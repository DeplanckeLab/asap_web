# frozen_string_literal: true

require 'set'

module ExternalCatalog
  # Upserts ExternalCatalogCandidate rows from live catalog APIs.
  class CandidateSync
    SOURCES = ExternalCatalogCandidate::IMPORT_SOURCE_ORDER

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # Returns { upserted:, marked_obsolete:, deleted_test:, by_source: { ... } }
    # +skip_seen_after+: for GEO, skip FTP/upsert for candidates already last_seen_at >= cutoff
    # (resume after a partial sync). Those ids still count as seen for prune.
    # +geo_only_bulk_samples+: when set, GEO only catalogs bulk series with exactly this many samples.
    def call(source: 'all', limit: nil, geo_mode: 'all', skip_seen_after: nil, geo_only_bulk_samples: nil)
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
        result = sync_source(
          src,
          limit: limit,
          geo_mode: geo_mode,
          skip_seen_after: skip_seen_after,
          geo_only_bulk_samples: geo_only_bulk_samples
        )
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

    def sync_source(source, limit:, geo_mode:, skip_seen_after:, geo_only_bulk_samples:)
      upserted = 0
      skip_accessions = geo_skip_accessions(source, skip_seen_after)
      # Preload so prune keeps rows we intentionally skip (already synced this run).
      seen_external_ids = skip_accessions.to_a
      enumeration_error = nil
      begin
        each_entry(
          source,
          limit: limit,
          geo_mode: geo_mode,
          skip_accessions: skip_accessions,
          only_bulk_samples: geo_only_bulk_samples
        ) do |entry|
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
      # Targeted bulk-sample re-adds must not prune the rest of the GEO catalog.
      if limit.blank? && enumeration_error.nil? && geo_only_bulk_samples.blank?
        prune = prune_missing_for_source!(source, seen_external_ids)
        marked_obsolete = prune[:marked_obsolete]
        deleted_test = prune[:deleted_test]
      end

      @logger.info(
        "[ExternalCatalog::CandidateSync] source=#{source} upserted=#{upserted} " \
        "skipped_seen=#{skip_accessions.size} marked_obsolete=#{marked_obsolete} " \
        "deleted_test=#{deleted_test}"
      )
      {
        upserted: upserted,
        marked_obsolete: marked_obsolete,
        deleted_test: deleted_test,
        error: enumeration_error
      }
    end

    def geo_skip_accessions(source, skip_seen_after)
      return Set.new unless source == 'geo' && skip_seen_after.present?

      cutoff = skip_seen_after.is_a?(Time) ? skip_seen_after : Time.zone.parse(skip_seen_after.to_s)
      raise ArgumentError, "invalid skip_seen_after: #{skip_seen_after.inspect}" if cutoff.nil?

      ids = ExternalCatalogCandidate.where(source: 'geo').where('last_seen_at >= ?', cutoff).pluck(:external_id)
      @logger.info(
        "[ExternalCatalog::CandidateSync] source=geo skip_seen_after=#{cutoff.utc.iso8601} " \
        "skip_accessions=#{ids.size}"
      )
      ids.to_set
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

    def each_entry(source, limit:, geo_mode:, skip_accessions: nil, only_bulk_samples: nil)
      case source
      when 'cellxgene'
        CellxgeneCatalog.new(logger: @logger).each(limit: limit) { |e| yield e }
      when 'bgee'
        BgeeCatalog.new(logger: @logger).each(limit: limit) { |e| yield e }
      when 'ebi_sc'
        EbiScCatalog.new(logger: @logger).each(limit: limit) { |e| yield e }
      when 'hca'
        HcaCatalog.new(logger: @logger).each(limit: limit) { |e| yield e }
      when 'hubmap'
        HubmapCatalog.new(logger: @logger).each(limit: limit) { |e| yield e }
      when 'broad_scp'
        BroadScpCatalog.new(logger: @logger).each(limit: limit) { |e| yield e }
      when 'allen_abc'
        AllenAbcCatalog.new(logger: @logger).each(limit: limit) { |e| yield e }
      when 'matkp'
        MatkpCatalog.new(logger: @logger).each(limit: limit) { |e| yield e }
      when 'geo'
        GeoCatalog.new(logger: @logger).each(
          limit: limit,
          mode: geo_mode,
          skip_accessions: skip_accessions,
          only_bulk_samples: only_bulk_samples
        ) { |e| yield e }
      end
    end
  end
end
