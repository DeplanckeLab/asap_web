# frozen_string_literal: true

namespace :external_catalog do
  def external_catalog_resolve_user!
    if ENV['IMPORT_USER_ID'].present?
      user = User.find_by(id: ENV['IMPORT_USER_ID'].to_i)
      raise "IMPORT_USER_ID=#{ENV['IMPORT_USER_ID']} not found" unless user

      return user
    end

    email = ENV['IMPORT_USER_EMAIL'].to_s.strip
    raise 'Set IMPORT_USER_EMAIL or IMPORT_USER_ID' if email.blank?

    user = User.find_by(email: email)
    raise "User not found for IMPORT_USER_EMAIL=#{email}" unless user

    user
  end

  def external_catalog_resolve_version!
    if ENV['VERSION_ID'].present?
      version = Version.find_by(id: ENV['VERSION_ID'].to_i)
      raise "VERSION_ID=#{ENV['VERSION_ID']} not found" unless version

      return version
    end

    version = Version.activated.where('id > 3').order(id: :desc).first
    raise 'No activated Version (id > 3) found; set VERSION_ID' unless version

    version
  end

  def external_catalog_bool(name, default: false)
    return default unless ENV.key?(name)

    %w[1 true yes on].include?(ENV[name].to_s.strip.downcase)
  end

  def external_catalog_archiver
    lambda do |project|
      archive_project_to_s3!(project, s3b: archive_s3_bucket_config, dry_run: false)
    end
  end

  def external_catalog_build_importer(user: nil)
    ExternalCatalog::ProjectImporter.new(
      user: user || external_catalog_resolve_user!,
      version: external_catalog_resolve_version!,
      dry_run: external_catalog_bool('DRY_RUN'),
      skip_archive: external_catalog_bool('SKIP_ARCHIVE', default: true),
      skip_publish: external_catalog_bool('SKIP_PUBLISH'),
      strict: external_catalog_bool('STRICT'),
      allow_scfair_warnings: external_catalog_bool('ALLOW_SCFAIR_WARNINGS'),
      parse_timeout_sec: ENV['PARSE_TIMEOUT_SEC'],
      archiver: external_catalog_archiver
    )
  end

  # COUNT, N, or LIMIT — number of projects to create from the candidate table.
  def external_catalog_count
    raw = ENV['COUNT'].presence || ENV['N'].presence || ENV['LIMIT'].presence
    raw&.to_i
  end

  def external_catalog_select_candidates(source:, count:, only_new:, max_filesize:, project_type:)
    scope = ExternalCatalogCandidate.importable
    if source.present? && source != 'all'
      unless ExternalCatalogCandidate::SOURCES.include?(source)
        raise "SOURCE must be all|#{ExternalCatalogCandidate::SOURCES.join('|')} (got #{source.inspect})"
      end

      scope = scope.for_source(source)
    end
    scope = scope.for_project_type(project_type) if project_type.present?
    scope = scope.not_yet_in_asap if only_new
    if max_filesize
      scope = scope.where('filesize = 0 OR filesize <= ?', max_filesize)
    end

    # Same order as the catalog UI. COUNT finishes the last collection if the
    # slice would otherwise split it (e.g. Figure 1, Figure 2, then Mouse…).
    scope.take_for_import(count)
  end

  def external_catalog_print_results(results)
    puts "OK: #{results[:ok].size}"
    results[:ok].each do |row|
      e = row[:entry]
      p = row[:project]
      outcome = row[:outcome]
      suffix = outcome.present? ? " (#{outcome})" : ''
      puts "  #{e.source}/#{e.external_id} -> project #{p.id} key=#{p.key} name=#{p.name.inspect}#{suffix}"
    end
    puts "SKIPPED: #{results[:skipped].size}"
    results[:skipped].each do |row|
      e = row[:entry]
      puts "  #{e.source}/#{e.external_id}: #{row[:reason]}"
    end
    puts "FAILED: #{results[:failed].size}"
    results[:failed].each do |row|
      e = row[:entry]
      err = row[:error]
      puts "  #{e.source}/#{e.external_id}: #{err.class} #{err.message}"
    end
  end

  def external_catalog_mark_candidate!(
    candidate,
    status:,
    error: nil,
    project: nil,
    user: nil,
    set_import_project: false,
    link_kind: nil
  )
    attrs = {
      import_status: status,
      import_error: error
    }
    if project && set_import_project
      attrs[:import_project_id] = project.id
    end
    attrs[:import_user_id] = user.id if user
    attrs[:import_error] = nil if status == 'idle' && error.nil?
    candidate.update!(attrs)
    return unless project

    kind =
      link_kind.presence ||
      (set_import_project ? 'import' : 'content_match')
    candidate.link_matched_project!(project, link_kind: kind)
  end

  def external_catalog_import_candidates!(candidates, user:, importer:)
    results = { ok: [], skipped: [], failed: [] }
    dry_run = external_catalog_bool('DRY_RUN')

    candidates.each do |candidate|
      entry = candidate.to_entry
      begin
        if candidate.already_in_asap?
          project = candidate.asap_projects.order(id: :desc).first
          unless dry_run
            external_catalog_mark_candidate!(
              candidate,
              status: 'idle',
              project: project,
              user: user,
              set_import_project: false,
              link_kind: 'provider_match'
            )
          end
          results[:skipped] << { entry: entry, reason: "already imported project=#{project&.key}" }
          next
        end

        unless dry_run
          external_catalog_mark_candidate!(candidate, status: 'importing', user: user)
        end

        project = importer.import_one(entry)
        if project == :dry_run
          results[:skipped] << { entry: entry, reason: 'dry_run' }
        elsif project
          unless dry_run
            created = importer.last_import_outcome == :created
            external_catalog_mark_candidate!(
              candidate,
              status: 'idle',
              project: project,
              user: user,
              set_import_project: created,
              link_kind: created ? 'import' : 'content_match'
            )
          end
          results[:ok] << { entry: entry, project: project, outcome: importer.last_import_outcome }
        else
          external_catalog_mark_candidate!(
            candidate,
            status: 'failed',
            error: 'Import returned no project',
            user: user
          ) unless dry_run
          results[:failed] << { entry: entry, error: StandardError.new('Import returned no project') }
        end
      rescue ExternalCatalog::ProjectImporter::SkipEntry => e
        project = candidate.asap_projects.order(id: :desc).first
        if project
          unless dry_run
            external_catalog_mark_candidate!(
              candidate,
              status: 'idle',
              project: project,
              user: user,
              set_import_project: false,
              link_kind: 'provider_match'
            )
          end
          results[:skipped] << { entry: entry, reason: e.message }
        else
          external_catalog_mark_candidate!(candidate, status: 'failed', error: e.message, user: user) unless dry_run
          results[:skipped] << { entry: entry, reason: e.message }
        end
      rescue StandardError => e
        external_catalog_mark_candidate!(
          candidate,
          status: 'failed',
          error: "#{e.class}: #{e.message}".truncate(2000),
          user: user
        ) unless dry_run
        results[:failed] << { entry: entry, error: e }
        raise if external_catalog_bool('STRICT')
      end
    end
    results
  end

  def external_catalog_pick_test_candidate(source, label:, max_bytes: 250_000_000)
    scope = ExternalCatalogCandidate.importable.for_source(source).not_yet_in_asap
    preferred = scope.where('filesize > 0 AND filesize <= ?', max_bytes).order(:filesize, :id).first
    fallback = scope.order(Arel.sql('CASE WHEN filesize > 0 THEN 0 ELSE 1 END, filesize ASC, id ASC')).first
    candidate = preferred || fallback
    raise "No #{label} candidate found in external_catalog_candidates (sync first)" unless candidate

    puts "#{label} test candidate: #{candidate.external_id} #{candidate.title.to_s[0, 80].inspect} " \
         "tax_id=#{candidate.tax_id} format=#{candidate.format_kind} filesize=#{candidate.filesize} " \
         "type=#{candidate.project_type_tag}"
    candidate
  end

  desc 'Import from external_catalog_candidates (COUNT/N/LIMIT, IMPORT_USER_EMAIL|IMPORT_USER_ID, SOURCE, PROJECT_TYPE, ONLY_NEW=1). ' \
       'Without SOURCE (or SOURCE=all), candidates are taken in order CELLxGENE, Bgee, HCA, GEO. ' \
       'COUNT may include extra rows to finish the last collection so a batch cannot split it. ' \
       'Duplicate file content (SHA-256) links the provider onto the existing ASAP project instead of creating another. ' \
       'SC projects: refresh analysis_pipeline, hard-fail scFAIR loom/h5ad validation on errors ' \
       '(and on warnings unless ALLOW_SCFAIR_WARNINGS=1), sync chunked h5ad export, then publish/archive. ' \
       'SKIP_ARCHIVE=1 (default). SKIP_PUBLISH=1 still creates the landing checkpoint but does not make the project public. ' \
       'CHUNK_CELLS overrides chunked h5ad cell batch size (default 2048).'
  task import: :environment do
    source = ENV.fetch('SOURCE', 'all').to_s.strip.downcase
    count = external_catalog_count
    only_new = external_catalog_bool('ONLY_NEW', default: true)
    max_filesize = ENV['MAX_FILESIZE_BYTES'].presence&.to_i
    project_type = ENV['PROJECT_TYPE'].presence
    dry_run = external_catalog_bool('DRY_RUN')
    user = external_catalog_resolve_user!

    puts "external_catalog:import from candidates SOURCE=#{source} COUNT=#{count.inspect} " \
         "USER=#{user.email} ONLY_NEW=#{only_new} DRY_RUN=#{ENV['DRY_RUN']} " \
         "SKIP_ARCHIVE=#{ENV.fetch('SKIP_ARCHIVE', '1')} " \
         "SKIP_PUBLISH=#{ENV.fetch('SKIP_PUBLISH', '0')} " \
         "ALLOW_SCFAIR_WARNINGS=#{ENV.fetch('ALLOW_SCFAIR_WARNINGS', '0')} " \
         "PROJECT_TYPE=#{project_type.inspect}"
    if source == 'all'
      puts "Source priority: #{ExternalCatalogCandidate::IMPORT_SOURCE_ORDER.join(' -> ')}"
    end

    if ExternalCatalogCandidate.count.zero?
      raise 'No external_catalog_candidates rows. Run external_catalog:sync_candidates first.'
    end

    unless dry_run
      released = ExternalCatalogCandidate.release_stale_importing!
      if released.positive?
        puts "Released #{released} stale importing candidate(s) with no running import job"
      end
    end

    candidates = external_catalog_select_candidates(
      source: source,
      count: count,
      only_new: only_new,
      max_filesize: max_filesize,
      project_type: project_type
    )
    puts "Candidates selected: #{candidates.size}"
    if candidates.empty?
      puts 'No importable candidates found (already in ASAP, importing, or filters too strict).'
      next
    end

    candidates.each do |c|
      puts "  - #{c.source}/#{c.external_id} format=#{c.format_kind} size=#{c.filesize} " \
           "title=#{c.title.to_s[0, 60].inspect}"
    end

    importer = external_catalog_build_importer(user: user)
    results = external_catalog_import_candidates!(candidates, user: user, importer: importer)
    external_catalog_print_results(results)
    abort('external_catalog:import had failures') if results[:failed].any?
  end

  desc 'Test import: one candidate each from CELLxGENE, Bgee, HCA, GEO (IMPORT_USER_EMAIL required)'
  task test: :environment do
    puts 'external_catalog:test — one candidate each from CELLxGENE, Bgee, HCA, GEO'
    user = external_catalog_resolve_user!
    importer = external_catalog_build_importer(user: user)
    ExternalCatalogCandidate.release_stale_importing! unless external_catalog_bool('DRY_RUN')

    candidates = []
    candidates << external_catalog_pick_test_candidate('cellxgene', label: 'CELLxGENE')
    candidates << external_catalog_pick_test_candidate('bgee', label: 'Bgee')
    candidates << external_catalog_pick_test_candidate('hca', label: 'HCA', max_bytes: 150_000_000)
    candidates << external_catalog_pick_test_candidate('geo', label: 'GEO')

    results = external_catalog_import_candidates!(candidates, user: user, importer: importer)
    external_catalog_print_results(results)
    abort('external_catalog:test had failures') if results[:failed].any?
  end

  desc 'Explore GEO matrix availability (SAMPLE=40 GEO_MODE=all|sc|bulk)'
  task geo_explore: :environment do
    sample = ENV.fetch('SAMPLE', '40').to_i
    mode = ENV.fetch('GEO_MODE', 'all')
    puts "external_catalog:geo_explore SAMPLE=#{sample} GEO_MODE=#{mode}"

    catalog = ExternalCatalog::GeoCatalog.new
    sc_kinds = Hash.new(0)
    bulk_kinds = Hash.new(0)
    sc_n = 0
    bulk_n = 0
    examples = { sc: [], bulk: [] }

    catalog.each(limit: sample, mode: mode) do |entry|
      if entry.project_type_tag.to_s == 'sc'
        sc_n += 1
        sc_kinds[entry.format_kind] += 1
        examples[:sc] << [entry.external_id, entry.format_kind, entry.filename] if examples[:sc].size < 5
      else
        bulk_n += 1
        bulk_kinds[entry.format_kind] += 1
        examples[:bulk] << [entry.external_id, entry.format_kind, entry.filename] if examples[:bulk].size < 5
      end
    end

    puts "Accepted candidates: #{sc_n + bulk_n} (sc=#{sc_n}, bulk=#{bulk_n})"
    puts "SC kinds: #{sc_kinds.inspect}"
    puts "Bulk kinds: #{bulk_kinds.inspect}"
    puts "SC examples: #{examples[:sc].inspect}"
    puts "Bulk examples: #{examples[:bulk].inspect}"
    puts
    puts 'Priority: SC loom > h5ad > RDS > MTX; bulk counts_table > series_matrix > archive_table'
    puts 'Project names for GEO: "GSE12345: series title"'
  end

  desc 'Sync candidate list for UAB UI (SOURCE=all|cellxgene|bgee|hca|geo LIMIT=N GEO_MODE=all|sc|bulk)'
  task sync_candidates: :environment do
    source = ENV.fetch('SOURCE', 'all').to_s.strip.downcase
    limit = ENV['LIMIT'].presence&.to_i
    geo_mode = ENV.fetch('GEO_MODE', 'all').to_s
    puts "external_catalog:sync_candidates SOURCE=#{source} LIMIT=#{limit.inspect} GEO_MODE=#{geo_mode}"

    totals = ExternalCatalog::CandidateSync.new.call(source: source, limit: limit, geo_mode: geo_mode)
    puts "Upserted: #{totals[:upserted]}"
    puts "Marked obsolete: #{totals[:marked_obsolete]}"
    puts "Deleted test entries (blank URL): #{totals[:deleted_test]}"
    totals[:by_source].each do |src, n|
      puts "  #{src}: #{n}"
    end
    puts "Total active candidates in DB: #{ExternalCatalogCandidate.current.count}"
    puts "Total obsolete candidates in DB: #{ExternalCatalogCandidate.obsolete_only.count}"
    Array(totals[:failed]).each do |failure|
      puts "FAILED #{failure[:source]}: #{failure[:error]}"
    end
    abort('external_catalog:sync_candidates: one or more sources failed') if Array(totals[:failed]).any?
  end

  desc 'Refresh collection title/description from upstream APIs (SOURCE=cellxgene|hca|all). Also updates matching ASAP project_collections.'
  task refresh_collection_metadata: :environment do
    source = ENV.fetch('SOURCE', 'cellxgene').to_s.strip.downcase
    puts "external_catalog:refresh_collection_metadata SOURCE=#{source}"
    totals = ExternalCatalog::CollectionMetadataRefresh.new.call(source: source)
    puts "CELLxGENE collections upserted: #{totals[:cellxgene]}"
    puts "HCA collection rows ensured: #{totals[:hca]}"
    puts "ASAP project_collections refreshed: #{totals[:project_collections]}"
    sample = ExternalCatalogCollection.find_by(source: 'cellxgene', external_key: '05e3d0fc-c9dd-4f14-9163-2b242b3bb5c2')
    if sample
      puts "Sample ECC title=#{sample.title.inspect}"
      puts "Sample ECC description=#{sample.description.to_s[0, 120].inspect}"
    end
    pc = ProjectCollection.find_by(source: 'cellxgene', external_key: '05e3d0fc-c9dd-4f14-9163-2b242b3bb5c2')
    puts "Sample ASAP project_collection title=#{pc&.title.inspect}" if pc
  end

  desc 'Backfill catalog collections + public project↔candidate links + ASAP project_collections. DRY_RUN=1 to preview.'
  task backfill_public_project_links: :environment do
    dry_run = external_catalog_bool('DRY_RUN')
    puts "external_catalog:backfill_public_project_links DRY_RUN=#{dry_run}"

    unless ActiveRecord::Base.connection.table_exists?(:external_catalog_candidate_projects)
      raise 'Table external_catalog_candidate_projects missing — run migrations first'
    end

    public_scope = Project.where(public: true).where('projects.being_deleted IS NOT TRUE')
    if dry_run
      with_provider = public_scope.joins(:provider_projects).distinct.count
      with_sha = public_scope.where.not(input_content_sha256: [nil, '']).count
      missing_pc = public_scope.where(project_collection_id: nil).count
      puts "Would scan public projects: #{public_scope.count} (with provider_projects=#{with_provider}, with input sha=#{with_sha}, missing project_collection=#{missing_pc})"
      puts "Candidates with collection_id: #{ExternalCatalogCandidate.current.where.not(collection_id: [nil, '']).count}"
      next
    end

    if ActiveRecord::Base.connection.table_exists?(:external_catalog_collections)
      n = ExternalCatalogCandidate.backfill_catalog_collections!
      puts "Linked candidates to external_catalog_collections: #{n}"
      puts "external_catalog_collections total: #{ExternalCatalogCollection.count}"
    else
      puts 'Skip collection backfill (external_catalog_collections missing)'
    end

    scanned = 0
    linked_rows = 0
    assigned_collections = 0
    public_scope.find_each do |project|
      scanned += 1
      had_collection = project.project_collection_id.present?
      rows = ExternalCatalogCandidate.sync_catalog_links_for_public_project!(project)
      linked_rows += rows.size
      assigned_collections += 1 if !had_collection && project.reload.project_collection_id.present?
    end

    puts "Scanned public projects: #{scanned}"
    puts "link_matched_project calls: #{linked_rows}"
    puts "Assigned project_collections: #{assigned_collections}"
    puts "external_catalog_candidate_projects total: #{ExternalCatalogCandidateProject.count}"
    puts "project_collections total: #{ProjectCollection.count}"
  end
end
