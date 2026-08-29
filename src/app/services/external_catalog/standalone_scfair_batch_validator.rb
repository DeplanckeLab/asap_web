# frozen_string_literal: true

module ExternalCatalog
  # Enqueues standalone scFAIR validations (download + IsolatedComplianceValidationJob)
  # for single-cell external catalog candidates that expose loom/h5ad URLs, and for
  # public ASAP sc-like projects (via get_file URLs of their matrix loom files).
  class StandaloneScfairBatchValidator
    STANDALONE_FORMATS = %w[loom h5ad].freeze
    ASAP_SOURCE = 'asap'
    CANDIDATE_TABLE = ExternalCatalogCandidate.table_name
    ALLOWED_SOURCES = (ExternalCatalogCandidate::SOURCES + [ASAP_SOURCE]).freeze

    Result = Struct.new(
      :queued,
      :skipped_existing,
      :skipped_unsupported,
      :skipped_blank_url,
      :skipped_missing_file,
      :candidates,
      keyword_init: true
    )

    def initialize(
      source: nil,
      limit: nil,
      schema_id: nil,
      user: nil,
      dry_run: false,
      skip_existing: true,
      retry_failed: false,
      max_filesize: nil,
      candidate_ids: nil,
      project_ids: nil,
      public_ids: nil
    )
      @source = source.to_s.strip.presence
      @limit = limit.present? ? Integer(limit) : nil
      @schema_id = schema_id.to_s.presence || Scfair::Rules::DEFAULT_SCHEMA_ID
      @user = user
      @dry_run = dry_run
      @skip_existing = skip_existing
      @retry_failed = retry_failed
      @max_filesize = max_filesize.present? ? Integer(max_filesize) : nil
      @candidate_ids = Array(candidate_ids).compact.map(&:to_i).reject(&:zero?).presence
      @project_ids = Array(project_ids).compact.map(&:to_i).reject(&:zero?).presence
      @public_ids = Array(public_ids).compact.map(&:to_i).reject(&:zero?).presence
      validate_source!
    end

    def call
      upload_type_id = UploadType.id_for('compliance_file_check')
      raise ArgumentError, 'compliance_file_check upload type is missing' if upload_type_id.blank?

      @queued = 0
      @skipped_unsupported = 0
      @skipped_blank_url = 0
      @skipped_missing_file = 0
      @scanned = 0
      @skipped_existing = (@skip_existing || @retry_failed) ? count_already_validated : 0

      # LIMIT is "enqueue up to N new validations", not "take N candidates then skip".
      catch(:limit_reached) do
        process_catalog_candidates(upload_type_id) if include_catalog?
        process_asap_projects(upload_type_id) if include_asap?
      end

      Result.new(
        queued: @queued,
        skipped_existing: @skipped_existing,
        skipped_unsupported: @skipped_unsupported,
        skipped_blank_url: @skipped_blank_url,
        skipped_missing_file: @skipped_missing_file,
        candidates: @scanned
      )
    end

    private

    def validate_source!
      return if @source.blank? || @source == 'all'
      return if ALLOWED_SOURCES.include?(@source)

      raise ArgumentError,
            "SOURCE must be all|#{ALLOWED_SOURCES.join('|')} (got #{@source.inspect})"
    end

    def include_catalog?
      @source != ASAP_SOURCE
    end

    def include_asap?
      return true if @source == ASAP_SOURCE
      return false unless @source.blank? || @source == 'all'

      # CANDIDATE_IDS alone scopes a catalog-only batch; include ASAP when unrestricted
      # or when PROJECT_IDS / PUBLIC_IDS explicitly select public projects.
      @candidate_ids.blank? || @project_ids.present? || @public_ids.present?
    end

    def process_catalog_candidates(upload_type_id)
      each_candidate do |candidate|
        @scanned += 1
        url = candidate.url.to_s.strip
        if url.blank?
          @skipped_blank_url += 1
          next
        end

        unless standalone_format?(candidate)
          @skipped_unsupported += 1
          next
        end

        # Defensive: still skip if a race inserted a check after the SQL exclude.
        if (@skip_existing || @retry_failed) && already_validated?(url)
          next
        end

        enqueue_or_count!(
          url: url,
          filename: candidate_filename(candidate, url),
          upload_type_id: upload_type_id
        )
      end
    end

    def process_asap_projects(upload_type_id)
      each_asap_project do |project|
        @scanned += 1
        loom_rel = primary_matrix_loom_rel(project)
        if loom_rel.blank?
          @skipped_missing_file += 1
          next
        end

        abs = project.storage_dir.join(loom_rel)
        unless File.exist?(abs)
          @skipped_missing_file += 1
          next
        end

        url = Basic.data_file_url_for_project(project, loom_rel)
        if url.blank?
          @skipped_blank_url += 1
          next
        end

        if (@skip_existing || @retry_failed) && already_validated?(url)
          next
        end

        enqueue_or_count!(
          url: url,
          filename: "ASAP#{project.public_id}_#{File.basename(loom_rel)}",
          upload_type_id: upload_type_id
        )
      end
    end

    def enqueue_or_count!(url:, filename:, upload_type_id:)
      if @dry_run
        @queued += 1
      else
        enqueue_url!(url: url, filename: filename, upload_type_id: upload_type_id)
        @queued += 1
      end

      throw :limit_reached if @limit && @queued >= @limit
    end

    def each_candidate
      scope = candidate_scope
      scope = restrict_to_failed_retries(scope) if @retry_failed
      scope = exclude_already_validated(scope) if @skip_existing || @retry_failed
      scope = scope.ordered_by_size

      # find_each ignores ORDER BY; walk in ordered pages instead.
      offset = 0
      page_size = 100
      loop do
        batch = scope.offset(offset).limit(page_size).to_a
        break if batch.empty?

        batch.each { |candidate| yield candidate }

        offset += page_size
        break if batch.size < page_size
      end
    end

    def each_asap_project
      projects = asap_project_scope.to_a
      projects = projects.select { |p| asap_project_eligible_for_retry?(p) } if @retry_failed
      projects = projects.reject { |p| asap_project_already_validated?(p) } if @skip_existing || @retry_failed
      projects = projects.select { |p| asap_within_max_filesize?(p) } if @max_filesize
      projects = sort_asap_projects(projects)

      projects.each { |project| yield project }
    end

    def asap_within_max_filesize?(project)
      loom_rel = primary_matrix_loom_rel(project)
      return true if loom_rel.blank?

      abs = project.storage_dir.join(loom_rel)
      return true unless File.exist?(abs)

      File.size(abs) <= @max_filesize
    end

    def candidate_scope
      scope = ExternalCatalogCandidate.current.for_project_type('sc').non_test_entry
      scope = scope.where(id: @candidate_ids) if @candidate_ids
      if @source.present? && @source != 'all' && @source != ASAP_SOURCE
        scope = scope.for_source(@source)
      end
      if @max_filesize
        scope = scope.where('filesize = 0 OR filesize <= ?', @max_filesize)
      end
      scope
    end

    def asap_project_scope
      sc_type_ids = ProjectType.where(tag: ProjectType::SC_LIKE_TAGS).pluck(:id)
      scope = Project.public_projects.not_deleted.where(project_type_id: sc_type_ids)
      scope = scope.where(id: @project_ids) if @project_ids
      scope = scope.where(public_id: @public_ids) if @public_ids
      scope.where.not(public_id: nil).order(:public_id)
    end

    def sort_asap_projects(projects)
      projects.sort_by do |project|
        loom_rel = primary_matrix_loom_rel(project)
        size =
          if loom_rel.present?
            abs = project.storage_dir.join(loom_rel)
            File.exist?(abs) ? File.size(abs) : Float::INFINITY
          else
            Float::INFINITY
          end
        [size, project.public_id.to_i]
      end
    end

    def primary_matrix_loom_rel(project)
      rels = Basic.project_matrix_loom_rels(project)
      return nil if rels.empty?

      preferred = rels.find { |rel| rel.to_s == 'parsing/output.loom' }
      preferred || rels.first
    end

    def asap_entry_url(project)
      loom_rel = primary_matrix_loom_rel(project)
      return nil if loom_rel.blank?

      Basic.data_file_url_for_project(project, loom_rel)
    end

    def asap_project_already_validated?(project)
      url = asap_entry_url(project)
      return false if url.blank?

      already_validated?(url)
    end

    def asap_project_eligible_for_retry?(project)
      url = asap_entry_url(project)
      return false if url.blank?

      StandaloneComplianceCheck.where(source_url: url, admin_run: true, status: 'failed').exists?
    end

    # RETRY_FAILED: only URLs that already have an admin check with status=failed.
    def restrict_to_failed_retries(scope)
      scope.where(
        <<~SQL.squish
          EXISTS (
            SELECT 1
            FROM standalone_compliance_checks scc
            WHERE scc.admin_run = TRUE
              AND scc.status = 'failed'
              AND scc.source_url IS NOT NULL
              AND scc.source_url <> ''
              AND scc.source_url = #{CANDIDATE_TABLE}.url
          )
        SQL
      )
    end

    # Skip URLs that already have a finished admin result.
    # With RETRY_FAILED, only completed rows block retry (failed rows are eligible again).
    def exclude_already_validated(scope)
      status_clause = @retry_failed ? "AND scc.status = 'completed'" : ''
      scope.where(
        <<~SQL.squish
          NOT EXISTS (
            SELECT 1
            FROM standalone_compliance_checks scc
            WHERE scc.admin_run = TRUE
              AND scc.source_url IS NOT NULL
              AND scc.source_url <> ''
              AND scc.source_url = #{CANDIDATE_TABLE}.url
              #{status_clause}
          )
        SQL
      )
    end

    def count_already_validated
      catalog_count = include_catalog? ? count_catalog_already_validated : 0
      asap_count = include_asap? ? count_asap_already_validated : 0
      catalog_count + asap_count
    end

    def count_catalog_already_validated
      status_clause = @retry_failed ? "AND scc.status = 'completed'" : ''
      candidate_scope.where(
        <<~SQL.squish
          EXISTS (
            SELECT 1
            FROM standalone_compliance_checks scc
            WHERE scc.admin_run = TRUE
              AND scc.source_url IS NOT NULL
              AND scc.source_url <> ''
              AND scc.source_url = #{CANDIDATE_TABLE}.url
              #{status_clause}
          )
        SQL
      ).count
    end

    def count_asap_already_validated
      asap_project_scope.to_a.count do |project|
        if @retry_failed
          url = asap_entry_url(project)
          next false if url.blank?

          StandaloneComplianceCheck.where(source_url: url, admin_run: true, status: 'completed').exists?
        else
          asap_project_already_validated?(project)
        end
      end
    end

    def standalone_format?(candidate)
      kind = candidate.format_kind.to_s.downcase.presence
      return STANDALONE_FORMATS.include?(kind) if kind.present?

      ext = File.extname(candidate.filename.to_s.presence || candidate.url.to_s).downcase
      STANDALONE_FORMATS.include?(ext.delete_prefix('.'))
    end

    def already_validated?(url)
      scope = StandaloneComplianceCheck.where(source_url: url, admin_run: true)
      scope = scope.where(status: 'completed') if @retry_failed
      scope.exists?
    end

    def candidate_filename(candidate, url)
      candidate.filename.to_s.presence ||
        File.basename(URI.parse(url).path).presence ||
        "#{candidate.source}_#{candidate.external_id}"
    rescue URI::InvalidURIError
      "#{candidate.source}_#{candidate.external_id}"
    end

    def enqueue_url!(url:, filename:, upload_type_id:)
      uri = URI.parse(url)
      raise ArgumentError, "Invalid URL: #{url}" unless uri.is_a?(URI::HTTP)

      task_id = SecureRandom.uuid
      fu = Fu.create!(
        upload_file_name: 'pending.download',
        upload_file_size: 0,
        name: filename,
        status: 'downloading',
        upload_type: upload_type_id,
        user_id: @user&.id,
        url: uri.to_s,
        compliance_schema_id: @schema_id,
        compliance_task_id: task_id,
        admin_run: true,
        creator_ip: nil
      )

      IsolatedComplianceStatusStore.write(
        task_id,
        {
          status: 'downloading',
          task_id: task_id,
          progress: 0,
          transfer_progress: 0,
          message: 'Downloading file...',
          fu_id: fu.id
        }
      )
      IsolatedComplianceUrlDownloadJob.perform_later(fu.id)
      fu
    end
  end
end
