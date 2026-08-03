# frozen_string_literal: true

require 'minitest/mock'
require 'set'
require_relative 'test_base_without_fixtures'

class ConsensusAnnotationSupportServiceTest < TestBaseWithoutFixtures
  setup do
    @tmp_root = Dir.mktmpdir('consensus-support')
    @previous_user_data_dir = ENV['USER_DATA_DIR']
    ENV['USER_DATA_DIR'] = File.join(@tmp_root, 'projects')
    FileUtils.mkdir_p(ENV['USER_DATA_DIR'])

    @user = register_for_test_cleanup(User.create!(email: "sup_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    @project = create_test_project!(name: 'Support project', key: "sup#{SecureRandom.hex(3)}", user_id: @user.id)
    @project_b = create_test_project!(
      name: 'Support clone',
      key: "spc#{SecureRandom.hex(3)}",
      user_id: @user.id,
      cloned_project_id: @project.id,
      root_project_id: @project.id
    )

    project_dir = Pathname.new(ENV['USER_DATA_DIR']) + @user.id.to_s + @project.key
    FileUtils.mkdir_p(project_dir)
    @loom_file = 'main.loom'
    File.write(project_dir + @loom_file, 'loom-stub')

    @pcs = register_for_test_cleanup(ProjectCellSet.create!(key: "pcs#{SecureRandom.hex(4)}"))
    @cell_set = register_for_test_cleanup(CellSet.create!(project_cell_set_id: @pcs.id, key: SecureRandom.hex(8), nber_cells: 2))
    @ott = OntologyTermType.find_by(name: 'cell_type') ||
           register_for_test_cleanup(OntologyTermType.create!(name: 'cell_type', label: 'Cell type'))

    data_type_id = DataType.find_by(name: 'DISCRETE')&.id || 3
    @consensus_annot = register_for_test_cleanup(
      @project.annots.create!(
        name: '/col_attrs/_asap_consensus_cell_type',
        label: '_asap_consensus_cell_type',
        filepath: @loom_file,
        dim: 1,
        data_type_id: data_type_id,
        list_cat_json: ['Orphan label'].to_json,
        latest_version: true,
        version_nber: 1,
        user_id: @user.id
      )
    )

    @cla = register_for_test_cleanup(
      Cla.create!(
        project_id: @project.id,
        cell_set_id: @cell_set.id,
        ontology_term_type_id: @ott.id,
        name: 'T cell',
        cat: 'cluster_1',
        nber_agree: 3,
        nber_disagree: 0,
        user_id: @user.id,
        cla_source_id: Basic::MANUAL_CLA_SOURCE_ID
      )
    )
  end

  teardown do
    destroy_registered_test_records!
    ENV['USER_DATA_DIR'] = @previous_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
  end

  test 'errors when annotated cells are missing from consensus' do
    Annot.stub(:available_loom_files, ->(_project_id) { [@loom_file] }) do
      H5DataService.stub(:get_metadata_vector, lambda { |_loom, path|
        case path
        when '/col_attrs/_asap_consensus_cell_type'
          %w[Unassigned Unassigned] + ['T cell', 'T cell']
        else
          nil
        end
      }) do
        service = ConsensusAnnotationSupportService.new(
          project: @project,
          user: @user,
          readable_if: ->(_project) { true }
        )
        service.define_singleton_method(:annotation_coverage) do |**_|
          { annotated_indexes: Set.new([0, 1, 2]) }
        end
        service.define_singleton_method(:assess_reproducibility) do |**_|
          { level: nil, status: 'skipped' }
        end

        result = service.call
        assert result[:ok], result[:error]
        entry = result[:by_type][@ott.id.to_s]
        assert entry
        assert_equal 'error', entry[:status]
        assert_equal 2, entry[:missing_annotated_cell_count]
        assert entry[:messages].any? { |msg| msg[:level] == 'error' && msg[:code] == 'annotated_cells_missing_in_consensus' }
        assert entry[:messages].any? { |msg| msg[:level] == 'warning' && msg[:code] == 'cells_without_annotation' && msg[:count] == 1 }
      end
    end
  end

  test 'warns with count when cells have no annotation' do
    @consensus_annot.update!(list_cat_json: ['T cell'].to_json)

    Annot.stub(:available_loom_files, ->(_project_id) { [@loom_file] }) do
      H5DataService.stub(:get_metadata_vector, lambda { |_loom, path|
        case path
        when '/col_attrs/_asap_consensus_cell_type'
          ['T cell', 'T cell', 'Unassigned', 'Unassigned']
        else
          nil
        end
      }) do
        service = ConsensusAnnotationSupportService.new(
          project: @project,
          user: @user,
          readable_if: ->(_project) { true }
        )
        service.define_singleton_method(:annotation_coverage) do |**_|
          { annotated_indexes: Set.new([0, 1]) }
        end
        service.define_singleton_method(:assess_reproducibility) do |**_|
          {
            level: 'success',
            status: 'reproducible',
            message: {
              level: 'success',
              code: 'compatible',
              text: 'compatible with existing annotations'
            }
          }
        end

        result = service.call
        assert result[:ok], result[:error]
        entry = result[:by_type][@ott.id.to_s]
        assert entry
        assert_equal 'warning', entry[:status]
        assert_equal 2, entry[:unannotated_cell_count]
        assert entry[:messages].any? { |msg| msg[:level] == 'success' }
        warning = entry[:messages].find { |msg| msg[:code] == 'cells_without_annotation' }
        assert warning
        assert_equal 2, warning[:count]
        assert_match(/2 cells have no annotation/i, warning[:text])
      end
    end
  end

  test 'flags consensus labels absent from lineage annotations as unsupported' do
    Annot.stub(:available_loom_files, ->(_project_id) { [@loom_file] }) do
      H5DataService.stub(:get_metadata_vector, lambda { |_loom, path|
        case path
        when '/col_attrs/_asap_consensus_cell_type'
          ['Orphan label', 'Orphan label']
        else
          nil
        end
      }) do
        service = ConsensusAnnotationSupportService.new(
          project: @project,
          user: @user,
          readable_if: ->(_project) { true }
        )
        service.define_singleton_method(:annotation_coverage) do |**_|
          { annotated_indexes: Set.new([0, 1]) }
        end
        ConsensusAnnotationPreviewService.stub(:call, lambda { |**kwargs|
          if kwargs[:build_vectors]
            { ok: false, error: 'skip vectors' }
          else
            {
              ok: true,
              annotation_type_id: @ott.id,
              equal_rank: [],
              collisions: []
            }
          end
        }) do
          result = service.call
          assert result[:ok], result[:error]
          entry = result[:by_type][@ott.id.to_s]
          assert entry
          assert_equal 'error', entry[:status]
          assert entry[:messages].any? { |msg| msg[:level] == 'error' && msg[:code] == 'labels_not_in_annotations' }
        end
      end
    end
  end

  test 'returns empty by_type when project has no consensus annots' do
    @consensus_annot.destroy!
    result = ConsensusAnnotationSupportService.call(
      project: @project,
      user: @user,
      readable_if: ->(_project) { true }
    )
    assert result[:ok], result[:error]
    entry = result[:by_type][@ott.id.to_s]
    assert entry
    assert_equal 'error', entry[:status]
    assert entry[:messages].any? { |msg| msg[:level] == 'error' && msg[:code] == 'missing_consensus' }
  end

  test 'does not error for missing consensus when no ASAP manual annotations exist' do
    @consensus_annot.destroy!
    @cla.update!(cla_source_id: nil)
    result = ConsensusAnnotationSupportService.call(
      project: @project,
      user: @user,
      readable_if: ->(_project) { true }
    )
    assert result[:ok], result[:error]
    assert_nil result[:by_type][@ott.id.to_s]
  end

  test 'errors for missing consensus when ASAP manual annotations have no ontology term type' do
    @consensus_annot.destroy!
    @cla.update!(ontology_term_type_id: nil)
    result = ConsensusAnnotationSupportService.call(
      project: @project,
      user: @user,
      readable_if: ->(_project) { true }
    )
    assert result[:ok], result[:error]
    entry = result[:by_type]['']
    assert entry
    assert_equal 'error', entry[:status]
    assert entry[:messages].any? { |msg| msg[:level] == 'error' && msg[:code] == 'missing_consensus' }
    assert_match(/Assign an annotation type/, entry[:messages].first[:text])
  end
end
