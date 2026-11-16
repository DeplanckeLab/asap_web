# frozen_string_literal: true

require_relative "../services/test_base_without_fixtures"

class FilterV8PythonStdMethodsTest < TestBaseWithoutFixtures
  M = FilterV8PythonStdMethods

  test "python_program_for replaces the java ASAP.jar call and keeps what follows" do
    assert_equal "python3 /srv/filter.v8.py", M.python_program_for("java -jar /srv/ASAP.jar")
    assert_equal "python3 /srv/filter.v8.py", M.python_program_for("java -jar ASAP.jar")
    assert_equal "python3 /srv/filter.v8.py -T FilterCols", M.python_program_for("java -Xms4g -Xmx8g -jar /srv/ASAP.jar -T FilterCols")
    assert_equal "python3 /srv/filter.v8.py", M.python_program_for("/usr/bin/java -jar lib/ASAP.jar")
    assert_nil M.python_program_for("Rscript --vanilla filtering.bulk.v8.R")
    assert_nil M.python_program_for("java -jar /srv/other.jar")
    assert_nil M.python_program_for(nil)
  end

  test "filter_mode reads -T from opts or from the program" do
    assert_equal "FilterCols", M.filter_mode({ "program" => "java -jar /srv/ASAP.jar", "opts" => [{ "opt" => "-T", "value" => "FilterCols" }] })
    assert_equal "FilterRows", M.filter_mode({ "program" => "java -jar /srv/ASAP.jar -T FilterRows -m keep" })
    assert_nil M.filter_mode({ "program" => "java -jar /srv/ASAP.jar", "opts" => [{ "opt" => "-T", "value" => "ModuleScore" }] })
    assert_nil M.filter_mode({ "program" => "java -jar /srv/ASAP.jar -T FilterDEMetadata" })
  end

  test "a Step holding the whole Java filtering command is rewritten, opts kept" do
    opts = [{ "opt" => "-T", "value" => "FilterCols" }, { "opt" => "-loom", "param_key" => "input_matrix_filename" },
            { "opt" => "-o", "param_key" => "output_dir" }, { "opt" => "-col_indexes_file", "value" => "\#{output_dir}/discarded_cols.json" }]
    step = { "program" => "java -jar /srv/ASAP.jar", "docker_image" => "asap_run", "opts" => opts }
    new_step = M.rewritten_step_command(step)
    assert_equal "python3 /srv/filter.v8.py", new_step["program"]
    assert_equal opts, new_step["opts"]
    assert_equal step.keys, new_step.keys
    assert_nil M.rewritten_step_command(new_step), "already rewritten"
  end

  test "a StdMethod inheriting the Java program from its Step gets its own Python program" do
    step = { "program" => "java -jar /srv/ASAP.jar", "docker_image" => "asap_run" }
    method = { "opts" => [{ "opt" => "-T", "value" => "FilterRows" }, { "opt" => "-m", "value" => "basic" }] }
    assert_nil M.rewritten_step_command(step), "step alone has no filtering mode"
    new_method = M.rewritten_method_command(step, method)
    assert_equal "python3 /srv/filter.v8.py", new_method["program"]
    assert_equal %w[program opts], new_method.keys
    assert_equal method["opts"], new_method["opts"]
  end

  test "a StdMethod with its own Java filtering program is rewritten in place" do
    method = { "program" => "java -jar /srv/ASAP.jar", "opts" => [{ "opt" => "-T", "value" => "FilterCols" }], "predict_params" => ["nber_cols"] }
    new_method = M.rewritten_method_command({}, method)
    assert_equal "python3 /srv/filter.v8.py", new_method["program"]
    assert_equal method.keys, new_method.keys
  end

  test "other Java modes and non-Java commands are left alone" do
    module_score = { "program" => "java -jar /srv/ASAP.jar", "opts" => [{ "opt" => "-T", "value" => "ModuleScore" }] }
    assert_nil M.rewritten_method_command({}, module_score)
    assert_nil M.rewritten_method_command({ "program" => "Rscript --vanilla filtering.bulk.v8.R" }, { "opts" => [] })
    assert_nil M.rewritten_method_command({}, { "program" => "python3 /srv/filter.v8.py", "opts" => [{ "opt" => "-T", "value" => "FilterCols" }] })
  end
end
