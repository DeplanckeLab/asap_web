# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogImportSuccessRegistryTest < ActiveSupport::TestCase
  setup do
    @path = Rails.root.join("tmp/external_catalog_import_success_#{SecureRandom.hex(6)}.tsv").to_s
    @user = register_for_test_cleanup(
      User.create!(email: "import_reg_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @version = Version.activated.where('id > 3').order(id: :desc).first || Version.order(id: :desc).first
    skip 'No Version available' unless @version

    @project = create_test_project!(
      name: 'Registry project',
      key: "rg#{SecureRandom.hex(3)}",
      user_id: @user.id,
      public: false,
      being_deleted: false,
      version_id: @version.id
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
  end

  test 'evaluate uses successful parsing run without requiring loom file on disk' do
    singleton = ExternalCatalog::ImportSuccessRegistry.singleton_class
    original = singleton.instance_method(:latest_successful_parsing_run)
    begin
      singleton.define_method(:latest_successful_parsing_run) { |_project| Run.new(status_id: 3) }
      row = ExternalCatalog::ImportSuccessRegistry.evaluate(@project)
      assert_equal 1, row.to_h[:parsed]
    ensure
      singleton.define_method(:latest_successful_parsing_run, original)
    end
  end

  test 'evaluate uses compliance_validations.passed for loom scFAIR' do
    ComplianceValidation.create!(
      project_id: @project.id,
      passed: true,
      errors_count: 0,
      warnings_count: 0,
      valid_checks_count: 1,
      validated_at: Time.current
    )

    row = ExternalCatalog::ImportSuccessRegistry.evaluate(@project)
    assert_equal 1, row.to_h[:scfair_loom_valid]
  end

  test 'evaluate infers h5ad stages when catalog import completed successfully' do
    singleton = ExternalCatalog::ImportSuccessRegistry.singleton_class
    original = singleton.instance_method(:latest_successful_parsing_run)
    begin
      singleton.define_method(:latest_successful_parsing_run) { |_project| Run.new(status_id: 3) }

      ComplianceValidation.create!(
        project_id: @project.id,
        passed: true,
        errors_count: 0,
        warnings_count: 0,
        valid_checks_count: 1,
        validated_at: Time.current
      )
      Checkpoint.create!(
        project: @project,
        user: @user,
        title: 'UMAP colored by cell type with labels',
        kind: Checkpoint::KIND_VISUALIZATION,
        state: { 'loomFile' => 'parsing/output.loom' },
        is_landing_page: true
      )
      candidate = ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: "ext-#{SecureRandom.hex(4)}",
        provider_tag: 'CELLxGENE',
        title: 'Test candidate',
        url: 'https://example.com/a.h5ad',
        format_kind: 'h5ad',
        import_project_id: @project.id,
        import_status: 'idle',
        import_error: nil,
        last_seen_at: Time.current
      )
      register_for_test_cleanup(candidate)

      row = ExternalCatalog::ImportSuccessRegistry.evaluate_for_backfill(@project)
      values = row.to_h
      assert_equal 1, values[:parsed]
      assert_equal 1, values[:scfair_loom_valid]
      assert_equal 1, values[:visualization_checkpoint]
      assert_equal 1, values[:h5ad_export]
      assert_equal 1, values[:scfair_h5ad_valid]
      assert_equal 1, values[:import_full_success]
    ensure
      singleton.define_method(:latest_successful_parsing_run, original)
    end
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
end
