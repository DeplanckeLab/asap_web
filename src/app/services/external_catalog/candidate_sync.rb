# frozen_string_literal: true

module ExternalCatalog
  # Upserts ExternalCatalogCandidate rows from live catalog APIs.
  class CandidateSync
    SOURCES = %w[cellxgene bgee hca geo].freeze

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # Returns { upserted:, by_source: { 'cellxgene' => n, ... } }
    def call(source: 'all', limit: nil, geo_mode: 'all')
      sources =
        case source.to_s.strip.downcase
        when 'all' then SOURCES
        when *SOURCES then [source.to_s.strip.downcase]
        else
          raise ArgumentError, "SOURCE must be all|#{SOURCES.join('|')} (got #{source.inspect})"
        end

      totals = { upserted: 0, by_source: Hash.new(0) }
      sources.each do |src|
        n = sync_source(src, limit: limit, geo_mode: geo_mode)
        totals[:upserted] += n
        totals[:by_source][src] = n
      end
      totals
    end

    private

    def sync_source(source, limit:, geo_mode:)
      upserted = 0
      each_entry(source, limit: limit, geo_mode: geo_mode) do |entry|
        ExternalCatalogCandidate.upsert_from_entry!(entry)
        upserted += 1
      end
      @logger.info("[ExternalCatalog::CandidateSync] source=#{source} upserted=#{upserted}")
      upserted
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
