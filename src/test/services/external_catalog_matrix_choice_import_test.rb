# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

# ProjectImporter#choose_matrix_selection! on an H5AD with several matrices and no /raw/X (e.g. Broad SCP3342).
class ExternalCatalogMatrixChoiceImportTest < ActiveSupport::TestCase
  FakeFu = Struct.new(:id, :upload_dir)

  setup do
    @version = Version.activated.where('id > 3').order(id: :desc).first || Version.order(id: :desc).first
    skip 'No Version available for importer tests' unless @version
    skip 'No single-cell ProjectType' unless ProjectType.find_by(tag: 'sc') || ProjectType.find_by('name ILIKE ?', '%single%')
    skip 'No bulk ProjectType' unless ProjectType.find_by(tag: 'bulk') || ProjectType.find_by('name ILIKE ?', '%bulk%')

    @user = register_for_test_cleanup(
      User.create!(email: "mchoice_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @dir = Pathname.new(Dir.mktmpdir('matrix_choice'))
    File.write(
      @dir.join('output.json'),
      {
        'detected_format' => 'H5AD',
        'list_groups' => [
          { 'group' => '/X', 'nber_rows' => 30, 'nber_cols' => 40, 'is_count' => 0, 'dtype' => 'float32' },
          { 'group' => '/layers/raw_count_cellbender', 'nber_rows' => 31, 'nber_cols' => 40, 'is_count' => 1 },
          { 'group' => '/layers/raw_count_cellranger', 'nber_rows' => 32, 'nber_cols' => 40, 'is_count' => 1 }
        ]
      }.to_json
    )
    @fu = FakeFu.new(987_654, @dir)
  end

  teardown do
    FileUtils.rm_rf(@dir) if @dir
  end

  def importer(ask:)
    ExternalCatalog::ProjectImporter.new(
      user: @user,
      version: @version,
      skip_archive: true,
      skip_publish: true,
      ask_matrix_choice: ask
    )
  end

  test 'UI import pauses with the choices and the recommended matrix' do
    err = assert_raises(ExternalCatalog::ProjectImporter::NeedsMatrixChoice) do
      importer(ask: true).send(:choose_matrix_selection!, @fu, nil)
    end
    assert_equal @fu, err.fu
    assert_equal %w[/X /layers/raw_count_cellbender /layers/raw_count_cellranger], err.choices.map { |c| c['path'] }
    assert_equal '/layers/raw_count_cellbender', err.recommended
  end

  test 'batch import uses the recommended matrix and its dimensions' do
    sel, dims, file_type = importer(ask: false).send(:choose_matrix_selection!, @fu, nil)
    assert_equal '/layers/raw_count_cellbender', sel
    assert_equal({ nber_rows: 31, nber_cols: 40 }, dims)
    assert_equal 'H5AD', file_type
  end

  test 'a chosen matrix is used, also when given as a bare layer name' do
    sel, dims, = importer(ask: true).send(:choose_matrix_selection!, @fu, nil, sel: '/layers/raw_count_cellranger')
    assert_equal '/layers/raw_count_cellranger', sel
    assert_equal 32, dims[:nber_rows]

    sel, = importer(ask: true).send(:choose_matrix_selection!, @fu, nil, sel: 'raw_count_cellranger')
    assert_equal '/layers/raw_count_cellranger', sel
  end

  test 'a matrix that is not in the file is rejected' do
    err = assert_raises(ExternalCatalog::ProjectImporter::Error) do
      importer(ask: true).send(:choose_matrix_selection!, @fu, nil, sel: '/layers/nope')
    end
    assert_match(%r{/layers/nope}, err.message)
  end

  test 'resume refuses a Fu of another user' do
    other = register_for_test_cleanup(
      User.create!(email: "mchoice_o_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    fu = register_for_test_cleanup(
      Fu.create!(user_id: other.id, upload_file_name: 'input_file.h5ad', upload_file_size: 0, status: 'preparsed')
    )
    assert_raises(ExternalCatalog::ProjectImporter::Error) do
      importer(ask: true).send(:resume_fu!, fu.id)
    end
  end
end
