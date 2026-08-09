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

  def external_catalog_build_importer
    ExternalCatalog::ProjectImporter.new(
      user: external_catalog_resolve_user!,
      version: external_catalog_resolve_version!,
      dry_run: external_catalog_bool('DRY_RUN'),
      skip_archive: external_catalog_bool('SKIP_ARCHIVE'),
      strict: external_catalog_bool('STRICT'),
      parse_timeout_sec: ENV['PARSE_TIMEOUT_SEC'],
      archiver: external_catalog_archiver
    )
  end

  def external_catalog_append_filtered(entries, entry, limit:, max_filesize:)
    return if limit.present? && entries.size >= limit.to_i
    if max_filesize && entry.filesize.to_i > 0 && entry.filesize.to_i > max_filesize
      return
    end

    entries << entry
  end

  def external_catalog_collect_entries(source:, limit:)
    max_filesize = ENV['MAX_FILESIZE_BYTES'].presence&.to_i
    geo_mode = ENV.fetch('GEO_MODE', 'all').to_s
    entries = []

    collect = lambda do |catalog, scan_limit: limit|
      catalog.each(limit: scan_limit) do |e|
        break if limit.present? && entries.size >= limit.to_i

        external_catalog_append_filtered(entries, e, limit: limit, max_filesize: max_filesize)
      end
    end

    case source
    when 'cellxgene'
      scan_limit = max_filesize && limit.present? ? [limit.to_i * 50, 200].max : limit
      before = entries.size
      ExternalCatalog::CellxgeneCatalog.new.each(limit: scan_limit) do |e|
        break if limit.present? && (entries.size - before) >= limit.to_i

        external_catalog_append_filtered(entries, e, limit: nil, max_filesize: max_filesize)
        break if limit.present? && (entries.size - before) >= limit.to_i
      end
    when 'bgee'
      collect.call(ExternalCatalog::BgeeCatalog.new)
    when 'hca'
      scan_limit = max_filesize && limit.present? ? [limit.to_i * 20, 100].max : limit
      before = entries.size
      ExternalCatalog::HcaCatalog.new.each(limit: scan_limit) do |e|
        break if limit.present? && (entries.size - before) >= limit.to_i

        external_catalog_append_filtered(entries, e, limit: nil, max_filesize: max_filesize)
        break if limit.present? && (entries.size - before) >= limit.to_i
      end
    when 'geo'
      ExternalCatalog::GeoCatalog.new.each(limit: limit, mode: geo_mode) do |e|
        entries << e
        break if limit.present? && entries.size >= limit.to_i
      end
    when 'all'
      per = limit
      %w[cellxgene bgee hca geo].each do |src|
        part = external_catalog_collect_entries(source: src, limit: per)
        entries.concat(part)
      end
    else
      raise "SOURCE must be all|cellxgene|bgee|hca|geo (got #{source.inspect})"
    end
    entries
  end

  def external_catalog_print_results(results)
    puts "OK: #{results[:ok].size}"
    results[:ok].each do |row|
      e = row[:entry]
      p = row[:project]
      puts "  #{e.source}/#{e.external_id} -> project #{p.id} key=#{p.key} name=#{p.name.inspect}"
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

  def external_catalog_pick_test_entry(catalog, label:, max_bytes: 250_000_000, scan_limit: 80, **each_opts)
    preferred = nil
    fallback = nil
    catalog.each(limit: scan_limit, **each_opts) do |entry|
      fallback ||= entry
      size = entry.filesize.to_i
      if size > 0 && size <= max_bytes
        preferred = entry
        break
      elsif size <= 0 && preferred.nil?
        preferred = entry
        break
      end
    end
    entry = preferred || fallback
    raise "No #{label} entry found" unless entry

    puts "#{label} test entry: #{entry.external_id} #{entry.title.to_s[0, 80].inspect} " \
         "tax_id=#{entry.tax_id} format=#{entry.format_kind} filesize=#{entry.filesize} type=#{entry.project_type_tag}"
    entry
  end

  desc 'Import catalogs (SOURCE=all|cellxgene|bgee|hca|geo LIMIT=N DRY_RUN=1 SKIP_ARCHIVE=1 GEO_MODE=all|sc|bulk)'
  task import: :environment do
    source = ENV.fetch('SOURCE', 'all').to_s.strip.downcase
    limit = ENV['LIMIT'].presence&.to_i
    puts "external_catalog:import SOURCE=#{source} LIMIT=#{limit.inspect} DRY_RUN=#{ENV['DRY_RUN']} " \
         "SKIP_ARCHIVE=#{ENV['SKIP_ARCHIVE']} GEO_MODE=#{ENV['GEO_MODE']}"

    entries = external_catalog_collect_entries(source: source, limit: limit)
    puts "Catalog entries selected: #{entries.size}"
    if entries.empty?
      puts 'No entries found.'
      next
    end

    importer = external_catalog_build_importer
    results = importer.import_many(entries)
    external_catalog_print_results(results)
    abort('external_catalog:import had failures') if results[:failed].any?
  end

  desc 'Test import: one entry each from CELLxGENE, Bgee, HCA, GEO (IMPORT_USER_EMAIL required)'
  task test: :environment do
    puts 'external_catalog:test — one CELLxGENE + Bgee + HCA + GEO'
    importer = external_catalog_build_importer

    entries = []
    entries << external_catalog_pick_test_entry(ExternalCatalog::CellxgeneCatalog.new, label: 'CELLxGENE')
    entries << external_catalog_pick_test_entry(ExternalCatalog::BgeeCatalog.new, label: 'Bgee')
    entries << external_catalog_pick_test_entry(
      ExternalCatalog::HcaCatalog.new,
      label: 'HCA',
      max_bytes: 150_000_000,
      scan_limit: 40
    )
    entries << external_catalog_pick_test_entry(
      ExternalCatalog::GeoCatalog.new,
      label: 'GEO',
      scan_limit: 30,
      mode: ENV.fetch('GEO_MODE', 'all')
    )

    results = importer.import_many(entries)
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
end
