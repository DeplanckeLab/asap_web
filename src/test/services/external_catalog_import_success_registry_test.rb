# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogImportSuccessRegistryTest < ActiveSupport::TestCase
  setup do
    @path = Rails.root.join("tmp/external_catalog_import_success_#{SecureRandom.hex(6)}.tsv").to_s
    @user = register_for_test_cleanup(
      User.create!(email: "import_reg_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(
      name: 'Registry project',
      key: "rg#{SecureRandom.hex(3)}",
      user_id: @user.id,
      public: false,
      being_deleted: false
    )
  end

  teardown do
    FileUtils.rm_f(@path)
  end

  test 'record writes multi-column TSV and upserts by project key' do
    status = ExternalCatalog::ImportSuccessRegistry::PipelineStatus.from_hash(
      parsed: 1,
      scfair_loom_valid: 1,
      visualization_checkpoint: 0,
      h5ad_export: 1,
      scfair_h5ad_valid: 1
    )
    ExternalCatalog::ImportSuccessRegistry.record!(project_key: @project.key, status: status, path: @path)

    rows = ExternalCatalog::ImportSuccessRegistry.read_all(path: @path)
    values = rows[@project.key].to_h
    assert_equal 0, values[:import_full_success]
    assert_equal 1, values[:parsed]
    assert_equal 1, values[:scfair_loom_valid]
    assert_equal 0, values[:visualization_checkpoint]
    assert_equal 1, values[:h5ad_export]
    assert_equal 1, values[:scfair_h5ad_valid]

    lines = File.readlines(@path, chomp: true)
    assert_equal ExternalCatalog::ImportSuccessRegistry::COLUMNS.join("\t"), lines.first
  end

  test 'import_full_success is 1 only when every stage is 1' do
    row = ExternalCatalog::ImportSuccessRegistry::PipelineStatus.from_hash(
      parsed: 1,
      scfair_loom_valid: 1,
      visualization_checkpoint: 1,
      h5ad_export: 1,
      scfair_h5ad_valid: 1
    )
    assert row.full_success?

    partial = ExternalCatalog::ImportSuccessRegistry::PipelineStatus.from_hash(
      parsed: 1,
      scfair_loom_valid: 1,
      visualization_checkpoint: 0,
      h5ad_export: 1,
      scfair_h5ad_valid: 1
    )
    refute partial.full_success?
  end

  test 'record_import_attempt uses importer pipeline status when present' do
    status = ExternalCatalog::ImportSuccessRegistry::PipelineStatus.from_hash(
      parsed: 1,
      scfair_loom_valid: 1,
      visualization_checkpoint: 1,
      h5ad_export: 1,
      scfair_h5ad_valid: 1
    )
    importer = Struct.new(:last_pipeline_status).new(status)
    ExternalCatalog::ImportSuccessRegistry.record_import_attempt!(
      project: @project,
      importer: importer,
      path: @path
    )
    assert ExternalCatalog::ImportSuccessRegistry.success?(@project.key, path: @path)
  end

  test 'record_import_attempt evaluates linked imports from project state' do
    importer = Struct.new(:last_import_outcome, :last_pipeline_status).new(:linked, nil)
    called = false
    singleton = ExternalCatalog::ImportSuccessRegistry.singleton_class
    original = singleton.instance_method(:evaluate)
    begin
      singleton.define_method(:evaluate) do |_project, **_kwargs|
        called = true
        ExternalCatalog::ImportSuccessRegistry::PipelineStatus.from_hash(parsed: 1)
      end
      ExternalCatalog::ImportSuccessRegistry.record_import_attempt!(
        project: @project,
        importer: importer,
        path: @path
      )
      assert called
      assert_equal 1, ExternalCatalog::ImportSuccessRegistry.read_all(path: @path)[@project.key].to_h[:parsed]
    ensure
      singleton.define_method(:evaluate, original)
    end
  end

  test 'evaluate detects visualization landing checkpoint' do
    Checkpoint.create!(
      project: @project,
      user: @user,
      title: 'UMAP colored by cell type with labels',
      kind: Checkpoint::KIND_VISUALIZATION,
      state: { 'loomFile' => 'parsing/output.loom' },
      is_landing_page: true
    )

    values = ExternalCatalog::ImportSuccessRegistry.evaluate(@project).to_h
    assert_equal 1, values[:visualization_checkpoint]
  end
end
