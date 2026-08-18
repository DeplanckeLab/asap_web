# frozen_string_literal: true

require 'logger'
require 'test_helper'

class ExternalCatalogCellxgeneCatalogTest < ActiveSupport::TestCase
  FakeHttp = Struct.new(:code, :body) do
    def success?
      c = code.to_i
      c >= 200 && c < 300
    end
  end

  class CatalogWithHandler < ExternalCatalog::CellxgeneCatalog
    def initialize(handler, logger:)
      super(logger: logger)
      @handler = handler
    end

    def perform_get(url)
      @handler.call(url)
    end

    def backoff_sleep(_seconds); end
  end

  setup do
    @logger = Logger.new(File::NULL)
  end

  test 'retries collection fetch after Net::ReadTimeout then yields the dataset' do
    attempts = 0
    list = FakeHttp.new(200, [{ collection_id: 'c-ok' }].to_json)
    detail = FakeHttp.new(200, collection_payload('c-ok', 'd-ok').to_json)
    catalog = CatalogWithHandler.new(
      lambda { |url|
        if url == ExternalCatalog::CellxgeneCatalog::BASE_URL
          list
        else
          attempts += 1
          raise Net::ReadTimeout if attempts < 3

          detail
        end
      },
      logger: @logger
    )

    entries = catalog.each.to_a
    assert_equal 1, entries.size
    assert_equal 'd-ok', entries.first.external_id
    assert_equal 3, attempts
  end

  test 'raises FetchError after repeated timeouts' do
    collection_calls = 0
    list = FakeHttp.new(200, [{ collection_id: 'c-timeout' }].to_json)
    catalog = CatalogWithHandler.new(
      lambda { |url|
        if url == ExternalCatalog::CellxgeneCatalog::BASE_URL
          list
        else
          collection_calls += 1
          raise Net::ReadTimeout
        end
      },
      logger: @logger
    )

    error = assert_raises(ExternalCatalog::CellxgeneCatalog::FetchError) do
      catalog.each.to_a
    end
    assert_match(/c-timeout/, error.message)
    assert_equal ExternalCatalog::CellxgeneCatalog::HTTP_ATTEMPTS, collection_calls
  end

  test 'does not retry HTTP 404' do
    collection_calls = 0
    list = FakeHttp.new(200, [{ collection_id: 'c-missing' }].to_json)
    catalog = CatalogWithHandler.new(
      lambda { |url|
        if url == ExternalCatalog::CellxgeneCatalog::BASE_URL
          list
        else
          collection_calls += 1
          FakeHttp.new(404, 'missing')
        end
      },
      logger: @logger
    )

    error = assert_raises(ExternalCatalog::CellxgeneCatalog::FetchError) do
      catalog.each.to_a
    end
    assert_match(/c-missing/, error.message)
    assert_equal 1, collection_calls
  end

  test 'skips a failed collection, yields the next, then raises FetchError' do
    list = FakeHttp.new(
      200,
      [{ collection_id: 'c-bad' }, { collection_id: 'c-good' }].to_json
    )
    good = FakeHttp.new(200, collection_payload('c-good', 'd-good').to_json)
    catalog = CatalogWithHandler.new(
      lambda { |url|
        case url
        when ExternalCatalog::CellxgeneCatalog::BASE_URL
          list
        when "#{ExternalCatalog::CellxgeneCatalog::BASE_URL}c-bad"
          raise Net::ReadTimeout
        else
          good
        end
      },
      logger: @logger
    )

    entries = []
    error = assert_raises(ExternalCatalog::CellxgeneCatalog::FetchError) do
      catalog.each { |entry| entries << entry }
    end
    assert_equal ['d-good'], entries.map(&:external_id)
    assert_match(/1 collection/, error.message)
    assert_match(/c-bad/, error.message)
  end

  private

  def collection_payload(collection_id, dataset_id)
    {
      collection_id: collection_id,
      name: "Collection #{collection_id}",
      datasets: [
        {
          dataset_id: dataset_id,
          title: "Dataset #{dataset_id}",
          assets: [
            {
              filetype: 'h5ad',
              url: "https://example.com/#{dataset_id}.h5ad",
              filesize: 12
            }
          ]
        }
      ]
    }
  end
end
