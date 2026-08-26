# frozen_string_literal: true

module ExternalCatalog
  # Enqueues standalone scFAIR validations (download + IsolatedComplianceValidationJob)
  # for single-cell external catalog candidates that expose loom/h5ad URLs.
  class StandaloneScfairBatchValidator
    STANDALONE_FORMATS = %w[loom h5ad].freeze

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
      max_filesize: nil,
      candidate_ids: nil
    )
      @source = source.to_s.strip.presence
      @limit = limit.present? ? Integer(limit) : nil
      @schema_id = schema_id.to_s.presence || Scfair::Rules::DEFAULT_SCHEMA_ID
      @user = user
      @dry_run = dry_run
      @skip_existing = skip_existing
      @max_filesize = max_filesize.present? ? Integer(max_filesize) : nil
      @candidate_ids = Array(candidate_ids).compact.map(&:to_i).reject(&:zero?).presence
    end

    def call
      upload_type_id = UploadType.id_for('compliance_file_check')
      raise ArgumentError, 'compliance_file_check upload type is missing' if upload_type_id.blank?

      queued = 0
      skipped_existing = 0
      skipped_unsupported = 0
      skipped_blank_url = 0
      candidates = select_candidates

      candidates.each do |candidate|
        url = candidate.url.to_s.strip
        if url.blank?
          skipped_blank_url += 1
          next
        end

        unless standalone_format?(candidate)
          skipped_unsupported += 1
          next
        end

        if @skip_existing && already_validated?(url)
          skipped_existing += 1
          next
        end

        if @dry_run
          queued += 1
          next
        end

        enqueue_candidate!(candidate, url, upload_type_id)
        queued += 1
      end

      Result.new(
        queued: queued,
        skipped_existing: skipped_existing,
        skipped_unsupported: skipped_unsupported,
        skipped_blank_url: skipped_blank_url,
        candidates: candidates.size
      )
    end

    private

    def select_candidates
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
      scope = scope.ordered_by_size
      @limit ? scope.limit(@limit).to_a : scope.to_a
    end

    def standalone_format?(candidate)
      kind = candidate.format_kind.to_s.downcase.presence
      return STANDALONE_FORMATS.include?(kind) if kind.present?

      ext = File.extname(candidate.filename.to_s.presence || candidate.url.to_s).downcase
      STANDALONE_FORMATS.include?(ext.delete_prefix('.'))
    end

    def already_validated?(url)
      StandaloneComplianceCheck.where(source_url: url, admin_run: true).exists?
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
