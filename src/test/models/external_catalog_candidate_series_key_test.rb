# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogCandidateSeriesKeyTest < ActiveSupport::TestCase
  test 'build_series_key prefers DOI over GEO and collection' do
    key = ExternalCatalogCandidate.build_series_key(
      source: 'cellxgene',
      external_id: 'dataset-1',
      dois: ['https://doi.org/10.1016/j.isci.2022.104097'],
      identifiers: [{ kind: 'geo_series', value: 'GSE190094' }],
      collection_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    )

    assert_equal 'doi:10.1016/j.isci.2022.104097', key
  end

  test 'build_series_key uses geo_series when DOI missing' do
    key = ExternalCatalogCandidate.build_series_key(
      source: 'cellxgene',
      external_id: 'dataset-1',
      dois: [],
      identifiers: [{ kind: 'geo_series', value: 'GSE190094' }],
      collection_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    )

    assert_equal 'geo_series:GSE190094', key
  end

  test 'build_series_key uses collection when DOI and GEO missing' do
    key = ExternalCatalogCandidate.build_series_key(
      source: 'cellxgene',
      external_id: 'dataset-1',
      dois: [],
      identifiers: [],
      collection_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    )

    assert_equal 'collection:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', key
  end

  test 'build_series_key for GEO source uses external_id' do
    key = ExternalCatalogCandidate.build_series_key(
      source: 'geo',
      external_id: 'gse12345',
      dois: [],
      identifiers: [],
      collection_id: nil
    )

    assert_equal 'geo_series:GSE12345', key
  end

  test 'collection_id_from_source_page_url parses CELLxGENE collection URL' do
    url = 'https://cellxgene.cziscience.com/collections/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    assert_equal 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
                 ExternalCatalogCandidate.collection_id_from_source_page_url(url)
  end

  test 'upsert_from_entry assigns series_key and collection_id' do
    entry = ExternalCatalog::Entry.new(
      source: 'cellxgene',
      external_id: "ds-#{SecureRandom.hex(4)}",
      title: 'Spatial transcriptomics in mouse: Puck_1',
      url: 'https://example.com/file.h5ad',
      tax_id: 10090,
      organism_label: 'Mus musculus',
      filesize: 100,
      project_type_tag: 'sc',
      format_kind: :h5ad,
      filename: 'file.h5ad',
      dois: ['10.1016/j.isci.2022.104097'],
      pmids: [],
      identifiers: [{ kind: 'geo_series', value: 'GSE190094' }],
      source_page_url: 'https://cellxgene.cziscience.com/collections/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      collection_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    )

    record = ExternalCatalogCandidate.upsert_from_entry!(entry)

    assert_equal 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', record.collection_id
    assert_equal 'doi:10.1016/j.isci.2022.104097', record.series_key
  ensure
    record&.destroy
  end

  test 'ordered_for_catalog groups by collection then title even when DOI series_keys differ' do
    suffix = SecureRandom.hex(3)
    figure_collection = "7dd599c5-d25d-40c0-b1a6-#{suffix}"
    mouse_collection = "c69bd2e0-32fe-431d-b855-#{suffix}"
    figure1 = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "fig1-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'Figure 1',
      dois_json: ['10.1002/ctm2.1356'].to_json,
      collection_id: figure_collection,
      import_status: 'idle',
      tax_id: 9606
    )
    figure2 = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "fig2-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'Figure 2',
      dois_json: ['10.1002/ctm2.1356'].to_json,
      collection_id: figure_collection,
      import_status: 'idle',
      tax_id: 9606
    )
    mouse1 = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "mouse1-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'Mouse 1',
      collection_id: mouse_collection,
      import_status: 'idle',
      tax_id: 10090
    )
    mouse2 = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "mouse2-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'Mouse 2',
      collection_id: mouse_collection,
      import_status: 'idle',
      tax_id: 10090
    )
    figure3 = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "fig3-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'Figure 3',
      dois_json: ['10.1002/ctm2.1356'].to_json,
      collection_id: figure_collection,
      import_status: 'idle',
      tax_id: 9606
    )

    ordered = ExternalCatalogCandidate.where(
      id: [figure1.id, figure2.id, figure3.id, mouse1.id, mouse2.id]
    ).ordered_for_catalog.to_a

    assert_equal ['Figure 1', 'Figure 2', 'Figure 3', 'Mouse 1', 'Mouse 2'],
                 ordered.map(&:title)
  ensure
    ExternalCatalogCandidate.where(
      id: [figure1&.id, figure2&.id, figure3&.id, mouse1&.id, mouse2&.id].compact
    ).delete_all
  end

  test 'take_for_import finishes the last collection when COUNT would split it' do
    suffix = SecureRandom.hex(3)
    mouse_collection = "aaaa1111-32fe-431d-b855-#{suffix}"
    figure_collection = "bbbb2222-d25d-40c0-b1a6-#{suffix}"
    rows = []
    ['Mouse 1', 'Mouse 2'].each_with_index do |title, i|
      rows << ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: "mouse#{i}-#{suffix}",
        provider_tag: 'CELLxGENE',
        title: title,
        collection_id: mouse_collection,
        import_status: 'idle',
        tax_id: 10090
      )
    end
    ['Figure 1', 'Figure 2', 'Figure 3'].each_with_index do |title, i|
      rows << ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: "fig#{i}-#{suffix}",
        provider_tag: 'CELLxGENE',
        title: title,
        dois_json: ['10.1002/ctm2.1356'].to_json,
        collection_id: figure_collection,
        import_status: 'idle',
        tax_id: 9606
      )
    end

    taken = ExternalCatalogCandidate.where(id: rows.map(&:id)).take_for_import(3)

    assert_equal ['Mouse 1', 'Mouse 2', 'Figure 1', 'Figure 2', 'Figure 3'],
                 taken.map(&:title)
  ensure
    ExternalCatalogCandidate.where(id: rows&.map(&:id)).delete_all
  end

  test 'take_for_import does not overflow when the batch is a single collection' do
    suffix = SecureRandom.hex(3)
    collection_id = "cccc3333-d25d-40c0-b1a6-#{suffix}"
    rows = (1..4).map do |i|
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: "only#{i}-#{suffix}",
        provider_tag: 'CELLxGENE',
        title: "Only #{i}",
        collection_id: collection_id,
        import_status: 'idle',
        tax_id: 9606
      )
    end

    taken = ExternalCatalogCandidate.where(id: rows.map(&:id)).take_for_import(2)
    assert_equal ['Only 1', 'Only 2'], taken.map(&:title)
  ensure
    ExternalCatalogCandidate.where(id: rows&.map(&:id)).delete_all
  end

  test 'ordered_for_catalog groups by series_key then title' do
    suffix = SecureRandom.hex(3)
    a = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "a-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'B title',
      dois_json: ['10.1/aaa'].to_json,
      import_status: 'idle',
      tax_id: 9606
    )
    b = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "b-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'A title',
      dois_json: ['10.1/aaa'].to_json,
      import_status: 'idle',
      tax_id: 9606
    )
    c = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "c-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'C title',
      dois_json: ['10.1/bbb'].to_json,
      import_status: 'idle',
      tax_id: 9606
    )

    ordered = ExternalCatalogCandidate.where(id: [a.id, b.id, c.id]).ordered_for_catalog.to_a
    assert_equal [b.id, a.id, c.id], ordered.map(&:id)
  ensure
    ExternalCatalogCandidate.where(id: [a&.id, b&.id, c&.id].compact).delete_all
  end

  test 'ordered_for_catalog prefers CELLxGENE then Bgee then EBI SC then HCA then HuBMAP then Broad SCP then Allen ABC then MATKP then GEO' do
    suffix = SecureRandom.hex(3)
    geo = ExternalCatalogCandidate.create!(
      source: 'geo',
      external_id: "GSE#{suffix}",
      provider_tag: 'GEO',
      title: 'Geo last',
      import_status: 'idle',
      tax_id: 9606,
      url: 'https://example.com/geo'
    )
    matkp = ExternalCatalogCandidate.create!(
      source: 'matkp',
      external_id: "matkp-#{suffix}",
      provider_tag: 'MATKP',
      title: 'Matkp eighth',
      import_status: 'idle',
      tax_id: 9606,
      url: 'https://example.com/matkp'
    )
    allen = ExternalCatalogCandidate.create!(
      source: 'allen_abc',
      external_id: "allen-#{suffix}",
      provider_tag: 'ALLEN_ABC',
      title: 'Allen seventh',
      import_status: 'idle',
      tax_id: 9606,
      url: 'https://example.com/allen'
    )
    broad = ExternalCatalogCandidate.create!(
      source: 'broad_scp',
      external_id: "SCP#{suffix}",
      provider_tag: 'BROAD_SCP',
      title: 'Broad sixth',
      import_status: 'idle',
      tax_id: 9606,
      url: 'https://example.com/broad'
    )
    hubmap = ExternalCatalogCandidate.create!(
      source: 'hubmap',
      external_id: "HBM#{suffix}",
      provider_tag: 'HUBMAP',
      title: 'Hubmap fifth',
      import_status: 'idle',
      tax_id: 9606,
      url: 'https://example.com/hubmap'
    )
    hca = ExternalCatalogCandidate.create!(
      source: 'hca',
      external_id: "hca-#{suffix}",
      provider_tag: 'HCA',
      title: 'Hca fourth',
      import_status: 'idle',
      tax_id: 9606,
      url: 'https://example.com/hca'
    )
    ebi = ExternalCatalogCandidate.create!(
      source: 'ebi_sc',
      external_id: "E-CURD-#{suffix}",
      provider_tag: 'EBI_SC',
      title: 'EBI third',
      import_status: 'idle',
      tax_id: 9606,
      url: 'https://example.com/ebi'
    )
    bgee = ExternalCatalogCandidate.create!(
      source: 'bgee',
      external_id: "bgee-#{suffix}",
      provider_tag: 'Bgee',
      title: 'Bgee second',
      import_status: 'idle',
      tax_id: 9606,
      url: 'https://example.com/bgee'
    )
    cxg = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "cxg-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'Cellxgene first',
      import_status: 'idle',
      tax_id: 9606,
      url: 'https://example.com/cxg'
    )

    ordered = ExternalCatalogCandidate.where(
      id: [geo.id, matkp.id, allen.id, broad.id, hubmap.id, hca.id, ebi.id, bgee.id, cxg.id]
    ).ordered_for_catalog.to_a
    assert_equal %w[cellxgene bgee ebi_sc hca hubmap broad_scp allen_abc matkp geo],
                 ordered.map(&:source)
    assert_equal ExternalCatalogCandidate::IMPORT_SOURCE_ORDER, ExternalCatalog::CandidateSync::SOURCES
  ensure
    ExternalCatalogCandidate.where(
      id: [geo&.id, matkp&.id, allen&.id, broad&.id, hubmap&.id, hca&.id, ebi&.id, bgee&.id, cxg&.id].compact
    ).delete_all
  end

  test 'ordered_by_size sorts by n_obs then n_vars then filesize' do
    suffix = SecureRandom.hex(3)
    large = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "large-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'Large',
      import_status: 'idle',
      n_obs: 100_000,
      n_vars: 20_000,
      filesize: 10,
      url: 'https://example.com/large'
    )
    small = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "small-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'Small',
      import_status: 'idle',
      n_obs: 500,
      n_vars: 10_000,
      filesize: 99,
      url: 'https://example.com/small'
    )
    unknown = ExternalCatalogCandidate.create!(
      source: 'geo',
      external_id: "GSE#{suffix}",
      provider_tag: 'GEO',
      title: 'Unknown dims',
      import_status: 'idle',
      filesize: 1,
      url: 'https://example.com/geo'
    )

    ordered = ExternalCatalogCandidate.where(id: [large.id, small.id, unknown.id]).ordered_by_size.to_a
    assert_equal [small.id, large.id, unknown.id], ordered.map(&:id)
  ensure
    ExternalCatalogCandidate.where(id: [large&.id, small&.id, unknown&.id].compact).delete_all
  end

  test 'for_n_obs_between filters by cell or sample count and omits unknown' do
    suffix = SecureRandom.hex(3)
    tiny = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "tiny-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'Tiny',
      import_status: 'idle',
      n_obs: 100,
      url: 'https://example.com/tiny'
    )
    mid = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "mid-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'Mid',
      import_status: 'idle',
      n_obs: 5_000,
      url: 'https://example.com/mid'
    )
    huge = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "huge-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'Huge',
      import_status: 'idle',
      n_obs: 200_000,
      url: 'https://example.com/huge'
    )
    unknown = ExternalCatalogCandidate.create!(
      source: 'geo',
      external_id: "GSE#{suffix}",
      provider_tag: 'GEO',
      title: 'Unknown',
      import_status: 'idle',
      url: 'https://example.com/unknown'
    )

    ids = [tiny.id, mid.id, huge.id, unknown.id]
    filtered = ExternalCatalogCandidate.where(id: ids).for_n_obs_between(500, 50_000).pluck(:id)
    assert_equal [mid.id], filtered

    only_min = ExternalCatalogCandidate.where(id: ids).for_n_obs_between(5_000, nil).pluck(:id).sort
    assert_equal [huge.id, mid.id].sort, only_min
  ensure
    ExternalCatalogCandidate.where(id: [tiny&.id, mid&.id, huge&.id, unknown&.id].compact).delete_all
  end
end
