# frozen_string_literal: true

module ExternalCatalog
  # Upserts ExternalCatalogCandidate rows from live catalog APIs.
  class CandidateSync
    SOURCES = ExternalCatalogCandidate::IMPORT_SOURCE_ORDER

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # Returns { upserted:, marked_obsolete:, deleted_test:, by_source: { ... } }
    def call(source: 'all', limit: nil, geo_mode: 'all')
      sources =
        case source.to_s.strip.downcase
        when 'all' then SOURCES
        when *SOURCES then [source.to_s.strip.downcase]
        else
          raise ArgumentError, "SOURCE must be all|#{SOURCES.join('|')} (got #{source.inspect})"
        end

      totals = {
        upserted: 0,
        marked_obsolete: 0,
        deleted_test: 0,
        by_source: Hash.new(0),
        failed: []
      }
      sources.each do |src|
        result = sync_source(src, limit: limit, geo_mode: geo_mode)
        totals[:upserted] += result[:upserted]
        totals[:marked_obsolete] += result[:marked_obsolete]
        totals[:deleted_test] += result[:deleted_test]
        totals[:by_source][src] = result[:upserted]
        next if result[:error].blank?

        totals[:failed] << { source: src, error: "#{result[:error].class}: #{result[:error].message}" }
      end
      totals
    end

    private

    def sync_source(source, limit:, geo_mode:)
      upserted = 0
      seen_external_ids = []
      enumeration_error = nil
      begin
        each_entry(source, limit: limit, geo_mode: geo_mode) do |entry|
          ExternalCatalogCandidate.upsert_from_entry!(entry)
          seen_external_ids << entry.external_id.to_s
          upserted += 1
        end
      rescue StandardError => e
        enumeration_error = e
        @logger.error(
          "[ExternalCatalog::CandidateSync] source=#{source} incomplete enumeration; skip prune: " \
          "#{e.class}: #{e.message}"
        )
      end

      if enumeration_error.nil? && seen_external_ids.empty?
        enumeration_error = StandardError.new(
          "source=#{source} yielded 0 entries; skip prune"
        )
        @logger.error(
          "[ExternalCatalog::CandidateSync] #{enumeration_error.message}"
        )
      end

      marked_obsolete = 0
      deleted_test = 0
      # Partial or failed walks must not mark unseen rows as obsolete.
      if limit.blank? && enumeration_error.nil?
        prune = prune_missing_for_source!(source, seen_external_ids)
        marked_obsolete = prune[:marked_obsolete]
        deleted_test = prune[:deleted_test]
      end

      @logger.info(
        "[ExternalCatalog::CandidateSync] source=#{source} upserted=#{upserted} " \
        "marked_obsolete=#{marked_obsolete} deleted_test=#{deleted_test}"
      )
      {
        upserted: upserted,
        marked_obsolete: marked_obsolete,
        deleted_test: deleted_test,
        error: enumeration_error
      }
    end

    def prune_missing_for_source!(source, seen_external_ids)
      marked_obsolete = 0
      deleted_test = 0
      scope = ExternalCatalogCandidate.for_source(source)
      scope = scope.where.not(external_id: seen_external_ids) if seen_external_ids.any?
      scope.find_each do |candidate|
        if candidate.test_entry? && !candidate.has_attached_asap_projects?
          candidate.destroy!
          deleted_test += 1
          next
        end

        next if candidate.obsolete?

        candidate.update!(obsolete: true)
        marked_obsolete += 1
      end
      { marked_obsolete: marked_obsolete, deleted_test: deleted_test }
    end

    def each_entry(source, limit:, geo_mode:)
      case source
      when 'cellxgene'
        CellxgeneCatalog.new(logger: @logger).each(limit: limit) { |e| yield e }
      when 'bgee'
        BgeeCatalog.new(logger: @logger).each(limit: limit) { |e| yield e }
      when 'hca'
        HcaCatalog.new(logger: @logger).each(limit: limit) { |e| yield e }
      when 'geo'
        GeoCatalog.new(logger: @logger).each(limit: limit, mode: geo_mode) { |e| yield e }
      end
    end
  end
end
