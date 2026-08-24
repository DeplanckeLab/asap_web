# frozen_string_literal: true

require 'test_helper'
require 'fileutils'
require 'tmpdir'
require 'ostruct'

class DeCellUniverseAttachTest < ActiveSupport::TestCase
  test 'attach_de_cell_universe_files! moves staged bin into the DE run directory' do
    Dir.mktmpdir('asap_de_univ_attach') do |dir|
      project_dir = Pathname.new(dir)
      step_dir = project_dir + 'de'
      run_dir = step_dir + '99'
      FileUtils.mkdir_p(run_dir)

      staged_rel = File.join('tmp', 'de_cell_universe', 'abc_filtered_in.bin')
      staged_abs = project_dir + staged_rel
      FileUtils.mkdir_p(staged_abs.dirname)
      payload = [0, 2, 4].pack('V*')
      File.binwrite(staged_abs, payload)

      run = OpenStruct.new(
        id: 99,
        attrs_json: {
          cell_universe_file: staged_rel,
          cell_universe_mode: 'in',
          cell_universe_n_cells: 10,
          cell_universe_n_indices: 3
        }.to_json
      )
      def run.save!
        true
      end

      list_of_runs2 = [[run, Basic.safe_parse_json(run.attrs_json, {})]]
      controller = ReqsController.new
      controller.instance_variable_set(:@step, OpenStruct.new(name: 'de', multiple_runs: true))
      controller.send(:attach_de_cell_universe_files!, list_of_runs2, project_dir, step_dir)

      dest = run_dir + 'filtered_in.bin'
      assert File.file?(dest)
      assert_equal [0, 2, 4], File.binread(dest).unpack('V*')
      refute File.exist?(staged_abs)

      attrs = Basic.safe_parse_json(run.attrs_json, {})
      assert_equal 'de/99/filtered_in.bin', attrs['cell_universe_file']
      assert_equal 'in', attrs['cell_universe_mode']
      assert_equal 'de/99/filtered_in.bin', list_of_runs2[0][1]['cell_universe_file']
    end
  end
end
