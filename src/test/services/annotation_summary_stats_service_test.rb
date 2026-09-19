# frozen_string_literal: true

require 'test_helper'
require 'ostruct'
require 'tmpdir'
require 'fileutils'

class AnnotationSummaryStatsServiceTest < ActiveSupport::TestCase
  class FakeRelation
    def initialize(record)
      @record = record
    end

    def where(*_args, **_kwargs)
      self
    end

    def first
      @record
    end
  end

  setup do
    @project = OpenStruct.new(id: 42)
    @project_dir = Dir.mktmpdir
    @loom_relative = 'parsing/output.loom'
    @loom_path = File.join(@project_dir, @loom_relative)
    FileUtils.mkdir_p(File.dirname(@loom_path))
    File.write(@loom_path, 'loom')

    @grouping = OpenStruct.new(
      id: 10,
      project_id: 42,
      name: '/col_attrs/cell_type',
      display_name: 'Cell type',
      filepath: @loom_relative,
      data_type: OpenStruct.new(name: 'DISCRETE')
    )
    @n_gene = OpenStruct.new(
      id: 20,
      project_id: 42,
      name: '/col_attrs/nGene',
      display_name: 'nGene',
      filepath: @loom_relative,
      data_type: OpenStruct.new(name: 'NUMERIC')
    )
    @batch = OpenStruct.new(
      id: 30,
      project_id: 42,
      name: '/col_attrs/batch',
      display_name: 'Batch',
      filepath: @loom_relative,
      data_type: OpenStruct.new(name: 'DISCRETE')
    )
    @stable_meta = OpenStruct.new(
      id: 99,
      name: '/row_attrs/_StableID',
      filepath: @loom_relative
    )
    @matrix = OpenStruct.new(
      id: 77,
      name: '/matrix',
      filepath: @loom_relative
    )

    @annots_by_id = {
      10 => @grouping,
      20 => @n_gene,
      30 => @batch
    }

    @original_find = Annot.method(:find_by)
    @original_light = Annot.method(:light)
    @original_get_meta = H5DataService.method(:get_metadata_vector)
    @original_extract = H5DataService.method(:extract_row_by_indexes)

    annots = @annots_by_id
    Annot.define_singleton_method(:find_by) do |**kwargs|
      annots[kwargs[:id].to_i]
    end

    matrix = @matrix
    stable = @stable_meta
    Annot.define_singleton_method(:light) do
      Object.new.tap do |rel|
        rel.define_singleton_method(:where) do |*args, **kwargs|
          name = kwargs[:name]
          name ||= args.first[:name] if args.first.is_a?(Hash)
          record = name.to_s.include?('_StableID') ? stable : matrix
          FakeRelation.new(record)
        end
      end
    end
  end

  teardown do
    FileUtils.remove_entry(@project_dir) if @project_dir && Dir.exist?(@project_dir)
    Annot.define_singleton_method(:find_by, @original_find)
    Annot.define_singleton_method(:light, @original_light)
    H5DataService.define_singleton_method(:get_metadata_vector, @original_get_meta)
    H5DataService.define_singleton_method(:extract_row_by_indexes, @original_extract)
  end

  test 'genes mode returns long-format continuous stats matching client formulas' do
    grouping_labels = %w[A A B B]
    expression = [1.0, 3.0, 5.0, 7.0]
    stable_ids = %w[g1 g2 g3]

    H5DataService.define_singleton_method(:get_metadata_vector) do |_path, meta_path|
      if meta_path.to_s.include?('cell_type')
        grouping_labels
      elsif meta_path.to_s.include?('_StableID')
        stable_ids
      else
        []
      end
    end
    H5DataService.define_singleton_method(:extract_row_by_indexes) do |_path, _matrix, indexes|
      { 'rows' => Array(indexes).map { expression } }
    end

    service = AnnotationSummaryStatsService.new(project: @project, project_dir: @project_dir)
    result = service.call(
      loom_file: @loom_relative,
      grouping_metadata_id: 10,
      mode: 'genes',
      gene_entries: [{ stable_id: 'g1', symbol: 'GENE1' }]
    )

    rows = result[:rows]
    assert_equal 2, rows.length
    a_row = rows.find { |r| r['Category'] == 'A' }
    b_row = rows.find { |r| r['Category'] == 'B' }
    assert_equal 'GENE1', a_row['Gene']
    assert_equal 2, a_row['Cell Count']
    assert_in_delta 2.0, a_row['Mean'], 0.0001
    assert_in_delta 1.0, a_row['Min'], 0.0001
    assert_in_delta 3.0, a_row['Max'], 0.0001
    assert_in_delta 3.0, a_row['Median'], 0.0001
    assert_in_delta 6.0, b_row['Mean'], 0.0001
    assert_equal [], result[:warnings]
  end

  test 'continuous mode returns stats for each metadata' do
    grouping_labels = %w[A B A B]
    n_gene_values = [10.0, 20.0, 30.0, 40.0]

    H5DataService.define_singleton_method(:get_metadata_vector) do |_path, meta_path|
      if meta_path.to_s.include?('cell_type')
        grouping_labels
      elsif meta_path.to_s.include?('nGene')
        n_gene_values
      else
        []
      end
    end

    service = AnnotationSummaryStatsService.new(project: @project, project_dir: @project_dir)
    result = service.call(
      loom_file: @loom_relative,
      grouping_metadata_id: 10,
      mode: 'continuous',
      metadata_ids: [20]
    )
    a_row = result[:rows].find { |r| r['Category'] == 'A' }
    assert_equal 'nGene', a_row['Metadata']
    assert_in_delta 20.0, a_row['Mean'], 0.0001
  end

  test 'categorical mode returns long-format crosstab' do
    grouping_labels = %w[A A B B]
    batch_labels = %w[x y x y]

    H5DataService.define_singleton_method(:get_metadata_vector) do |_path, meta_path|
      if meta_path.to_s.include?('cell_type')
        grouping_labels
      elsif meta_path.to_s.include?('batch')
        batch_labels
      else
        []
      end
    end

    service = AnnotationSummaryStatsService.new(project: @project, project_dir: @project_dir)
    result = service.call(
      loom_file: @loom_relative,
      grouping_metadata_id: 10,
      mode: 'categorical',
      metadata_ids: [30]
    )
    match = result[:rows].find do |r|
      r['Metadata'] == 'Batch' && r['Category'] == 'A' && r['Coloring category'] == 'x'
    end
    assert_equal 1, match['Cell Count']
    assert_in_delta 50.0, match['%'], 0.0001
  end

  test 'applies category filters when computing gene stats' do
    grouping_labels = %w[A A B B]
    expression = [1.0, 3.0, 5.0, 7.0]
    filter_labels = %w[keep drop keep drop]
    stable_ids = %w[g1]

    filter_meta = OpenStruct.new(
      id: 40,
      project_id: 42,
      name: '/col_attrs/filter',
      display_name: 'Filter',
      filepath: @loom_relative,
      data_type: OpenStruct.new(name: 'DISCRETE')
    )
    @annots_by_id[40] = filter_meta

    H5DataService.define_singleton_method(:get_metadata_vector) do |_path, meta_path|
      case meta_path.to_s
      when /cell_type/ then grouping_labels
      when /_StableID/ then stable_ids
      when /filter/ then filter_labels
      else []
      end
    end
    H5DataService.define_singleton_method(:extract_row_by_indexes) do |_path, _matrix, indexes|
      { 'rows' => Array(indexes).map { expression } }
    end

    service = AnnotationSummaryStatsService.new(project: @project, project_dir: @project_dir)
    result = service.call(
      loom_file: @loom_relative,
      grouping_metadata_id: 10,
      mode: 'genes',
      gene_entries: [{ stable_id: 'g1', symbol: 'GENE1' }],
      filters: { 'categories' => { '40' => ['keep'] } }
    )

    a_row = result[:rows].find { |r| r['Category'] == 'A' }
    b_row = result[:rows].find { |r| r['Category'] == 'B' }
    assert_equal 1, a_row['Cell Count']
    assert_in_delta 1.0, a_row['Mean'], 0.0001
    assert_equal 1, b_row['Cell Count']
    assert_in_delta 5.0, b_row['Mean'], 0.0001
  end

  test 'rejects oversized gene batches' do
    H5DataService.define_singleton_method(:get_metadata_vector) do |_path, _meta|
      %w[A B]
    end

    service = AnnotationSummaryStatsService.new(project: @project, project_dir: @project_dir)
    genes = (1..(AnnotationSummaryStatsService::MAX_BATCH_SIZE + 1)).map { |i| { stable_id: "g#{i}", symbol: "G#{i}" } }
    err = assert_raises(AnnotationSummaryStatsService::ValidationError) do
      service.call(
        loom_file: @loom_relative,
        grouping_metadata_id: 10,
        mode: 'genes',
        gene_entries: genes
      )
    end
    assert_match(/Too many genes/, err.message)
  end
end
