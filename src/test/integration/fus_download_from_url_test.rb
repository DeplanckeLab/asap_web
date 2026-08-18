# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

class FusDownloadFromUrlTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs

    @tmp_root = Dir.mktmpdir('fus-download-from-url')
    @previous_upload_data_dir = ENV['UPLOAD_DATA_DIR']
    ENV['UPLOAD_DATA_DIR'] = File.join(@tmp_root, 'fus')
    FileUtils.mkdir_p(ENV['UPLOAD_DATA_DIR'])
  end

  teardown do
    destroy_registered_test_records!
    ENV['UPLOAD_DATA_DIR'] = @previous_upload_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test 'reusing an in-progress download does not start preparsing' do
    version = Version.order(:id).first
    skip 'no versions available' if version.blank?

    get new_project_path
    assert_response :success
    sandbox = session[:sandbox]
    source_url = 'https://example.com/datasets/big.h5ad'

    fu = register_for_test_cleanup(
      Fu.create!(
        user_id: nil,
        project_key: sandbox,
        upload_file_name: 'input_file.h5ad',
        upload_file_size: 1000,
        name: 'big.h5ad',
        status: 'downloading',
        url: source_url,
        preparsing_version_id: version.id
      )
    )
    FileUtils.mkdir_p(fu.upload_dir)
    File.write(fu.file_path, 'partial-h5ad')

    assert_no_enqueued_jobs only: FuPreparsingJob do
      assert_no_enqueued_jobs only: FuDownloadFromUrlJob do
        post download_from_url_fus_path, params: {
          url: source_url,
          version_id: version.id
        }, as: :json
      end
    end

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal fu.id, payload['fu_id']
    assert_equal 'downloading', payload['status']
    assert_equal true, payload['reused']
    assert_equal 'downloading', fu.reload.status
  end
end
