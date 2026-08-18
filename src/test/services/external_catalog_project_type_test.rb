# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogProjectTypeTest < ActiveSupport::TestCase
  setup do
    @version = Version.activated.where('id > 3').order(id: :desc).first || Version.order(id: :desc).first
    skip 'No Version available' unless @version

    @sc = ProjectType.find_by(tag: 'sc')
    @spat = ProjectType.find_by(tag: 'spat')
    @bulk = ProjectType.find_by(tag: 'bulk')
    skip 'Missing sc/spat/bulk ProjectType' unless @sc && @spat && @bulk

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

  test 'project_type_for creates spat when missing from database' do
    ProjectType.find_by(tag: 'spat')&.destroy!

    begin
      ptype = @importer.send(:project_type_for, entry_for('spat'))
      assert_equal 'spat', ptype.tag
      assert_equal 'Spatial transcriptomics', ptype.name
    ensure
      ProjectType.ensure_for_tag!('spat')
    end
  end

  test 'project_type_for maps spat and bulk tags' do
    assert_equal @spat.id, @importer.send(:project_type_for, entry_for('spat')).id
    assert_equal @bulk.id, @importer.send(:project_type_for, entry_for('bulk')).id
    assert_equal @sc.id, @importer.send(:project_type_for, entry_for('sc')).id
  end

  test 'project_type_for uses preparsing is_spatial even when catalog tag is sc' do
    tmp = Dir.mktmpdir('ecpt-fu')
    File.write(File.join(tmp, 'output.json'), { is_spatial: 1, spatial_library_id: 'libA' }.to_json)
    fu = Object.new
    fu.define_singleton_method(:upload_dir) { Pathname.new(tmp) }

    begin
      ptype = @importer.send(:project_type_for, entry_for('sc'), fu: fu)
      assert_equal 'spat', ptype.tag
    ensure
      FileUtils.rm_rf(tmp)
    end
  end

  test 'CELLxGENE visium dataset is tagged spat' do
    catalog = ExternalCatalog::CellxgeneCatalog.new
    dataset = {
      assay: [{ ontology_term_id: 'EFO:0022857', label: 'Visium Spatial Gene Expression V1' }]
    }
    assert_equal 'spat', catalog.send(:project_type_tag_for_dataset, dataset)
  end

  test 'CELLxGENE scRNA-seq dataset stays sc' do
    catalog = ExternalCatalog::CellxgeneCatalog.new
    dataset = {
      assay: [{ 'ontology_term_id' => 'EFO:0009899', 'label' => "10x 3' v3" }]
    }
    assert_equal 'sc', catalog.send(:project_type_tag_for_dataset, dataset)
  end
end
