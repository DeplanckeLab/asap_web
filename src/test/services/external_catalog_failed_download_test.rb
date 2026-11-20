# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require 'tmpdir'

# ProjectImporter#import_one deletes a fresh download when the import fails before a project uses it.
class ExternalCatalogFailedDownloadTest < ActiveSupport::TestCase
  setup do
    @version = Version.activated.where('id > 3').order(id: :desc).first || Version.order(id: :desc).first
    skip 'No Version available for importer tests' unless @version
    @organism = Organism.order(:id).first
    skip 'No Organism available for importer tests' unless @organism

    @previous_upload_dir = ENV['UPLOAD_DATA_DIR']
    @upload_root = Dir.mktmpdir('failed_download')
    ENV['UPLOAD_DATA_DIR'] = @upload_root

    @user = register_for_test_cleanup(
      User.create!(email: "faildl_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    external_id = "faildl-#{SecureRandom.hex(4)}"
    @entry = ExternalCatalog::Entry.new(
      source: 'cellxgene',
      external_id: external_id,
      title: "Failed download #{external_id}",
      url: "https://example.com/#{external_id}.h5ad",
      tax_id: @organism.tax_id,
      project_type_tag: 'sc',
      format_kind: :h5ad
    )
  end

  teardown do
    ENV['UPLOAD_DATA_DIR'] = @previous_upload_dir
    FileUtils.rm_rf(@upload_root) if @upload_root
  end

  def importer
    ExternalCatalog::ProjectImporter.new(
      user: @user,
      version: @version,
      skip_archive: true,
      skip_publish: true,
      ask_user_choice: true
    )
  end

  # Stands in for FuDownloadFromUrlJob: writes the file, the preparsing output and the final status.
  # list_groups: nil writes no preparsing output.json.
  def fake_download(status:, list_groups: nil)
    lambda do |fu_id, _url, **|
      fu = Fu.find(fu_id)
      @fu_ids << fu.id
      FileUtils.mkdir_p(fu.upload_dir)
      File.write(fu.upload_dir.join(fu.upload_file_name), 'h5ad bytes')
      unless list_groups.nil?
        File.write(fu.upload_dir.join('output.json'), { 'detected_format' => 'H5AD', 'list_groups' => list_groups }.to_json)
      end
      fu.update!(status: status)
    end
  end

  def run_import(download)
    @fu_ids = []
    imp = importer
    imp.stub(:resolve_organism!, @organism) do
      FuDownloadFromUrlJob.stub(:perform_now, download) do
        imp.import_one(@entry)
      end
    end
  end

  test 'a failed download is deleted' do
    assert_raises(ExternalCatalog::ProjectImporter::Error) { run_import(fake_download(status: 'failed')) }

    assert_equal 1, @fu_ids.size
    assert_nil Fu.find_by(id: @fu_ids.first)
    assert_empty Dir.children(@upload_root)
  end

  test 'a download that fails after preparsing is deleted' do
    err = assert_raises(ExternalCatalog::ProjectImporter::Error) { run_import(fake_download(status: 'preparsed')) }
    assert_match(/Missing preparsing output.json/, err.message)

    assert_nil Fu.find_by(id: @fu_ids.first)
    assert_empty Dir.children(@upload_root)
  end

  test 'a download waiting for the project form is kept' do
    groups = [
      { 'group' => '/X', 'nber_rows' => 3, 'nber_cols' => 4, 'is_count' => 0 },
      { 'group' => '/layers/counts', 'nber_rows' => 3, 'nber_cols' => 4, 'is_count' => 1 }
    ]
    err = assert_raises(ExternalCatalog::ProjectImporter::NeedsUserChoice) do
      run_import(fake_download(status: 'preparsed', list_groups: groups))
    end

    fu = register_for_test_cleanup(Fu.find_by(id: @fu_ids.first))
    assert fu
    assert_equal fu.id, err.fu.id
    assert File.exist?(fu.upload_dir.join(fu.upload_file_name))
  end
end
