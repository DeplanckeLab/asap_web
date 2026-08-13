# frozen_string_literal: true

require 'uri'
require 'open3'
require 'zlib'
require 'csv'
require 'fileutils'
require 'digest'

module ExternalCatalog
  # Sequential import of one catalog entry into ASAP:
  # download → preparse → (content-sha256+preparsing link or create project) → Provider label →
  # parse → scFAIR validation (sc) → archive.
  class ProjectImporter
    RAW_SEL = '/raw/X'
    DEFAULT_PARSE_TIMEOUT_SEC = 6 * 60 * 60
    POLL_INTERVAL_SEC = 15
    PREPARSING_FINGERPRINT_KEYS = %w[file_type sel_name delimiter gene_name_col has_header].freeze
    LANDING_CHECKPOINT_TITLE_SUFFIX = ' colored by cell type with labels'
    LEGACY_LANDING_CHECKPOINT_TITLES = [
      'Landing page',
      'Scatter plot colored by cell type metadata with labels',
      'UMAP colored by cell type metadata with labels',
      't-SNE colored by cell type metadata with labels',
      'PCA colored by cell type metadata with labels',
      "Scatter plot#{LANDING_CHECKPOINT_TITLE_SUFFIX}"
    ].freeze
    EMBEDDING_METHOD_LABELS = {
      umap: 'UMAP',
      tsne: 't-SNE',
      pca: 'PCA'
    }.freeze
    # Prefer UMAP, then t-SNE, then PCA when guessing from annot names.
    EMBEDDING_METHOD_RANK = {
      umap: 0,
      tsne: 1,
      pca: 2
    }.freeze

    class Error < StandardError; end
    class SkipEntry < StandardError; end

    def initialize(
      user:,
      version:,
      logger: Rails.logger,
      dry_run: false,
      skip_archive: false,
      skip_publish: false,
      strict: false,
      parse_timeout_sec: nil,
      archiver: nil
    )
      @user = user
      @version = version
      @logger = logger
      @dry_run = dry_run
      @skip_archive = skip_archive
      @skip_publish = skip_publish
      @strict = strict
      @parse_timeout_sec = (parse_timeout_sec || ENV.fetch('PARSE_TIMEOUT_SEC', DEFAULT_PARSE_TIMEOUT_SEC)).to_i
      @archiver = archiver
      @formats_by_name = FileFormat.all.index_by(&:name)
      @sc_type = ProjectType.find_by(tag: 'sc') || ProjectType.find_by('name ILIKE ?', '%single%')
      @bulk_type = ProjectType.find_by(tag: 'bulk') || ProjectType.find_by('name ILIKE ?', '%bulk%')
      raise Error, 'Single-cell project type not found' unless @sc_type
      raise Error, 'Bulk project type not found' unless @bulk_type
    end

    def import_many(entries)
      results = { ok: [], skipped: [], failed: [] }
      entries.each do |entry|
        begin
          project = import_one(entry)
          if project == :dry_run
            results[:skipped] << { entry: entry, reason: 'dry_run' }
          elsif project
            results[:ok] << { entry: entry, project: project }
          else
            results[:skipped] << { entry: entry, reason: 'no_project' }
          end
        rescue SkipEntry => e
          @logger.warn("[ExternalCatalog] skip #{entry.source}/#{entry.external_id}: #{e.message}")
          results[:skipped] << { entry: entry, reason: e.message }
          raise if @strict
        rescue StandardError => e
          @logger.error("[ExternalCatalog] fail #{entry.source}/#{entry.external_id}: #{e.class} #{e.message}")
          @logger.error(e.backtrace.first(20).join("\n")) if e.backtrace
          results[:failed] << { entry: entry, error: e }
          raise if @strict
        end
      end
      results
    end

    def import_one(entry)
      @logger.info(
        "[ExternalCatalog] start source=#{entry.source} id=#{entry.external_id} " \
        "title=#{entry.title.inspect} format=#{entry.format_kind} url=#{entry.url}"
      )

      provider = ensure_provider!(entry)
      if already_imported?(provider, entry.external_id)
        raise SkipEntry, "already imported provider=#{provider.name} key=#{entry.external_id}"
      end

      organism = resolve_organism!(entry)
      if @dry_run
        @logger.info(
          "[ExternalCatalog][dry-run] would import #{entry.source}/#{entry.external_id} " \
          "organism_id=#{organism.id} tax_id=#{entry.tax_id} type=#{entry.project_type_tag} " \
          "dois=#{entry.normalized_dois.inspect} pmids=#{entry.normalized_pmids.inspect} " \
          "identifiers=#{entry.normalized_identifiers.inspect}"
        )
        return :dry_run
      end

      @last_import_outcome = nil
      fu = download_and_preparse!(entry, organism)
      sel_name, dims, file_type = choose_matrix_selection!(fu, organism)
      parsing_attrs = build_parsing_attrs(entry, sel_name, dims, file_type)
      preparsing_fp = preparsing_fingerprint(parsing_attrs)
      content_sha = InputFileSha256.ensure_for_fu!(fu)
      existing = find_live_project_by_content_and_preparsing(content_sha, preparsing_fp)
      if existing
        @logger.info(
          "[ExternalCatalog] content+preparsing match source=#{entry.source}/#{entry.external_id} " \
          "sha=#{content_sha} fp=#{preparsing_fp} -> existing project_id=#{existing.id} key=#{existing.key}; " \
          'linking provider instead of creating a new project'
        )
        link_existing_project!(existing, entry, provider)
        discard_unused_fu!(fu)
        @last_import_outcome = :linked
        return existing
      end

      project = create_project!(entry, fu, organism, parsing_attrs, preparsing_fp)
      attach_project_collection!(project, entry)
      attach_provider_label!(project, provider, entry)
      wait_for_parse!(project)
      attach_reference_metadata!(project, entry)
      run_scfair_validation!(project) if project_type_for(entry).tag.to_s == 'sc'
      finalize_project_visibility!(project)
      archive_project!(project) unless @skip_archive

      @logger.info(
        "[ExternalCatalog] done source=#{entry.source} id=#{entry.external_id} " \
        "project_id=#{project.id} key=#{project.key} public=#{project.public?}"
      )
      @last_import_outcome = :created
      project
    end

    attr_reader :last_import_outcome

    private

    def find_live_project_by_content_and_preparsing(sha, fingerprint)
      return nil if sha.blank? || fingerprint.blank?

      Project.where(input_content_sha256: sha.to_s, input_preparsing_fingerprint: fingerprint.to_s)
             .where(being_deleted: [false, nil])
             .order(Arel.sql('CASE WHEN public THEN 0 ELSE 1 END'), id: :asc)
             .first
    end

    def preparsing_fingerprint(attrs)
      h = attrs.is_a?(Hash) ? attrs.deep_stringify_keys : {}
      payload = PREPARSING_FINGERPRINT_KEYS.index_with { |k| h[k].nil? ? nil : h[k].to_s }
      Digest::SHA256.hexdigest(payload.to_json)
    end

    def build_parsing_attrs(entry, sel_name, dims, file_type)
      parsing_attrs = { file_type: file_type.presence || 'H5AD' }
      if sel_name.present? && parsing_attrs[:file_type].to_s.upcase != 'RAW_TEXT'
        parsing_attrs[:sel_name] = sel_name
      end
      parsing_attrs[:nber_rows] = dims[:nber_rows] if dims[:nber_rows].present?
      parsing_attrs[:nber_cols] = dims[:nber_cols] if dims[:nber_cols].present?

      if entry.source.to_s == 'geo' && %w[series_matrix counts_table].include?(entry.format_kind.to_s)
        parsing_attrs[:file_type] = 'RAW_TEXT'
        parsing_attrs[:has_header] = '1'
        parsing_attrs[:gene_name_col] = 'first'
        parsing_attrs[:delimiter] = ''
        parsing_attrs.delete(:sel_name)
      end
      parsing_attrs
    end

    # Attach this catalog entry's provider onto an existing ASAP project that already
    # has the same input file content and preparsing params. Also merge identifiers /
    # publications from this source. Candidate↔project join + optional import_project_id
    # are set by the importer caller.
    def link_existing_project!(project, entry, provider)
      attach_provider_label!(project, provider, entry)
      attach_reference_metadata!(project, entry)
      if project.project_collection_id.blank?
        attach_project_collection!(project, entry)
      end
      @logger.info(
        "[ExternalCatalog] linked source=#{entry.source}/#{entry.external_id} " \
        "provider=#{provider.tag} onto project=#{project.key}"
      )
      project
    end

    def discard_unused_fu!(fu)
      return unless fu

      upload_dir = begin
        fu.upload_dir
      rescue StandardError
        nil
      end
      fu.destroy!
      if upload_dir && upload_dir.exist?
        FileUtils.rm_rf(upload_dir)
      end
    rescue StandardError => e
      @logger.warn("[ExternalCatalog] could not discard unused Fu##{fu&.id}: #{e.class} #{e.message}")
    end

    def ensure_provider!(entry)
      provider = Provider.find_or_create_by!(tag: entry.provider_tag) do |p|
        p.name = entry.provider_name
        p.description = "Imported from #{entry.provider_name} catalog"
      end

      desired_mask =
        case entry.source.to_s
        when 'hca'
          'https://data.humancellatlas.org/explore/projects/#{id}'
        when 'geo'
          'https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=#{id}'
        when 'cellxgene'
          # ProviderProject key is the CELLxGENE dataset_id.
          'https://cellxgene.cziscience.com/e/#{id}.cxg/'
        when 'bgee'
          # Bgee curated experiment page (ids are typically SRA/ENA study accessions).
          'https://www.bgee.org/experiment/#{id}'
        end

      if desired_mask.present? && provider.url_mask != desired_mask
        provider.update!(url_mask: desired_mask)
      end
      if provider.name != entry.provider_name
        provider.update!(name: entry.provider_name)
      end
      provider
    end

    def already_imported?(provider, external_id)
      pp = ProviderProject.find_by(provider_id: provider.id, key: external_id.to_s)
      return false unless pp

      pp.projects.where(being_deleted: [false, nil]).exists?
    end

    def project_type_for(entry)
      tag = entry.project_type_tag.to_s
      tag == 'bulk' ? @bulk_type : @sc_type
    end

    def resolve_organism!(entry)
      tax_id = entry.tax_id.to_i
      label = entry.organism_label.to_s.split(';').map(&:strip).reject(&:blank?).first

      if tax_id <= 0 && label.present?
        tax_id = HcaCatalog::SPECIES_TAX[label.downcase].to_i
      end

      if tax_id <= 0 && label.present?
        local = Organism.where('LOWER(name) = ?', label.downcase).where(obsolete: [false, nil]).order(:id).first
        if local
          @logger.info("[ExternalCatalog] organism by name #{label.inspect} -> id=#{local.id} tax_id=#{local.tax_id}")
          return local
        end
      end

      if tax_id <= 0
        raise SkipEntry, "Missing tax_id for #{entry.source}/#{entry.external_id} (#{label})"
      end

      env_data = Basic.safe_parse_json(@version.env_json, {})
      db_name = env_data['asap_data_db_name'].to_s.strip
      raise Error, "Version #{@version.id} missing asap_data_db_name" if db_name.blank?

      remote_orgs = RemoteOrganism.list_for_version(db_name)
      matches = remote_orgs.select { |o| o['tax_id'].to_i == tax_id }
      if matches.empty?
        raise SkipEntry, "No ASAP organism for tax_id=#{tax_id} (#{label})"
      end

      chosen =
        matches.find { |o| o['short_name'].to_s.split.size == 1 } ||
        matches.min_by { |o| o['id'].to_i }

      organism = Organism.find_by(id: chosen['id'])
      raise SkipEntry, "Organism id=#{chosen['id']} not in local organisms table" unless organism

      @logger.info(
        "[ExternalCatalog] organism tax_id=#{tax_id} -> id=#{organism.id} " \
        "name=#{organism.name} short_name=#{chosen['short_name']}"
      )
      organism
    end

    def download_and_preparse!(entry, organism)
      original_name = entry.filename.presence ||
                      URI.parse(entry.url).path.to_s.split('/').last.presence ||
                      'input_file'
      original_name = original_name.gsub(/[()\[\]#?$]/, '')
      ext = ProjectInputFinalizerService.extract_upload_extension(original_name)
      ext = '.bin' if ext.blank?
      input_filename = "input_file#{ext}"

      fu = Fu.create!(
        user_id: @user.id,
        upload_file_name: input_filename,
        upload_file_size: 0,
        status: 'downloading',
        name: original_name,
        url: entry.url
      )

      FuDownloadFromUrlJob.perform_now(
        fu.id,
        entry.url,
        organism_id: organism.id,
        version_id: @version.id
      )
      fu.reload

      unless %w[preparsed completed uploaded].include?(fu.status.to_s)
        raise Error, "Download/preparse failed for Fu##{fu.id} status=#{fu.status}"
      end

      if entry.format_kind.to_s == 'series_matrix'
        convert_series_matrix_fu!(fu, entry, organism)
        fu.reload
        unless %w[preparsed completed uploaded].include?(fu.status.to_s)
          raise Error, "series_matrix re-preparse failed for Fu##{fu.id} status=#{fu.status}"
        end
      elsif entry.source.to_s == 'geo' && entry.format_kind.to_s == 'counts_table'
        normalize_counts_table_fu!(fu, entry, organism)
        fu.reload
      end

      fu
    end

    def text_delimiter_for(entry)
      name = entry.filename.to_s.downcase
      return ',' if name.end_with?('.csv', '.csv.gz')
      return "\t" if name.end_with?('.tsv', '.tsv.gz') ||
                    name.end_with?('.txt', '.txt.gz') ||
                    entry.format_kind.to_s == 'series_matrix'

      ''
    end

    def re_preparse_text_fu!(fu, organism, delimiter:)
      return if delimiter.blank?

      @logger.info("[ExternalCatalog] re-preparsing Fu##{fu.id} as RAW_TEXT delimiter=#{delimiter.inspect}")
      fu.update!(status: 'preparsing')
      FuPreparsingService.new(
        fu,
        organism_id: organism.id,
        version_id: @version.id,
        delimiter: delimiter
      ).call
      fu.update!(status: 'preparsed')
    end

    COUNTS_ANNOTATION_HEADERS = %w[
      geneid gene_id gene genes id_ref id chr chromosome chrom start end strand length
      gene_name gene_symbol symbol description biotype feature name
    ].freeze

    # Deposit often includes featureCounts annotation columns; keep gene id + numeric samples only.
    def normalize_counts_table_fu!(fu, entry, organism)
      src = fu.upload_dir.join(fu.upload_file_name)
      raise Error, "Missing counts table for Fu##{fu.id}" unless File.exist?(src)

      delimiter = text_delimiter_for(entry)
      delimiter = ',' if delimiter.blank? && entry.filename.to_s.downcase.include?('.csv')
      delimiter = "\t" if delimiter.blank?

      raw =
        if src.to_s.end_with?('.gz')
          Zlib::GzipReader.open(src) { |gz| gz.read }
        else
          File.read(src)
        end
      raw = raw.to_s.sub(/\A\uFEFF/, '')

      require 'csv'
      table = CSV.parse(raw, headers: true, col_sep: delimiter, liberal_parsing: true)
      raise SkipEntry, "counts table empty for #{entry.external_id}" if table.headers.blank? || table.size < 2

      headers = table.headers.map { |h| h.to_s.strip }
      gene_header = headers.first
      raise SkipEntry, "counts table missing gene column for #{entry.external_id}" if gene_header.blank?

      sample_headers = headers.drop(1).reject do |h|
        COUNTS_ANNOTATION_HEADERS.include?(h.to_s.downcase.strip)
      end
      if sample_headers.empty?
        raise SkipEntry, "counts table has no sample columns for #{entry.external_id}"
      end

      # Keep only columns that look numeric on a sample of rows.
      probe = table.first([50, table.size].min)
      numeric_headers = sample_headers.select do |h|
        vals = probe.map { |row| row[h].to_s.strip }.reject(&:blank?)
        next false if vals.empty?

        ok = vals.count { |v| v.match?(/\A[+-]?\d+(\.\d+)?([eE][+-]?\d+)?\z/) }
        ok.fdiv(vals.size) >= 0.9
      end
      if numeric_headers.size < 2
        raise SkipEntry,
              "counts table has too few numeric sample columns (#{numeric_headers.size}) for #{entry.external_id}"
      end

      out_name = 'input_file.txt'
      out_path = fu.upload_dir.join(out_name)
      CSV.open(out_path, 'w', col_sep: "\t") do |csv|
        csv << ([gene_header] + numeric_headers)
        table.each do |row|
          gene = row[gene_header].to_s.strip
          next if gene.blank?

          values = numeric_headers.map do |h|
            v = row[h].to_s.strip
            v.presence || '0'
          end
          csv << ([gene] + values)
        end
      end

      File.delete(src) if src.to_s != out_path.to_s && File.exist?(src)
      fu.update!(
        upload_file_name: out_name,
        upload_file_size: File.size(out_path),
        name: "#{File.basename(entry.filename.to_s.sub(/\.gz\z/i, ''))}.tsv",
        status: 'preparsing'
      )
      FuPreparsingService.new(
        fu,
        organism_id: organism.id,
        version_id: @version.id,
        delimiter: ''
      ).call
      fu.update!(status: 'preparsed')
    end

    # GEO series_matrix is SOFT metadata wrapping a tab table; ASAP needs the table alone.
    def convert_series_matrix_fu!(fu, entry, organism)
      src = fu.upload_dir.join(fu.upload_file_name)
      raise Error, "Missing series_matrix file for Fu##{fu.id}" unless File.exist?(src)

      raw =
        if src.to_s.end_with?('.gz')
          Zlib::GzipReader.open(src) { |gz| gz.read }
        else
          File.read(src)
        end

      lines = raw.to_s.lines.map(&:chomp)
      begin_idx = lines.index { |l| l.strip == '!series_matrix_table_begin' }
      end_idx = lines.index { |l| l.strip == '!series_matrix_table_end' }
      unless begin_idx && end_idx && end_idx > begin_idx + 1
        raise SkipEntry, "series_matrix has no expression table for #{entry.external_id}"
      end

      table_lines = lines[(begin_idx + 1)...end_idx].reject(&:blank?)
      if table_lines.size < 2
        raise SkipEntry, "series_matrix expression table empty for #{entry.external_id}"
      end

      cleaned = table_lines.map do |line|
        line.split("\t").map { |cell| cell.to_s.gsub(/\A"|"\z/, '') }.join("\t")
      end

      out_name = 'input_file.txt'
      out_path = fu.upload_dir.join(out_name)
      File.write(out_path, "#{cleaned.join("\n")}\n")
      File.delete(src) if src.to_s != out_path.to_s && File.exist?(src)

      fu.update!(
        upload_file_name: out_name,
        upload_file_size: File.size(out_path),
        name: "#{File.basename(entry.filename.to_s, '.gz')}.tsv",
        status: 'preparsing'
      )
      FuPreparsingService.new(
        fu,
        organism_id: organism.id,
        version_id: @version.id,
        delimiter: ''
      ).call
      fu.update!(status: 'preparsed')
    end

    def choose_matrix_selection!(fu, organism)
      output_path = fu.upload_dir.join('output.json')
      raise Error, "Missing preparsing output.json for Fu##{fu.id}" unless File.exist?(output_path)

      output = Basic.safe_parse_json(File.read(output_path), {})
      file_type = Basic.effective_preparsing_file_type(output).presence || output['detected_format'].to_s
      groups = Array(output['list_groups'])
      paths = groups.map { |g| g['group'].to_s }.reject(&:blank?)

      if paths.empty?
        # Some formats still parse with empty list_groups in edge cases; persist type only.
        return [nil, {}, file_type]
      end

      sel_name = nil
      if file_type.to_s.upcase == 'H5AD'
        sel_name =
          if paths.include?(RAW_SEL)
            RAW_SEL
          elsif paths.size == 1
            normalize_sel_path(paths.first)
          else
            raise Error, "Ambiguous H5AD matrices without #{RAW_SEL}: #{paths.join(', ')}"
          end

        if sel_name == RAW_SEL
          @logger.info("[ExternalCatalog] re-preparsing Fu##{fu.id} with sel=#{RAW_SEL}")
          fu.update!(status: 'preparsing')
          FuPreparsingService.new(
            fu,
            organism_id: organism.id,
            version_id: @version.id,
            sel: RAW_SEL
          ).call
          fu.update!(status: 'preparsed')
          output = Basic.safe_parse_json(File.read(output_path), {})
          groups = Array(output['list_groups'])
          file_type = Basic.effective_preparsing_file_type(output).presence || file_type
        end
      elsif file_type.to_s.upcase == 'RAW_TEXT'
        sel_name = nil
      elsif paths.size == 1
        # LOOM / RDS / single archive member — keep group name when useful for archives.
        sel_name = paths.first
        sel_name = nil if file_type.to_s.upcase == 'LOOM'
      elsif %w[ARCHIVE ARCHIVE_COMPRESSED COMPRESSED].include?(file_type.to_s.upcase)
        raise Error, "Ambiguous archive members: #{paths.join(', ')}"
      else
        sel_name = paths.first
      end

      selected =
        if sel_name
          groups.find { |g| g['group'].to_s == sel_name } || groups.first
        else
          groups.first
        end
      dims = {
        nber_rows: selected && (selected['nber_rows'] || selected['nb_genes']),
        nber_cols: selected && (selected['nber_cols'] || selected['nb_cells'])
      }
      [sel_name, dims, file_type]
    end

    def normalize_sel_path(path)
      p = path.to_s
      return p if p.start_with?('/')
      return '/X' if p == 'X'

      "/layers/#{p}"
    end

    def create_project!(entry, fu, organism, parsing_attrs, preparsing_fp)
      ptype = project_type_for(entry)
      project = Project.new(
        user_id: @user.id,
        key: Project.generate_unique_key,
        name: entry.project_name,
        description: "Imported from #{entry.provider_name} (#{entry.external_id})",
        organism_id: organism.id,
        project_type_id: ptype.id,
        version_id: @version.id,
        fu_id: fu.id,
        nber_rows: parsing_attrs[:nber_rows],
        nber_cols: parsing_attrs[:nber_cols],
        parsing_attrs_json: parsing_attrs.to_json,
        input_preparsing_fingerprint: preparsing_fp,
        status_id: Status.find_by(name: 'pending')&.id || 1
      )
      project.save!
      project.ensure_project_steps

      user_data_dir = ENV['USER_DATA_DIR'] || Rails.root.join('storage', 'user_data').to_s
      project_dir = Pathname.new(user_data_dir) + project.user_id.to_s + project.key
      FileUtils.mkdir_p(project_dir)

      ProjectInputFinalizerService.call(
        project: project,
        project_dir: project_dir,
        input_file: fu,
        formats_by_name: @formats_by_name,
        logger: @logger
      )

      project.parse_files({})
      project
    end

    def attach_project_collection!(project, entry)
      collection_id = entry.collection_id.to_s.strip.presence
      return if collection_id.blank?
      return if project.project_collection_id.present?

      collection_url =
        case entry.source.to_s
        when 'cellxgene'
          "https://cellxgene.cziscience.com/collections/#{collection_id}"
        when 'hca'
          "https://data.humancellatlas.org/explore/projects/#{collection_id}"
        else
          entry.source_page_url.to_s.presence
        end

      collection = ProjectCollection.upsert_from_catalog!(
        source: entry.source.to_s,
        external_key: collection_id,
        title: entry.collection_title,
        description: entry.collection_description,
        source_page_url: collection_url
      )
      project.update!(project_collection_id: collection.id)
    end

    def attach_provider_label!(project, provider, entry)
      pp = ProviderProject.find_or_initialize_by(provider_id: provider.id, key: entry.external_id.to_s)
      pp.title = entry.project_name(max_length: 255)
      pp.filename = entry.filename.presence || File.basename(URI.parse(entry.url).path.to_s).presence
      attrs = Basic.safe_parse_json(pp.attrs_json, {})
      attrs['source_url'] = entry.url
      attrs['organism_label'] = entry.organism_label
      attrs['tax_id'] = entry.tax_id
      attrs['format_kind'] = entry.format_kind
      attrs['project_type_tag'] = entry.project_type_tag
      attrs['dois'] = entry.normalized_dois
      attrs['pmids'] = entry.normalized_pmids
      attrs['identifiers'] = entry.normalized_identifiers
      if entry.source_page_url.present?
        attrs['source_page_url'] = entry.source_page_url.to_s
      elsif provider.url_mask.present?
        attrs['source_page_url'] = provider.url_mask.gsub('#{id}', entry.external_id.to_s)
      end
      pp.attrs_json = attrs.to_json
      pp.save!

      unless project.provider_projects.exists?(id: pp.id)
        project.provider_projects << pp
      end
    end

    # Publication (DOI / PMID → Article + project.doi) and dataset accessions → ExpEntry.
    def attach_reference_metadata!(project, entry)
      attach_publications!(project, entry)
      attach_exp_identifiers!(project, entry)
    end

    def attach_publications!(project, entry)
      dois = entry.normalized_dois
      pmids = entry.normalized_pmids
      return if dois.empty? && pmids.empty?

      if pmids.any?
        Fetch.load_articles(pmids.join(';'))
        pmids.each do |pmid|
          article = Article.find_by(pmid: pmid)
          next unless article

          project.articles << article unless project.articles.exists?(id: article.id)
          dois << ReferenceIds.normalize_doi(article.doi) if article.doi.present?
        end
      end

      dois = dois.compact.uniq
      dois.each do |doi|
        article = Article.find_by(doi: doi)
        if article.nil?
          info = Fetch.doi_info(doi)
          next if info.blank? || info[:doi].blank?

          article = Article.create!(info)
        end
        project.articles << article unless project.articles.exists?(id: article.id)
      end

      return if dois.empty?

      existing = project.doi.to_s.split(/[\s,;]+/).map { |d| ReferenceIds.normalize_doi(d) }.compact
      merged = (existing + dois).uniq
      project.update!(doi: merged.join(', '))
      @logger.info("[ExternalCatalog] publications project=#{project.key} dois=#{merged.inspect} pmids=#{pmids.inspect}")
    end

    def attach_exp_identifiers!(project, entry)
      ids = entry.normalized_identifiers
      return if ids.empty?

      ids.each do |ref|
        kind = ref[:kind]
        value = ref[:value].to_s.strip
        type_id = ReferenceIds.type_id_for_kind(kind)
        next if type_id.blank? || value.blank?

        exp_entry =
          if kind == 'geo_series'
            Fetch.fetch_gse(value)
            ExpEntry.find_by(identifier: value, identifier_type_id: type_id) ||
              ExpEntry.find_or_initialize_by(identifier: value, identifier_type_id: type_id)
          elsif kind == 'array_express'
            Fetch.fetch_array_express(value)
            ExpEntry.find_by(identifier: value, identifier_type_id: type_id) ||
              ExpEntry.find_or_initialize_by(identifier: value, identifier_type_id: type_id)
          else
            ExpEntry.find_or_initialize_by(identifier: value, identifier_type_id: type_id)
          end

        if exp_entry.new_record?
          exp_entry.title ||= entry.title.to_s.truncate(255).presence
          exp_entry.save!
        elsif exp_entry.changed?
          exp_entry.save!
        end

        unless project.exp_entries.exists?(id: exp_entry.id)
          project.exp_entries << exp_entry
        end
      end

      # Copy a DOI onto linked exp_entries when they lack one (propagate_project_doi
      # expects a single DOI string, so handle comma-separated project.doi here).
      primary_doi = entry.normalized_dois.first ||
                    ReferenceIds.normalize_doi(project.doi.to_s.split(/[\s,;]+/).first)
      if primary_doi.present?
        project.exp_entries.where(doi: [nil, '']).find_each do |ee|
          ee.update!(doi: primary_doi)
        end
      end
      @logger.info(
        "[ExternalCatalog] exp_entries project=#{project.key} " \
        "ids=#{ids.map { |h| "#{h[:kind]}:#{h[:value]}" }.inspect}"
      )
    end

    def wait_for_parse!(project)
      success_id = Status.find_by(name: 'success')&.id
      failed_id = Status.find_by(name: 'failed')&.id
      stopped_id = Status.find_by(name: 'stopped')&.id
      deadline = Time.now + @parse_timeout_sec

      loop do
        project.reload
        loom = project_loom_path(project)
        if loom && File.exist?(loom) && File.size(loom) > 0
          run = latest_parsing_run(project)
          if run.nil? || run.status_id == success_id
            @logger.info("[ExternalCatalog] parse complete project=#{project.key} loom=#{loom}")
            return
          end
        end

        run = latest_parsing_run(project)
        if run && [failed_id, stopped_id].include?(run.status_id)
          raise Error, "Parsing failed for project=#{project.key} run=#{run.id} status_id=#{run.status_id}"
        end

        if Time.now > deadline
          raise Error, "Parsing timed out after #{@parse_timeout_sec}s for project=#{project.key}"
        end

        @logger.info(
          "[ExternalCatalog] waiting for parse project=#{project.key} " \
          "run_status=#{run&.status_id} loom=#{loom.inspect}"
        )
        sleep POLL_INTERVAL_SEC
      end
    end

    def latest_parsing_run(project)
      asap_docker_image = Basic.get_asap_docker(project.version)
      return nil unless asap_docker_image

      parsing_step_ids = Step.where(
        docker_image_id: asap_docker_image.id,
        version_id: project.version_id,
        name: 'parsing'
      ).pluck(:id)
      return nil if parsing_step_ids.empty?

      Run.where(project_id: project.id, step_id: parsing_step_ids).order(id: :desc).first
    end

    def project_loom_path(project)
      user_data_dir = ENV['USER_DATA_DIR'] || Rails.root.join('storage', 'user_data').to_s
      primary = Pathname.new(user_data_dir).join(project.user_id.to_s, project.key, 'parsing', 'output.loom')
      return primary.to_s if File.exist?(primary)

      Dir.glob(File.join(user_data_dir, project.user_id.to_s, project.key, '**', '*.loom')).first
    end

    def run_scfair_validation!(project)
      @logger.info("[ExternalCatalog] scFAIR validation project=#{project.key}")
      ScfairValidationJob.perform_now(project.id)
    end

    def visualization_available?(project)
      Annot.light.where(project_id: project.id)
           .where.not(filepath: nil)
           .where(dim: 1, nber_rows: 2)
           .exists?
    end

    def finalize_project_visibility!(project)
      project.reload
      unless visualization_available?(project)
        @logger.info("[ExternalCatalog] skip landing/public project=#{project.key}: no visualization embeddings")
        return
      end

      create_landing_visualization_checkpoint!(project)

      if @skip_publish
        @logger.info("[ExternalCatalog] skip public project=#{project.key}: SKIP_PUBLISH")
        return
      end

      can_publish, reason = project.can_be_public?
      unless can_publish
        @logger.info("[ExternalCatalog] skip public project=#{project.key}: #{reason}")
        return
      end

      if project.public?
        @logger.info("[ExternalCatalog] already public project=#{project.key} public_id=#{project.public_id}")
        return
      end

      if project.sandbox?
        @logger.info("[ExternalCatalog] skip public project=#{project.key}: sandbox project")
        return
      end

      project.public_id = (Project.maximum(:public_id) || 0) + 1 if project.public_id.nil?
      project.public = true
      project.public_at = Time.current
      project.save!
      @logger.info(
        "[ExternalCatalog] made public project=#{project.key} public_id=#{project.public_id}"
      )
    end

    def create_landing_visualization_checkpoint!(project)
      embedding = prefer_embedding_annot(project)
      unless embedding
        @logger.info("[ExternalCatalog] skip landing checkpoint project=#{project.key}: no embedding annot")
        return
      end

      coloring = find_cell_type_annot(project, filepath: embedding.filepath)
      unless coloring
        @logger.info(
          "[ExternalCatalog] skip landing checkpoint project=#{project.key}: " \
          "no cell_type metadata on loom=#{embedding.filepath}"
        )
        return
      end

      loom_file = embedding.filepath
      state = landing_checkpoint_state(embedding: embedding, coloring: coloring, loom_file: loom_file)
      label_font = state.dig('display', 'labelFontSizeMode')
      label_size = state.dig('display', 'labelFontSize')
      title = landing_checkpoint_title_for(embedding)

      Checkpoint.transaction do
        project.checkpoints.visualization.where(is_landing_page: true).update_all(is_landing_page: false)

        checkpoint = find_existing_landing_checkpoint(project, title: title) ||
                     project.checkpoints.visualization.new
        checkpoint.title = title
        checkpoint.user = project.user
        checkpoint.kind = Checkpoint::KIND_VISUALIZATION
        checkpoint.run_id = nil
        checkpoint.state = state
        checkpoint.comments = checkpoint.comments.presence || []
        checkpoint.is_landing_page = true
        checkpoint.save!
        @logger.info(
          "[ExternalCatalog] landing checkpoint project=#{project.key} " \
          "checkpoint_id=#{checkpoint.id} title=#{title.inspect} " \
          "emb=#{embedding.id}(#{embedding.name}) " \
          "color=#{coloring.id}(#{coloring.name}) labels=on " \
          "labelFont=#{label_font}:#{label_size}"
        )
      end
    end

    def prefer_embedding_annot(project)
      Annot.light
           .where(project_id: project.id, dim: 1, nber_rows: 2)
           .where.not(filepath: nil)
           .to_a
           .min_by do |annot|
        parsing_rank = annot.filepath.to_s.match?(%r{(^|/)parsing(/|$)}) ? 0 : 1
        method_rank = embedding_method_rank(annot.name)
        cell_count = -(annot.nber_cols.to_i)
        [method_rank, parsing_rank, cell_count, annot.id]
      end
    end

    def detect_embedding_method(name)
      text = name.to_s
      return :umap if text.match?(/(?:\b|_)umap(?:\b|_)/i)
      return :tsne if text.match?(/(?:\b|_)(?:tsne|t_sne|t-sne)(?:\b|_)/i)
      return :pca if text.match?(/(?:\b|_)pca(?:\b|_)/i)

      nil
    end

    def embedding_method_rank(name)
      method = detect_embedding_method(name)
      EMBEDDING_METHOD_RANK.fetch(method, 3)
    end

    def embedding_method_label(name)
      method = detect_embedding_method(name)
      EMBEDDING_METHOD_LABELS[method] || 'Scatter plot'
    end

    def landing_checkpoint_title_for(embedding)
      "#{embedding_method_label(embedding.name)}#{LANDING_CHECKPOINT_TITLE_SUFFIX}"
    end

    def find_existing_landing_checkpoint(project, title:)
      known_titles = (
        EMBEDDING_METHOD_LABELS.values.map { |label| "#{label}#{LANDING_CHECKPOINT_TITLE_SUFFIX}" } +
        LEGACY_LANDING_CHECKPOINT_TITLES +
        [title]
      ).uniq

      project.checkpoints.visualization.where(title: known_titles).order(:id).first
    end

    def find_cell_type_annot(project, filepath:)
      scope = Annot.light
                   .where(project_id: project.id, filepath: filepath, dim: 1, nber_rows: 1)
                   .where("name ILIKE ?", "%cell_type%")
                   .where.not("name ILIKE ?", "%ontology%")

      exact = scope.find { |a| a.name.to_s.downcase == '/col_attrs/cell_type' }
      return exact if exact

      preferred = scope.find do |a|
        base = a.name.to_s.split('/').last.to_s.downcase.tr(' ', '_')
        base == 'cell_type'
      end
      return preferred if preferred

      scope.min_by(&:id)
    end

    def landing_checkpoint_state(embedding:, coloring:, loom_file:)
      label_font = landing_label_font_settings(coloring)

      {
        'version' => 1,
        'loomFile' => loom_file,
        'embedding' => {
          'id' => embedding.id.to_s,
          'loomFile' => loom_file
        },
        'visualizationEmbedding' => {
          'id' => embedding.id.to_s,
          'loomFile' => loom_file,
          'name' => embedding.name,
          'dimension' => nil
        },
        'matrix' => {
          'layer' => nil,
          'annotId' => nil
        },
        'coloring' => {
          'metadataId' => coloring.id.to_s,
          'geneSetItem' => nil,
          'categoryColorOverrides' => {},
          'customColorRange' => nil,
          'currentColorScheme' => nil,
          'gradientScale' => 'normal',
          'metadataGradients' => {},
          'history' => []
        },
        'filters' => {
          'selectedCategories' => {},
          'selectedRanges' => {},
          'metadataFilterSwitches' => {},
          'geneFilterSwitches' => {},
          'globalFiltersEnabled' => true
        },
        'adaptColorRangeByMetadataId' => {},
        'axes' => { 'x' => nil, 'y' => nil },
        'foldState' => {
          'metadata' => { coloring.id.to_s => true },
          'genes' => {}
        },
        'panelScroll' => {},
        'bottomRightPanel' => nil,
        'genes' => { 'tags' => [] },
        'display' => {
          'pointSize' => nil,
          'categoryOrder' => 'largest-first',
          'numericalOrder' => 'negative-to-positive',
          'histogramScale' => 'normal',
          'histogramIgnoreZeros' => true,
          'metadataHistogramOptions' => {},
          'showGrid' => true,
          'showAxes' => true,
          'showCategories' => true,
          'showLabelBoxes' => true,
          'labelFontSizeMode' => label_font[:mode],
          'labelFontSize' => label_font[:size],
          'truncateLongLabels' => false,
          'freezeMovedLabels' => true,
          'labelPlacementMode' => 'avoid-collisions',
          'manualLabelLocks' => {}
        },
        'customPlotWindow' => nil,
        'interaction' => {
          'mode' => 'pick',
          'bounds' => nil
        },
        'selection' => {
          'selectedCells' => [],
          'activeTab' => 'gene-sets'
        }
      }
    end

    # Matches visualization UI: Small = 10 with manual mode.
    LANDING_LABEL_FONT_SMALL_SIZE = 10
    LANDING_LABEL_MAX_LENGTH_FOR_DEFAULT_SIZE = 15

    def landing_label_font_settings(coloring)
      max_len = max_category_label_length(coloring)
      if max_len > LANDING_LABEL_MAX_LENGTH_FOR_DEFAULT_SIZE
        { mode: 'manual', size: LANDING_LABEL_FONT_SMALL_SIZE }
      else
        { mode: 'auto', size: 12 }
      end
    end

    def max_category_label_length(annot)
      labels = category_labels_for_font_size(annot)
      return 0 if labels.empty?

      labels.map { |label| label.to_s.length }.max
    end

    def category_labels_for_font_size(annot)
      if annot.categories_json.present?
        parsed = JSON.parse(annot.categories_json)
        if parsed.is_a?(Hash) && parsed.any?
          return parsed.keys.map(&:to_s)
        end
        if parsed.is_a?(Array) && parsed.any?
          return parsed.map(&:to_s)
        end
      end

      annot.distinct_category_labels_from_list_cat_json
    end

    def archive_project!(project)
      raise Error, 'Archive callback not configured' unless @archiver

      @logger.info("[ExternalCatalog] archive project=#{project.key}")
      result = @archiver.call(project)
      if result == :failed
        raise Error, "Archive failed for project=#{project.key}"
      end
      @logger.info("[ExternalCatalog] archive result=#{result} project=#{project.key}")
      result
    end
  end
end
