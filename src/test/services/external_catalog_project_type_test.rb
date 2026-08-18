# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogProjectTypeTest < ActiveSupport::TestCase
  setup do
    @version = Version.activated.where('id > 3').order(id: :desc).first || Version.order(id: :desc).first
    skip 'No Version available' unless @version

    @sc = ProjectType.find_by(tag: 'sc')
    @bulk = ProjectType.find_by(tag: 'bulk')
    skip 'Missing sc/bulk ProjectType' unless @sc && @bulk

    @user = register_for_test_cleanup(
      User.create!(email: "ecpt_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @importer = ExternalCatalog::ProjectImporter.new(
      user: @user,
      version: @version,
      skip_archive: true,
      skip_publish: true
    )
  end

  def entry_for(tag)
    ExternalCatalog::Entry.new(
      source: 'cellxgene',
      external_id: SecureRandom.hex(4),
      title: 'Catalog project',
      url: 'https://example.com/a.h5ad',
      tax_id: 9606,
      organism_label: 'Homo sapiens',
      filesize: 10,
      project_type_tag: tag,
      format_kind: :h5ad,
      filename: 'a.h5ad'
    )
  end

  test 'project_type_for keeps GEO bulk and maps every other catalog tag to sc' do
    assert_equal @bulk.id, @importer.send(:project_type_for, entry_for('bulk')).id
    assert_equal @sc.id, @importer.send(:project_type_for, entry_for('sc')).id
    assert_equal @sc.id, @importer.send(:project_type_for, entry_for('spat')).id
    assert_equal @sc.id, @importer.send(:project_type_for, entry_for('atac')).id
    assert_equal @sc.id, @importer.send(:project_type_for, entry_for('multi')).id
  end

  test 'CELLxGENE catalog entries are always tagged sc' do
    catalog = ExternalCatalog::CellxgeneCatalog.new
    visium = {
      dataset_id: 'd-visium',
      title: 'Visium',
      assay: [{ ontology_term_id: 'EFO:0022857', label: 'Visium Spatial Gene Expression V1' }],
      assets: [{ filetype: 'h5ad', url: 'https://example.com/v.h5ad', filesize: 10 }]
    }
    scrna = {
      dataset_id: 'd-sc',
      title: 'scRNA',
      assay: [{ 'ontology_term_id' => 'EFO:0009899', 'label' => "10x 3' v3" }],
      assets: [{ filetype: 'h5ad', url: 'https://example.com/s.h5ad', filesize: 10 }]
    }

    visium_entry = catalog.send(:entries_for_dataset, visium).first
    scrna_entry = catalog.send(:entries_for_dataset, scrna).first
    assert_equal 'sc', visium_entry.project_type_tag
    assert_equal 'sc', scrna_entry.project_type_tag
  end

  test 'CELLxGENE skips multiome-only and ATAC-only datasets' do
    catalog = ExternalCatalog::CellxgeneCatalog.new
    assets = [{ filetype: 'h5ad', url: 'https://example.com/a.h5ad', filesize: 10 }]
    multiome_only = {
      dataset_id: 'd-multi',
      title: 'Multiome only',
      assay: [{ ontology_term_id: 'EFO:0030059', label: '10x multiome' }],
      assets: assets
    }
    atac_only = {
      dataset_id: 'd-atac',
      title: 'ATAC only',
      assay: [{ ontology_term_id: 'EFO:0010891', label: 'scATAC-seq' }],
      assets: assets
    }
    mixed = {
      dataset_id: 'd-mixed',
      title: 'Multiome plus RNA',
      assay: [
        { ontology_term_id: 'EFO:0030059', label: '10x multiome' },
        { ontology_term_id: 'EFO:0009899', label: "10x 3' v3" }
      ],
      assets: assets
    }

    assert_empty catalog.send(:entries_for_dataset, multiome_only)
    assert_empty catalog.send(:entries_for_dataset, atac_only)
    mixed_entry = catalog.send(:entries_for_dataset, mixed).first
    assert_equal 'd-mixed', mixed_entry.external_id
    assert_equal 'sc', mixed_entry.project_type_tag
  end
end
