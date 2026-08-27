# frozen_string_literal: true

module ExternalCatalog
  # Enqueues standalone scFAIR validations (download + IsolatedComplianceValidationJob)
  # for single-cell external catalog candidates that expose loom/h5ad URLs.
  class StandaloneScfairBatchValidator
    STANDALONE_FORMATS = %w[loom h5ad].freeze
    CANDIDATE_TABLE = ExternalCatalogCandidate.table_name

    Result = Struct.new(
      :queued,
      :skipped_existing,
      :skipped_unsupported,
      :skipped_blank_url,
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
      candidate_ids: nil
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
    end

    def call
      upload_type_id = UploadType.id_for('compliance_file_check')
      raise ArgumentError, 'compliance_file_check upload type is missing' if upload_type_id.blank?

      queued = 0
      skipped_unsupported = 0
      skipped_blank_url = 0
      scanned = 0
      skipped_existing = (@skip_existing || @retry_failed) ? count_already_validated : 0

      # LIMIT is "enqueue up to N new validations", not "take N candidates then skip".
      catch(:limit_reached) do
        each_candidate do |candidate|
          scanned += 1
          url = candidate.url.to_s.strip
          if url.blank?
            skipped_blank_url += 1
            next
          end

          unless standalone_format?(candidate)
            skipped_unsupported += 1
            next
          end

          # Defensive: still skip if a race inserted a check after the SQL exclude.
          if (@skip_existing || @retry_failed) && already_validated?(url)
            next
          end

          if @dry_run
            queued += 1
          else
            enqueue_candidate!(candidate, url, upload_type_id)
            queued += 1
          end

          throw :limit_reached if @limit && queued >= @limit
        end
      end

      Result.new(
        queued: queued,
        skipped_existing: skipped_existing,
        skipped_unsupported: skipped_unsupported,
        skipped_blank_url: skipped_blank_url,
        candidates: scanned
      )
    end

    private

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

    def candidate_scope
      scope = ExternalCatalogCandidate.current.for_project_type('sc').non_test_entry
      scope = scope.where(id: @candidate_ids) if @candidate_ids
      if @source.present? && @source != 'all'
        unless ExternalCatalogCandidate::SOURCES.include?(@source)
          raise ArgumentError,
                "SOURCE must be all|#{ExternalCatalogCandidate::SOURCES.join('|')} (got #{@source.inspect})"
        end
        scope = scope.for_source(@source)
      end
      if @max_filesize
        scope = scope.where('filesize = 0 OR filesize <= ?', @max_filesize)
      end
      scope
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

    def enqueue_candidate!(candidate, url, upload_type_id)
      uri = URI.parse(url)
      raise ArgumentError, "Invalid URL for candidate ##{candidate.id}: #{url}" unless uri.is_a?(URI::HTTP)

      original_filename =
        candidate.filename.to_s.presence ||
        File.basename(uri.path).presence ||
        "#{candidate.source}_#{candidate.external_id}"

      task_id = SecureRandom.uuid
      fu = Fu.create!(
        upload_file_name: 'pending.download',
        upload_file_size: 0,
        name: original_filename,
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
