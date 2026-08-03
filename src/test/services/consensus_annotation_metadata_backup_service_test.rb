# frozen_string_literal: true

require 'minitest/mock'
require_relative 'test_base_without_fixtures'

class ConsensusAnnotationMetadataBackupServiceTest < TestBaseWithoutFixtures
  setup do
    @tmp_root = Dir.mktmpdir('consensus-backup')
    @previous_user_data_dir = ENV['USER_DATA_DIR']
    ENV['USER_DATA_DIR'] = File.join(@tmp_root, 'projects')
    FileUtils.mkdir_p(ENV['USER_DATA_DIR'])

    @user = register_for_test_cleanup(User.create!(email: "bkp_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    @project = create_test_project!(name: 'Backup project', key: "bkp#{SecureRandom.hex(3)}", user_id: @user.id)
    project_dir = Pathname.new(ENV['USER_DATA_DIR']) + @user.id.to_s + @project.key
    FileUtils.mkdir_p(project_dir)
    @loom_file = 'main.loom'
    File.write(project_dir + @loom_file, 'loom-stub')

    data_type_id = DataType.find_by(name: 'DISCRETE')&.id || 3
    @metadata_path = '/col_attrs/_asap_consensus_cell_type'
    @annot = register_for_test_cleanup(
      @project.annots.create!(
        name: @metadata_path,
        label: '_asap_consensus_cell_type',
        filepath: @loom_file,
        dim: 1,
        data_type_id: data_type_id,
        nber_cols: 3,
        latest_version: true,
        version_nber: 1,
        user_id: @user.id,
        created_at: 2.days.ago,
        updated_at: 2.days.ago
      )
    )
    @original_id = @annot.id
    @original_created_at = @annot.created_at
  end

  teardown do
    destroy_registered_test_records!
    ENV['USER_DATA_DIR'] = @previous_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
  end

  test 'renames existing annot to backup path instead of duplicating' do
    H5DataService.stub(:metadata_dataset_exists?, ->(_loom, path) { path == @metadata_path || path.to_s.end_with?(@metadata_path) }) do
      H5DataService.stub(:get_metadata_vector, ->(*) { %w[a b c] }) do
        H5DataService.stub(:copy_metadata_dataset!, ->(*) { true }) do
          H5DataService.stub(:delete_metadata_dataset!, ->(*) { true }) do
            result = ConsensusAnnotationMetadataBackupService.call(
              project: @project,
              loom_file: @loom_file,
              metadata_path: @metadata_path,
              new_labels: %w[x y z]
            )

            assert result[:ok], result[:error]
            assert result[:backed_up]
            assert_equal @original_id, result[:backup_annot_id]

            @annot.reload
            assert_equal result[:backup_path], @annot.name
            assert_equal false, @annot.latest_version
            assert_in_delta @original_created_at.to_f, @annot.created_at.to_f, 1.0
            assert_equal 1, @project.annots.where(id: @original_id).count
            assert_equal 0, @project.annots.where(name: @metadata_path).count
          end
        end
      end
    end
  end
end
