# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class ProjectPublicationServiceTest < ActiveSupport::TestCase
  setup do
    @tmp_root = Dir.mktmpdir('project_publication')
    @prev_user_data_dir = ENV['USER_DATA_DIR']
    ENV['USER_DATA_DIR'] = @tmp_root

    @user = register_for_test_cleanup(
      User.create!(email: "pub_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(user_id: @user.id, input_filename: 'input_file.loom', public: false)
    @project_dir = Pathname.new(@tmp_root) + @user.id.to_s + @project.key
    FileUtils.mkdir_p(@project_dir + 'parsing')
    @loom_rel = 'parsing/output.loom'
    File.write(@project_dir + @loom_rel, 'loom-bytes')
    File.write(@project_dir + 'parsing/output.h5ad', 'h5ad-bytes')
    FileUtils.touch(@project_dir + 'parsing/output.h5ad', mtime: Time.now + 2)

    register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        name: '/matrix',
        dim: 3,
        filepath: @loom_rel,
        nber_rows: 10,
        nber_cols: 5
      )
    )
  end

  teardown do
    ENV['USER_DATA_DIR'] = @prev_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root && File.exist?(@tmp_root)
  end

  test 'start finalizes when h5ads are already ready and valid' do
    @project.stub(:can_be_public?, [true, nil]) do
      Basic.stub(:ensure_h5ad_exports_for_project, lambda { |*_args|
        [{ loom_rel: @loom_rel, run: nil, h5ad_status: 'ready', error: nil }]
      }) do
        Basic.stub(:anndata_mapping_needs_update?, false) do
          fake_result = Struct.new(:valid?, :errors, :warnings).new(true, [], [])
          ScfairH5adValidatorService.stub(:new, ->(*) { Object.new.tap { |o| o.define_singleton_method(:validate) { fake_result } } }) do
            ExternalCatalogCandidate.stub(:sync_catalog_links_for_public_project!, ->(*) {}) do
              result = ProjectPublicationService.start!(@project, user_id: @user.id, logger: Rails.logger)
              assert_equal 'finalized', result[:status]
              @project.reload
              assert @project.public?
              refute @project.publishing?
              assert_nil @project.publication_error
              assert @project.public_id.present?
              assert @project.public_at.present?
            end
          end
        end
      end
    end
  end

  test 'start leaves being_published when exports are still pending' do
    @project.stub(:can_be_public?, [true, nil]) do
      Basic.stub(:ensure_h5ad_exports_for_project, lambda { |*_args|
        [{ loom_rel: @loom_rel, run: nil, h5ad_status: 'pending', error: nil }]
      }) do
        Basic.stub(:h5ad_export_status, 'pending') do
          result = ProjectPublicationService.start!(@project, user_id: @user.id, logger: Rails.logger)
          assert_equal 'waiting', result[:status]
          @project.reload
          refute @project.public?
          assert @project.publishing?
        end
      end
    end
  end

  test 'continue aborts when h5ad validation fails' do
    @project.start_publishing!
    fake_result = Struct.new(:valid?, :errors, :warnings).new(
      false,
      [{ field: '/uns/title', message: 'missing' }],
      []
    )

    Basic.stub(:h5ad_export_status, 'ready') do
      Basic.stub(:latest_h5ad_export_run, nil) do
        ScfairH5adValidatorService.stub(:new, ->(*) { Object.new.tap { |o| o.define_singleton_method(:validate) { fake_result } } }) do
          result = ProjectPublicationService.continue!(@project, logger: Rails.logger)
          assert_equal 'aborted', result[:status]
          @project.reload
          refute @project.public?
          refute @project.publishing?
          assert_match(/scFAIR H5AD validation failed/, @project.publication_error)
        end
      end
    end
  end

  test 'cancel clears being_published without making public' do
    @project.start_publishing!
    result = ProjectPublicationService.cancel!(@project, logger: Rails.logger)
    assert_equal 'cancelled', result[:status]
    @project.reload
    refute @project.public?
    refute @project.publishing?
    assert_nil @project.publication_error
  end

  test 'start raises when compliance blocks publishing' do
    @project.stub(:can_be_public?, [false, 'Need validation']) do
      err = assert_raises(ProjectPublicationService::Error) do
        ProjectPublicationService.start!(@project, user_id: @user.id, logger: Rails.logger)
      end
      assert_match(/Need validation/, err.message)
      @project.reload
      refute @project.publishing?
      refute @project.public?
    end
  end
end
