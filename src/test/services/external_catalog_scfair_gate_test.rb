# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogScfairGateTest < ActiveSupport::TestCase
  Result = Struct.new(
    :valid?, :errors, :warnings, :info, :valid_checks, :schema_version, :validated_at,
    keyword_init: true
  )

  setup do
    @version = Version.activated.where('id > 3').order(id: :desc).first || Version.order(id: :desc).first
    skip 'No Version available for importer tests' unless @version

    @sc_type = ProjectType.find_by(tag: 'sc') || ProjectType.find_by('name ILIKE ?', '%single%')
    skip 'No single-cell ProjectType' unless @sc_type

    @user = register_for_test_cleanup(
      User.create!(email: "scfair_gate_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(
      name: 'scFAIR gate project',
      key: "sg#{SecureRandom.hex(3)}",
      user_id: @user.id,
      public: false,
      being_deleted: false,
      project_type_id: @sc_type.id,
      version_id: @version.id
    )

    @archive_calls = []
    @importer = ExternalCatalog::ProjectImporter.new(
      user: @user,
      version: @version,
      skip_archive: false,
      skip_publish: true,
      dry_run: false,
      archiver: lambda { |project|
        @archive_calls << project.key
        :ok
      }
    )
    ENV['ASAP_RUN_CONTAINER'] ||= 'asap_run_test'
  end

  def valid_result
    Result.new(
      valid?: true,
      errors: [],
      warnings: [],
      info: [],
      valid_checks: [],
      schema_version: '7.1.0',
      validated_at: Time.current.iso8601
    )
  end

  def invalid_result(message)
    Result.new(
      valid?: false,
      errors: [{ field: 'attrs/title', message: message }],
      warnings: [],
      info: [],
      valid_checks: [],
      schema_version: '7.1.0',
      validated_at: Time.current.iso8601
    )
  end

  def warning_result(message)
    Result.new(
      valid?: true,
      errors: [],
      warnings: [{ field: 'obs', message: message }],
      info: [],
      valid_checks: [],
      schema_version: '7.1.0',
      validated_at: Time.current.iso8601
    )
  end

  def fake_status(ok: true)
    Struct.new(:success?, :exitstatus).new(ok, ok ? 0 : 1)
  end

  def with_replaced_singleton(mod, method_name, impl)
    original = mod.method(method_name)
    mod.define_singleton_method(method_name, &impl)
    yield
  ensure
    mod.define_singleton_method(method_name, original)
  end

  def with_project_loom
    project_dir = Basic.project_user_dir(@project)
    FileUtils.mkdir_p(project_dir + 'parsing')
    loom_abs = project_dir + 'parsing/output.loom'
    h5ad_abs = project_dir + 'parsing/output.h5ad'
    File.write(loom_abs, 'loom')
    loom = loom_abs.to_s
    @importer.define_singleton_method(:project_loom_path) { |_p| loom }
    yield project_dir, loom_abs, h5ad_abs
  ensure
    FileUtils.rm_rf(project_dir) if project_dir && Dir.exist?(project_dir)
  end

  test 'invalid loom raises and does not archive' do
    loom_result = invalid_result('missing title')
    with_project_loom do |_dir, _loom, _h5ad|
      with_replaced_singleton(CompliancePipeline, :validate_project_loom, ->(*) { loom_result }) do
        with_replaced_singleton(ScfairValidationJob, :persist_validation_result, ->(*) { true }) do
          err = assert_raises(ExternalCatalog::ProjectImporter::Error) do
            @importer.send(:validate_loom_or_raise!, @project)
            @importer.send(:archive_project!, @project)
          end
          assert_match(/scFAIR loom validation failed/, err.message)
          assert_empty @archive_calls
        end
      end
    end
  end

  test 'loom with warnings raises and does not archive' do
    loom_warn = warning_result('schema_reference mismatch')
    with_project_loom do |_dir, _loom, _h5ad|
      with_replaced_singleton(CompliancePipeline, :validate_project_loom, ->(*) { loom_warn }) do
        with_replaced_singleton(ScfairValidationJob, :persist_validation_result, ->(*) { true }) do
          err = assert_raises(ExternalCatalog::ProjectImporter::Error) do
            @importer.send(:validate_loom_or_raise!, @project)
            @importer.send(:archive_project!, @project)
          end
          assert_match(/scFAIR loom validation failed/, err.message)
          assert_match(/warnings=1/, err.message)
          assert_empty @archive_calls
        end
      end
    end
  end

  test 'valid loom and invalid h5ad raises and does not archive' do
    loom_ok = valid_result
    h5ad_bad = invalid_result('missing uns/title')
    status_ok = fake_status
    with_project_loom do |_dir, _loom, h5ad_abs|
      with_replaced_singleton(CompliancePipeline, :validate_project_loom, ->(*) { loom_ok }) do
        with_replaced_singleton(ScfairValidationJob, :persist_validation_result, ->(*) { true }) do
          with_replaced_singleton(Open3, :capture3, lambda { |*|
            File.write(h5ad_abs, 'h5ad-bytes')
            ['ok', '', status_ok]
          }) do
            validator = Object.new
            validator.define_singleton_method(:validate) { h5ad_bad }
            with_replaced_singleton(ScfairH5adValidatorService, :new, ->(*) { validator }) do
              err = assert_raises(ExternalCatalog::ProjectImporter::Error) do
                @importer.send(:validate_loom_or_raise!, @project)
                @importer.send(:export_h5ad_chunked_or_raise!, @project)
                @importer.send(:validate_h5ad_or_raise!, @project)
                @importer.send(:archive_project!, @project)
              end
              assert_match(/scFAIR h5ad validation failed/, err.message)
              assert_empty @archive_calls
            end
          end
        end
      end
    end
  end

  test 'valid loom and h5ad with warnings raises and does not archive' do
    loom_ok = valid_result
    h5ad_warn = warning_result('CellID not in column-order')
    status_ok = fake_status
    with_project_loom do |_dir, _loom, h5ad_abs|
      with_replaced_singleton(CompliancePipeline, :validate_project_loom, ->(*) { loom_ok }) do
        with_replaced_singleton(ScfairValidationJob, :persist_validation_result, ->(*) { true }) do
          with_replaced_singleton(Open3, :capture3, lambda { |*|
            File.write(h5ad_abs, 'h5ad-bytes')
            ['ok', '', status_ok]
          }) do
            validator = Object.new
            validator.define_singleton_method(:validate) { h5ad_warn }
            with_replaced_singleton(ScfairH5adValidatorService, :new, ->(*) { validator }) do
              err = assert_raises(ExternalCatalog::ProjectImporter::Error) do
                @importer.send(:validate_loom_or_raise!, @project)
                @importer.send(:export_h5ad_chunked_or_raise!, @project)
                @importer.send(:validate_h5ad_or_raise!, @project)
                @importer.send(:archive_project!, @project)
              end
              assert_match(/scFAIR h5ad validation failed/, err.message)
              assert_match(/warnings=1/, err.message)
              assert_empty @archive_calls
            end
          end
        end
      end
    end
  end

  test 'valid loom and valid h5ad archives when skip_archive is false' do
    loom_ok = valid_result
    h5ad_ok = valid_result
    status_ok = fake_status
    with_project_loom do |_dir, _loom, h5ad_abs|
      with_replaced_singleton(CompliancePipeline, :validate_project_loom, ->(*) { loom_ok }) do
        with_replaced_singleton(ScfairValidationJob, :persist_validation_result, ->(*) { true }) do
          with_replaced_singleton(Open3, :capture3, lambda { |*|
            File.write(h5ad_abs, 'h5ad-bytes')
            ['ok', '', status_ok]
          }) do
            validator = Object.new
            validator.define_singleton_method(:validate) { h5ad_ok }
            with_replaced_singleton(ScfairH5adValidatorService, :new, ->(*) { validator }) do
              @importer.send(:validate_loom_or_raise!, @project)
              @importer.send(:export_h5ad_chunked_or_raise!, @project)
              @importer.send(:validate_h5ad_or_raise!, @project)
              @importer.send(:archive_project!, @project)
            end
          end
        end
      end

      assert_equal [@project.key], @archive_calls
      assert h5ad_abs.exist?
    end
  end
end
