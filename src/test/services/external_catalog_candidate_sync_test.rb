# frozen_string_literal: true

require 'logger'
require 'test_helper'

class ExternalCatalogCandidateSyncTest < ActiveSupport::TestCase
  class EmptyCatalog
    def each(limit: nil, mode: nil); end
  end

  class YieldCatalog
    def initialize(entry)
      @entry = entry
    end

    def each(limit: nil, mode: nil)
      yield @entry
    end
  end

  class YieldThenFailCatalog
    def initialize(entry, error)
      @entry = entry
      @error = error
    end

    def each(limit: nil, mode: nil)
      yield @entry
      raise @error
    end
  end

  class FailCatalog
    def initialize(error)
      @error = error
    end

    def each(limit: nil, mode: nil)
      raise @error
    end
  end

  class SyncWithCatalogs < ExternalCatalog::CandidateSync
    def initialize(catalogs:, logger:)
      super(logger: logger)
      @catalogs = catalogs
    end

    def each_entry(source, limit:, geo_mode:)
      catalog = @catalogs.fetch(source)
      if source == 'geo'
        catalog.each(limit: limit, mode: geo_mode) { |entry| yield entry }
      else
        catalog.each(limit: limit) { |entry| yield entry }
      end
    end
  end

  setup do
    @logger = Logger.new(File::NULL)
  end

  test 'does not prune unseen CELLxGENE rows when enumeration is incomplete' do
    suffix = SecureRandom.hex(4)
    unseen = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: "old-#{suffix}",
        provider_tag: 'CELLxGENE',
        title: 'Unseen because collection fetch failed',
        url: "https://example.com/old-#{suffix}.h5ad",
        import_status: 'idle',
        tax_id: 9606
      )
    )
    seen_entry = catalog_entry(
      source: 'cellxgene',
      external_id: "seen-#{suffix}",
      title: 'Fetched before timeout'
    )
    sync = SyncWithCatalogs.new(
      catalogs: {
        'cellxgene' => YieldThenFailCatalog.new(
          seen_entry,
          ExternalCatalog::CellxgeneCatalog::FetchError.new('collection timeout')
        )
      },
      logger: @logger
    )

    totals = sync.call(source: 'cellxgene')
    assert_equal 1, totals[:upserted]
    assert_equal 0, totals[:marked_obsolete]
    assert_equal 1, totals[:failed].size
    assert_equal 'cellxgene', totals[:failed].first[:source]

    seen = ExternalCatalogCandidate.find_by!(source: 'cellxgene', external_id: "seen-#{suffix}")
    register_for_test_cleanup(seen)
    assert_equal false, unseen.reload.obsolete?
    assert_equal false, seen.obsolete?
  end

  test 'SOURCE=all continues later sources after CELLxGENE fails' do
    suffix = SecureRandom.hex(4)
    bgee_entry = catalog_entry(
      source: 'bgee',
      external_id: "ERP#{suffix}",
      title: 'Bgee after CELLxGENE failure'
    )
    sync = SyncWithCatalogs.new(
      catalogs: {
        'cellxgene' => FailCatalog.new(ExternalCatalog::CellxgeneCatalog::FetchError.new('timeout')),
        'bgee' => YieldThenFailCatalog.new(
          bgee_entry,
          ExternalCatalog::CellxgeneCatalog::FetchError.new('stop before prune')
        ),
        'hca' => FailCatalog.new(RuntimeError.new('not walked')),
        'geo' => FailCatalog.new(RuntimeError.new('not walked'))
      },
      logger: @logger
    )

    totals = sync.call(source: 'all')
    assert_equal 1, totals[:upserted]
    assert_equal 0, totals[:by_source]['cellxgene']
    assert_equal 1, totals[:by_source]['bgee']
    assert_includes totals[:failed].map { |row| row[:source] }, 'cellxgene'

    created = ExternalCatalogCandidate.find_by!(source: 'bgee', external_id: "ERP#{suffix}")
    register_for_test_cleanup(created)
    assert_equal 'Bgee after CELLxGENE failure', created.title
  end

  test 'does not prune existing rows when a source yields 0 entries' do
    suffix = SecureRandom.hex(4)
    existing = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'geo',
        external_id: "GSE#{suffix}",
        provider_tag: 'GEO',
        title: 'Must stay current if walk is empty',
        url: "https://example.com/GSE#{suffix}.h5ad",
        import_status: 'idle',
        tax_id: 9606
      )
    )
    sync = SyncWithCatalogs.new(
      catalogs: { 'geo' => EmptyCatalog.new },
      logger: @logger
    )

    totals = sync.call(source: 'geo')
    assert_equal 0, totals[:upserted]
    assert_equal 0, totals[:marked_obsolete]
    assert_equal ['geo'], totals[:failed].map { |row| row[:source] }
    assert_equal false, existing.reload.obsolete?
  end

  private

  def catalog_entry(source:, external_id:, title:)
    ExternalCatalog::Entry.new(
      source: source,
      external_id: external_id,
      title: title,
      url: "https://example.com/#{external_id}.h5ad",
      tax_id: 9606,
      organism_label: 'Homo sapiens',
      filesize: 10,
      project_type_tag: 'sc',
      format_kind: :h5ad,
      filename: "#{external_id}.h5ad",
      dois: [],
      pmids: [],
      identifiers: [],
      source_page_url: "https://example.com/#{external_id}"
    )
  end
end
