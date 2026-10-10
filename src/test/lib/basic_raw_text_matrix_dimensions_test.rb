require 'test_helper'
require 'tmpdir'

class BasicRawTextMatrixDimensionsTest < ActiveSupport::TestCase
  test 'raw_text_matrix_dimensions matches scan for comma CSV with header' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'matrix.csv')
      File.write(path, <<~CSV)
        Gene,c1,c2,c3
        g1,1,2,3
        g2,4,5,6
      CSV

      dims = Basic.raw_text_matrix_dimensions(
        path,
        gene_name_col: 'first',
        delimiter: ',',
        has_header: true
      )
      scan = Basic.raw_text_matrix_scan(
        path,
        gene_name_col: 'first',
        delimiter: ',',
        has_header: true
      )

      assert_equal 2, dims[:nber_rows]
      assert_equal 3, dims[:nber_cols]
      assert_equal scan[:n_rows], dims[:nber_rows]
      assert_equal scan[:n_cells], dims[:nber_cols]
    end
  end

  test 'raw_text_matrix_field_count avoids allocating per-column strings for wide lines' do
    delim = ','
    wide = 'Gene,' + Array.new(5_000) { |i| "c#{i}" }.join(',')
    assert_equal 5001, Basic.raw_text_matrix_field_count(wide, delim)
  end

  test 'sync_raw_text_dimensions_from_file! skips rescan when preparser dims are already positive' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'matrix.csv')
      # Intentionally wrong on-disk content vs claimed dims: sync must not overwrite
      # when preparser already returned usable dimensions.
      File.write(path, "Gene,a\ng1,1\n")
      output = {
        'file_path' => path,
        'list_groups' => [
          { 'group' => 'matrix.csv', 'nber_rows' => 33694, 'nber_cols' => 73681 }
        ]
      }

      Basic.sync_raw_text_dimensions_from_file!(
        output,
        gene_name_col: 'first',
        delimiter: ',',
        has_header: true
      )

      assert_equal 33694, output['list_groups'][0]['nber_rows']
      assert_equal 73681, output['list_groups'][0]['nber_cols']
    end
  end

  test 'sync_raw_text_dimensions_from_file! fills dims when preparser left zero columns' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'matrix.csv')
      File.write(path, <<~CSV)
        Gene,c1,c2
        g1,1,2
        g2,3,4
      CSV
      output = {
        'file_path' => path,
        'list_groups' => [
          { 'group' => 'matrix.csv', 'nber_rows' => 2, 'nber_cols' => 0 }
        ]
      }

      Basic.sync_raw_text_dimensions_from_file!(
        output,
        gene_name_col: 'first',
        delimiter: ',',
        has_header: true
      )

      assert_equal 2, output['list_groups'][0]['nber_rows']
      assert_equal 2, output['list_groups'][0]['nber_cols']
    end
  end
end
