require "shellwords"

namespace :de do
  LOOM_FILE         = "/data/asap2_test/users/2/2qj430/parsing/output.loom"
  DE_SCRIPT         = "/srv/de.v8.py"
  DE_SCRIPT_APPROX  = "/srv/de_approx.v8.py"
  CONTAINER         = ENV.fetch("ASAP_RUN_CONTAINER", "asap_run_test")
  METHOD            = "t_test_approx"
  INPUT_DS     = "/layers/norm_1_seurat"
  GROUP_DS     = "/col_attrs/DF.classifications"
  GROUP_DS_2   = "/col_attrs/final_annotation_ontology_term"
  WRITE_META   = "/attrs/_de_test"
  GROUP_1      = "Singlet"
  GROUP_2      = "Doublet"
  GROUP_2_ALT  = "Epidermal cell"

  # Shared preview options applied to every invocation
  PREVIEW_OPTS = "--preview-cell-fraction 0.15 --table-top-de-per-direction 2"

  BENCH_METHODS = %w[t_test_approx wilcoxon t_test t_test_overestim_var]

  # Two-group ontology benchmark: both groups from the same column
  BENCH_ONTO_DS  = "/col_attrs/final_annotation_ontology_term"
  BENCH_ONTO_G1  = "Epidermal cell"
  BENCH_ONTO_G2  = "Abdominal oenocyte"

  # ─── Helpers ──────────────────────────────────────────────────────────

  # t_test_approx lives in de_approx.v8.py; other methods use de.v8.py (same CLI).
  def de_script_for(method_name)
    method_name.to_s == "t_test_approx" ? DE_SCRIPT_APPROX : DE_SCRIPT
  end

  def de_run(label, extra_args, output_dir, method_override: nil, preview_override: nil)
    FileUtils.rm_rf(output_dir)
    FileUtils.mkdir_p(output_dir)

    method_val  = method_override || METHOD
    preview_val = preview_override.nil? ? PREVIEW_OPTS : preview_override

    script = de_script_for(method_val)

    cmd = [
      "docker exec #{CONTAINER} python3 -u #{script}",
      "-f #{LOOM_FILE}",
      "--method #{method_val}",
      "--input-dataset #{INPUT_DS}",
      "--is-count false",
      preview_val,
      extra_args,
    ].compact.reject(&:empty?).join(" ")

    puts ""
    puts "=" * 100
    puts "[#{label}]"
    puts "  Script: #{script}"
    puts "  CMD: #{cmd}"
    puts "=" * 100

    output = `#{cmd} 2>&1`
    ok     = $?.success?

    puts output
    puts ok ? "  => Command succeeded" : "  => Command FAILED (exit #{$?.exitstatus})"
    [ok, output]
  end

  def parse_output_json(output_dir)
    json_path = File.join(output_dir, "output.json")
    unless File.exist?(json_path)
      puts "  FAIL: output.json not found at #{json_path}"
      return nil
    end
    JSON.parse(File.read(json_path))
  end

  def parse_stdout_json(stdout)
    JSON.parse(stdout)
  rescue JSON::ParserError => e
    puts "  FAIL: Could not parse stdout JSON: #{e.message}"
    nil
  end

  def check_json_structure(json, mode, label, opts = {})
    errors = []
    unless json.is_a?(Hash)
      puts "  FAIL: [#{label}] JSON root is not a Hash"
      return false
    end

    # metadata array
    meta = json["metadata"]
    unless meta.is_a?(Array) && meta.size > 0
      errors << "Missing or empty 'metadata' array"
    else
      m = meta.first
      %w[on type nber_cols nber_rows headers].each do |key|
        errors << "metadata[0] missing key '#{key}'" unless m.key?(key)
      end
      errors << "nber_rows should be > 0 (got #{m['nber_rows']})" if m["nber_rows"].to_i <= 0
      errors << "nber_cols should be > 0 (got #{m['nber_cols']})" if m["nber_cols"].to_i <= 0
    end

    # mode
    errors << "Expected mode '#{mode}', got '#{json['mode']}'" if json["mode"] != mode

    # group sizes
    if mode == "FindAllMarkers"
      errors << "Missing 'number_of_groups'" unless json.key?("number_of_groups")
      errors << "Missing 'group_sizes'" unless json.key?("group_sizes")
      errors << "Missing 'list_cats_json'" unless json.key?("list_cats_json")
      if json["number_of_groups"].to_i < 2
        errors << "number_of_groups should be >= 2 (got #{json['number_of_groups']})"
      end
    else
      errors << "Missing 'group_size'"  unless json.key?("group_size")
      errors << "Missing 'group2_size'" unless json.key?("group2_size")
      errors << "group_size should be > 0"  if json["group_size"].to_i <= 0
      errors << "group2_size should be > 0" if json["group2_size"].to_i <= 0
    end

    # tested genes
    errors << "Missing 'number_of_genes_tested'" unless json.key?("number_of_genes_tested")
    errors << "number_of_genes_tested should be > 0" if json["number_of_genes_tested"].to_i <= 0

    # FDR
    errors << "Missing 'number_of_genes_with_fdr_le_5pct'" unless json.key?("number_of_genes_with_fdr_le_5pct")

    # overlapping_cells
    if opts[:expect_overlap]
      errors << "overlapping_cells should be >= 0" unless json.key?("overlapping_cells")
    end

    # Two-group specific checks
    if mode == "Two-group DE"
      errors << "Missing 'group_name'"  unless json.key?("group_name")
      errors << "Missing 'group2_name'" unless json.key?("group2_name")
      errors << "group_name mismatch (expected '#{opts[:g1]}', got '#{json['group_name']}')" if opts[:g1] && json["group_name"] != opts[:g1]
      errors << "group2_name mismatch (expected '#{opts[:g2]}', got '#{json['group2_name']}')" if opts[:g2] && json["group2_name"] != opts[:g2]
    end

    # Single marker
    if mode == "Single marker"
      errors << "Missing 'group_name'" unless json.key?("group_name")
      errors << "group_name mismatch (expected '#{opts[:g1]}', got '#{json['group_name']}')" if opts[:g1] && json["group_name"] != opts[:g1]
    end

    # Preview
    if opts[:expect_preview]
      unless json["preview"].is_a?(Hash) && json["preview"]["applied"] == true
        errors << "Preview was expected but not found or not applied"
      end
    end

    # Warnings
    if json["warnings"].is_a?(Array)
      json["warnings"].each { |w| puts "  WARNING from script: #{w}" }
    end

    if errors.any?
      errors.each { |e| puts "  FAIL: [#{label}] #{e}" }
      false
    else
      puts "  PASS: [#{label}] output.json structure is valid"
      true
    end
  end

  def check_file_exists(path, label)
    if File.exist?(path)
      size = (File.size(path) / 1024.0).round(2)
      puts "  PASS: [#{label}] #{File.basename(path)} exists (#{size} KB)"
      true
    else
      puts "  FAIL: [#{label}] #{File.basename(path)} missing"
      false
    end
  end

  def check_tsv(path, label, opts = {})
    return false unless check_file_exists(path, label)
    lines = File.readlines(path)
    if lines.size < 2
      puts "  FAIL: [#{label}] TSV has fewer than 2 lines (header + data)"
      return false
    end
    header = lines.first.strip.split("\t")
    puts "  INFO: [#{label}] TSV columns: #{header.join(', ')} (#{lines.size - 1} data rows)"

    if opts[:expect_group_column]
      unless header.first == "Compared group"
        puts "  FAIL: [#{label}] Expected first TSV column to be 'Compared group'"
        return false
      end
    end
    true
  end

  def check_de_table(json, label)
    return false unless json
    dt = json["de_table"]
    if dt.is_a?(Hash) && dt["rows"].is_a?(Array)
      puts "  PASS: [#{label}] de_table present in stdout (#{dt['rows'].size} rows)"
      true
    elsif dt.is_a?(Array)
      puts "  PASS: [#{label}] de_table present in stdout (#{dt.size} rows)"
      true
    else
      puts "  FAIL: [#{label}] de_table missing from stdout JSON"
      false
    end
  end

  def check_metadata_in_loom(meta_path, label)
    cmd = "docker exec #{CONTAINER} python3 -c \"" \
          "import h5py; " \
          "f = h5py.File('#{LOOM_FILE}', 'r'); " \
          "ds = f.get('#{meta_path}'); " \
          "print('EXISTS' if ds is not None else 'MISSING'); " \
          "print('shape=' + str(ds.shape)) if ds is not None else None; " \
          "f.close()\""
    out = `#{cmd} 2>&1`.strip
    if out.include?("EXISTS")
      puts "  PASS: [#{label}] Metadata '#{meta_path}' written in loom (#{out.split("\n").last})"
      true
    else
      puts "  FAIL: [#{label}] Metadata '#{meta_path}' not found in loom"
      false
    end
  end

  def delete_metadata_from_loom(meta_path)
    cmd = "docker exec #{CONTAINER} python3 -c \"" \
          "import h5py; " \
          "f = h5py.File('#{LOOM_FILE}', 'r+'); " \
          "f.pop('#{meta_path}', None); " \
          "f.close()\""
    `#{cmd} 2>&1`
  end

  def report(results)
    puts ""
    puts "=" * 100
    puts "SUMMARY"
    puts "=" * 100
    total = results.size
    passed = results.count { |r| r[:pass] }
    failed = total - passed

    results.each do |r|
      status = r[:pass] ? "PASS" : "FAIL"
      puts "  [#{status}] #{r[:name]}"
    end

    puts ""
    puts "Total: #{total} | Passed: #{passed} | Failed: #{failed}"
    puts "=" * 100
    failed == 0
  end

  # ─── Scenario runners ────────────────────────────────────────────────

  def run_scenario_all_markers(results)
    base_dir = "/data/asap2_test/tests/de"

    # --- Sub-test A: with -o + --write-tsv (per-category cat_N.tsv files) ---
    label   = "S1a: All-vs-complementary with per-category TSV"
    out_dir = File.join(base_dir, "s1a")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} -o #{out_dir} --write-tsv",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "FindAllMarkers", label, expect_preview: true)
      if json && json["list_cats_json"].is_a?(Array)
        json["list_cats_json"].each_with_index do |_cat, i|
          check_file_exists(File.join(out_dir, "cat_#{i + 1}.tsv"), "#{label}/cat_#{i + 1}.tsv")
        end
      end
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test B: with -o + --write-tsv + --merge-files (single output.tsv) ---
    label   = "S1b: All-vs-complementary with merged TSV"
    out_dir = File.join(base_dir, "s1b")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} -o #{out_dir} --write-tsv --merge-files",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "FindAllMarkers", label, expect_preview: true)
      pass = check_tsv(File.join(out_dir, "output.tsv"), label, expect_group_column: true) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test C: with --write-metadata ---
    meta_path = "#{WRITE_META}_s1c"
    label     = "S1c: All-vs-complementary with metadata"
    out_dir   = File.join(base_dir, "s1c")
    delete_metadata_from_loom("attrs/#{meta_path.split('/').last}")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} -o #{out_dir} --write-metadata #{meta_path}",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "FindAllMarkers", label, expect_preview: true)
      pass = check_metadata_in_loom(meta_path, label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test D: stdout-only (no -o) ---
    label   = "S1d: All-vs-complementary stdout-only"
    out_dir = File.join(base_dir, "s1d")
    ok, output = de_run(label,
      "--group-dataset #{GROUP_DS}",
      out_dir)
    if ok
      json = parse_stdout_json(output)
      pass = json && check_json_structure(json, "FindAllMarkers", label, expect_preview: true)
      pass = check_de_table(json, label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }
  end

  def run_scenario_two_group_same_metadata(results)
    base_dir = "/data/asap2_test/tests/de"

    # --- Sub-test A: with -o + --write-tsv ---
    label   = "S2a: Two-group same metadata with TSV"
    out_dir = File.join(base_dir, "s2a")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} --group #{GROUP_1} --group-2 #{GROUP_2} -o #{out_dir} --write-tsv",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "Two-group DE", label,
        expect_preview: true, g1: GROUP_1, g2: GROUP_2)
      pass = check_tsv(File.join(out_dir, "output.tsv"), label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test B: with --write-metadata ---
    meta_path = "#{WRITE_META}_s2b"
    label     = "S2b: Two-group same metadata with metadata"
    out_dir   = File.join(base_dir, "s2b")
    delete_metadata_from_loom("attrs/#{meta_path.split('/').last}")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} --group #{GROUP_1} --group-2 #{GROUP_2} -o #{out_dir} --write-metadata #{meta_path}",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "Two-group DE", label,
        expect_preview: true, g1: GROUP_1, g2: GROUP_2)
      pass = check_metadata_in_loom(meta_path, label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test C: with --write-volcano ---
    label   = "S2c: Two-group same metadata with volcano"
    out_dir = File.join(base_dir, "s2c")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} --group #{GROUP_1} --group-2 #{GROUP_2} -o #{out_dir} --write-volcano",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "Two-group DE", label,
        expect_preview: true, g1: GROUP_1, g2: GROUP_2)
      pass = check_file_exists(File.join(out_dir, "output.plot.json"), label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test D: stdout-only ---
    label   = "S2d: Two-group same metadata stdout-only"
    out_dir = File.join(base_dir, "s2d")
    ok, output = de_run(label,
      "--group-dataset #{GROUP_DS} --group #{GROUP_1} --group-2 #{GROUP_2}",
      out_dir)
    if ok
      json = parse_stdout_json(output)
      pass = json && check_json_structure(json, "Two-group DE", label,
        expect_preview: true, g1: GROUP_1, g2: GROUP_2)
      pass = check_de_table(json, label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test E: all outputs combined ---
    meta_path = "#{WRITE_META}_s2e"
    label     = "S2e: Two-group same metadata all outputs"
    out_dir   = File.join(base_dir, "s2e")
    delete_metadata_from_loom("attrs/#{meta_path.split('/').last}")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} --group #{GROUP_1} --group-2 #{GROUP_2} " \
      "-o #{out_dir} --write-tsv --write-volcano --write-metadata #{meta_path}",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "Two-group DE", label,
        expect_preview: true, g1: GROUP_1, g2: GROUP_2)
      pass = check_tsv(File.join(out_dir, "output.tsv"), label) && pass
      pass = check_file_exists(File.join(out_dir, "output.plot.json"), label) && pass
      pass = check_metadata_in_loom(meta_path, label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }
  end

  def run_scenario_single_marker(results)
    base_dir = "/data/asap2_test/tests/de"

    # --- Sub-test A: with -o + --write-tsv ---
    label   = "S3a: Single-marker with TSV"
    out_dir = File.join(base_dir, "s3a")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} --group #{GROUP_1} -o #{out_dir} --write-tsv",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "Single marker", label,
        expect_preview: true, g1: GROUP_1)
      pass = check_tsv(File.join(out_dir, "output.tsv"), label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test B: with --write-metadata ---
    meta_path = "#{WRITE_META}_s3b"
    label     = "S3b: Single-marker with metadata"
    out_dir   = File.join(base_dir, "s3b")
    delete_metadata_from_loom("attrs/#{meta_path.split('/').last}")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} --group #{GROUP_1} -o #{out_dir} --write-metadata #{meta_path}",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "Single marker", label,
        expect_preview: true, g1: GROUP_1)
      pass = check_metadata_in_loom(meta_path, label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test C: with --write-volcano ---
    label   = "S3c: Single-marker with volcano"
    out_dir = File.join(base_dir, "s3c")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} --group #{GROUP_1} -o #{out_dir} --write-volcano",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "Single marker", label,
        expect_preview: true, g1: GROUP_1)
      pass = check_file_exists(File.join(out_dir, "output.plot.json"), label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test D: stdout-only ---
    label   = "S3d: Single-marker stdout-only"
    out_dir = File.join(base_dir, "s3d")
    ok, output = de_run(label,
      "--group-dataset #{GROUP_DS} --group #{GROUP_1}",
      out_dir)
    if ok
      json = parse_stdout_json(output)
      pass = json && check_json_structure(json, "Single marker", label,
        expect_preview: true, g1: GROUP_1)
      pass = check_de_table(json, label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test E: all outputs combined ---
    meta_path = "#{WRITE_META}_s3e"
    label     = "S3e: Single-marker all outputs"
    out_dir   = File.join(base_dir, "s3e")
    delete_metadata_from_loom("attrs/#{meta_path.split('/').last}")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} --group #{GROUP_1} " \
      "-o #{out_dir} --write-tsv --write-volcano --write-metadata #{meta_path}",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "Single marker", label,
        expect_preview: true, g1: GROUP_1)
      pass = check_tsv(File.join(out_dir, "output.tsv"), label) && pass
      pass = check_file_exists(File.join(out_dir, "output.plot.json"), label) && pass
      pass = check_metadata_in_loom(meta_path, label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }
  end

  def run_scenario_two_group_diff_metadata(results)
    base_dir = "/data/asap2_test/tests/de"
    # Use Doublet as group-1 here: Singlet covers 99.8% of cells, so any group-2
    # from the other column would lose almost all cells to overlap removal.
    # Doublet (117 cells) has minimal overlap with the second annotation column.
    s4_g1 = GROUP_2  # Doublet

    # --- Sub-test A: with -o + --write-tsv ---
    label   = "S4a: Two-group diff metadata with TSV"
    out_dir = File.join(base_dir, "s4a")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} --group-dataset-2 #{GROUP_DS_2} " \
      "--group #{s4_g1} --group-2 \"#{GROUP_2_ALT}\" -o #{out_dir} --write-tsv",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "Two-group DE", label,
        expect_preview: true, expect_overlap: true, g1: s4_g1, g2: GROUP_2_ALT)
      pass = check_tsv(File.join(out_dir, "output.tsv"), label) && pass
      if json
        overlap = json["overlapping_cells"].to_i
        puts "  INFO: [#{label}] overlapping_cells = #{overlap}"
      end
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test B: with --write-metadata ---
    meta_path = "#{WRITE_META}_s4b"
    label     = "S4b: Two-group diff metadata with metadata"
    out_dir   = File.join(base_dir, "s4b")
    delete_metadata_from_loom("attrs/#{meta_path.split('/').last}")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} --group-dataset-2 #{GROUP_DS_2} " \
      "--group #{s4_g1} --group-2 \"#{GROUP_2_ALT}\" -o #{out_dir} --write-metadata #{meta_path}",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "Two-group DE", label,
        expect_preview: true, expect_overlap: true, g1: s4_g1, g2: GROUP_2_ALT)
      pass = check_metadata_in_loom(meta_path, label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test C: with --write-volcano ---
    label   = "S4c: Two-group diff metadata with volcano"
    out_dir = File.join(base_dir, "s4c")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} --group-dataset-2 #{GROUP_DS_2} " \
      "--group #{s4_g1} --group-2 \"#{GROUP_2_ALT}\" -o #{out_dir} --write-volcano",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "Two-group DE", label,
        expect_preview: true, expect_overlap: true, g1: s4_g1, g2: GROUP_2_ALT)
      pass = check_file_exists(File.join(out_dir, "output.plot.json"), label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test D: stdout-only ---
    label   = "S4d: Two-group diff metadata stdout-only"
    out_dir = File.join(base_dir, "s4d")
    ok, output = de_run(label,
      "--group-dataset #{GROUP_DS} --group-dataset-2 #{GROUP_DS_2} " \
      "--group #{s4_g1} --group-2 \"#{GROUP_2_ALT}\"",
      out_dir)
    if ok
      json = parse_stdout_json(output)
      pass = json && check_json_structure(json, "Two-group DE", label,
        expect_preview: true, expect_overlap: true, g1: s4_g1, g2: GROUP_2_ALT)
      pass = check_de_table(json, label) && pass
    else
      pass = false
    end
    results << { name: label, pass: pass }

    # --- Sub-test E: all outputs combined ---
    meta_path = "#{WRITE_META}_s4e"
    label     = "S4e: Two-group diff metadata all outputs"
    out_dir   = File.join(base_dir, "s4e")
    delete_metadata_from_loom("attrs/#{meta_path.split('/').last}")
    ok, _output = de_run(label,
      "--group-dataset #{GROUP_DS} --group-dataset-2 #{GROUP_DS_2} " \
      "--group #{s4_g1} --group-2 \"#{GROUP_2_ALT}\" " \
      "-o #{out_dir} --write-tsv --write-volcano --write-metadata #{meta_path}",
      out_dir)
    if ok
      json = parse_output_json(out_dir)
      pass = json && check_json_structure(json, "Two-group DE", label,
        expect_preview: true, expect_overlap: true, g1: s4_g1, g2: GROUP_2_ALT)
      pass = check_tsv(File.join(out_dir, "output.tsv"), label) && pass
      pass = check_file_exists(File.join(out_dir, "output.plot.json"), label) && pass
      pass = check_metadata_in_loom(meta_path, label) && pass
      if json
        overlap = json["overlapping_cells"].to_i
        puts "  INFO: [#{label}] overlapping_cells = #{overlap}"
      end
    else
      pass = false
    end
    results << { name: label, pass: pass }
  end

  # ─── Tasks ───────────────────────────────────────────────────────────

  desc "Run all DE v8 test scenarios"
  task test_all: :environment do
    puts "DE v8 Test Suite"
    puts "=" * 100
    puts "Loom file:  #{LOOM_FILE}"
    puts "Container:  #{CONTAINER}"
    puts "Method:     #{METHOD}"
    puts "Input DS:   #{INPUT_DS}"
    puts "Group DS:   #{GROUP_DS}"
    puts "Group DS 2: #{GROUP_DS_2}"
    puts ""

    unless File.exist?(LOOM_FILE)
      puts "ERROR: Loom file not found: #{LOOM_FILE}"
      exit 1
    end

    running = `docker inspect -f '{{.State.Running}}' #{CONTAINER} 2>&1`.strip
    unless running == "true"
      puts "ERROR: Container '#{CONTAINER}' is not running."
      puts "Start it with: docker compose -f docker-compose.test.yml up -d asap_run"
      exit 1
    end

    results = []

    puts ""
    puts "#" * 100
    puts "# SCENARIO 1: FindAllMarkers (all groups vs complementary)"
    puts "#" * 100
    run_scenario_all_markers(results)

    puts ""
    puts "#" * 100
    puts "# SCENARIO 2: Two-group DE (same metadata: #{GROUP_1} vs #{GROUP_2})"
    puts "#" * 100
    run_scenario_two_group_same_metadata(results)

    puts ""
    puts "#" * 100
    puts "# SCENARIO 3: Single marker (#{GROUP_1} vs complementary)"
    puts "#" * 100
    run_scenario_single_marker(results)

    puts ""
    puts "#" * 100
    puts "# SCENARIO 4: Two-group DE (different metadata: #{GROUP_2} vs #{GROUP_2_ALT})"
    puts "#" * 100
    run_scenario_two_group_diff_metadata(results)

    all_pass = report(results)
    exit(all_pass ? 0 : 1)
  end

  desc "Run scenario 1 only: FindAllMarkers (all vs complementary)"
  task test_all_markers: :environment do
    results = []
    run_scenario_all_markers(results)
    exit(report(results) ? 0 : 1)
  end

  desc "Run scenario 2 only: Two-group DE (same metadata)"
  task test_two_group_same: :environment do
    results = []
    run_scenario_two_group_same_metadata(results)
    exit(report(results) ? 0 : 1)
  end

  desc "Run scenario 3 only: Single marker vs complementary"
  task test_single_marker: :environment do
    results = []
    run_scenario_single_marker(results)
    exit(report(results) ? 0 : 1)
  end

  desc "Run scenario 4 only: Two-group DE (different metadata)"
  task test_two_group_diff: :environment do
    results = []
    run_scenario_two_group_diff_metadata(results)
    exit(report(results) ? 0 : 1)
  end

  # ─── Benchmark ───────────────────────────────────────────────────────

  # Each config: [label, preview_args, top_de]
  # All runs use -o to write output.json only (no TSV, no metadata, no stdout).
  BENCH_CONFIGS = [
    ["no-preview",            "",                                nil],
    ["preview-0.15",          "--preview-cell-fraction 0.15",    nil],
    ["preview-0.15 top-de-2", "--preview-cell-fraction 0.15",    2],
    ["preview-0.50",          "--preview-cell-fraction 0.50",    nil],
    ["preview-1.0",           "--preview-cell-fraction 1.0",     nil],
  ].freeze

  def run_benchmark_all_markers
    base_dir = "/data/asap2_test/tests/de/bench"
    bench_results = []
    run_index = 0

    BENCH_METHODS.each do |method|
      BENCH_CONFIGS.each do |cfg_label, preview_args, top_de|
        run_index += 1
        tag     = "bench_%02d" % run_index
        out_dir = File.join(base_dir, tag)
        label   = "B#{run_index}: #{method} | #{cfg_label}"

        preview_full = preview_args.dup
        preview_full += " --table-top-de-per-direction #{top_de}" if top_de

        extra = "--group-dataset #{GROUP_DS} -o #{out_dir}"

        t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ok, _output = de_run(label, extra, out_dir,
                             method_override: method,
                             preview_override: preview_full)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start

        pass = false
        genes_tested = 0
        genes_fdr    = 0
        n_groups     = 0
        if ok
          json = parse_output_json(out_dir)
          if json
            pass         = check_json_structure(json, "FindAllMarkers", label, expect_preview: !preview_args.empty?)
            genes_tested = json["number_of_genes_tested"].to_i
            genes_fdr    = json["number_of_genes_with_fdr_le_5pct"].to_i
            n_groups     = json["number_of_groups"].to_i
          end
        end

        bench_results << {
          rank:         0,
          label:        label,
          method:       method,
          options:      cfg_label,
          elapsed:      elapsed,
          pass:         pass,
          genes_tested: genes_tested,
          genes_fdr:    genes_fdr,
          n_groups:     n_groups,
        }
      end
    end

    bench_results
  end

  def print_benchmark_table(bench_results)
    sorted = bench_results.sort_by { |r| r[:elapsed] }
    sorted.each_with_index { |r, i| r[:rank] = i + 1 }

    col_rank    = 4
    col_method  = [6, *sorted.map { |r| r[:method].size }].max
    col_options = [7, *sorted.map { |r| r[:options].size }].max
    col_time    = 10
    col_status  = 6
    col_groups  = 6
    col_genes   = 12
    col_fdr     = 10

    header = "%-#{col_rank}s  %-#{col_method}s  %-#{col_options}s  %#{col_time}s  %-#{col_status}s  %#{col_groups}s  %#{col_genes}s  %#{col_fdr}s" %
             ["#", "Method", "Options", "Time (s)", "Status", "Groups", "Genes tested", "Genes FDR"]
    sep = "-" * header.size

    puts ""
    puts ""
    puts "=" * header.size
    puts "BENCHMARK RESULTS: FindAllMarkers (sorted by execution time)"
    puts "=" * header.size
    puts header
    puts sep

    sorted.each do |r|
      status = r[:pass] ? "PASS" : "FAIL"
      time_s = "%.2f" % r[:elapsed]
      row = "%-#{col_rank}s  %-#{col_method}s  %-#{col_options}s  %#{col_time}s  %-#{col_status}s  %#{col_groups}s  %#{col_genes}s  %#{col_fdr}s" %
            [r[:rank], r[:method], r[:options], time_s, status, r[:n_groups], r[:genes_tested], r[:genes_fdr]]
      puts row
    end

    puts sep

    fastest = sorted.first[:elapsed]
    slowest = sorted.last[:elapsed]
    passed  = sorted.count { |r| r[:pass] }
    failed  = sorted.count { |r| !r[:pass] }

    puts ""
    puts "Total runs: #{sorted.size} | Passed: #{passed} | Failed: #{failed}"
    puts "Fastest: %.2fs (%s | %s)" % [fastest, sorted.first[:method], sorted.first[:options]]
    puts "Slowest: %.2fs (%s | %s)" % [slowest, sorted.last[:method], sorted.last[:options]]
    if fastest > 0
      puts "Slowest / Fastest ratio: %.1fx" % (slowest / fastest)
    end
    puts "=" * header.size

    failed == 0
  end

  desc "Benchmark FindAllMarkers across methods and option combinations"
  task benchmark_all_markers: :environment do
    puts "DE v8 Benchmark: FindAllMarkers"
    puts "=" * 100
    puts "Loom file:  #{LOOM_FILE}"
    puts "Container:  #{CONTAINER}"
    puts "Input DS:   #{INPUT_DS}"
    puts "Group DS:   #{GROUP_DS}"
    puts "Methods:    #{BENCH_METHODS.join(', ')}"
    puts ""

    unless File.exist?(LOOM_FILE)
      puts "ERROR: Loom file not found: #{LOOM_FILE}"
      exit 1
    end

    running = `docker inspect -f '{{.State.Running}}' #{CONTAINER} 2>&1`.strip
    unless running == "true"
      puts "ERROR: Container '#{CONTAINER}' is not running."
      puts "Start it with: docker compose -f docker-compose.test.yml up -d asap_run"
      exit 1
    end

    bench_results = run_benchmark_all_markers
    all_pass = print_benchmark_table(bench_results)
    exit(all_pass ? 0 : 1)
  end

  # ─── Two-group ontology benchmark (reference: t_test, no preview) ─────

  # [label, preview_args]  preview_args empty string = no preview
  TWO_GROUP_ONTO_PREVIEW_CONFIGS = [
    ["no-preview", ""],
    ["preview-0.15",         "--preview-cell-fraction 0.15"],
    ["preview-0.50",         "--preview-cell-fraction 0.50"],
    ["preview-1.0",          "--preview-cell-fraction 1.0"],
  ].freeze

  REF_METHOD = "t_test"
  TOP_N      = 10

  # [mode_key, table heading, one-line description of how top-10 up/down are chosen]
  ONTOLOGY_RANK_MODES = [
    [
      :pvalue,
      "Table 1: p-value ordering",
      "Within each direction (by LFC sign): ascending p-value, then logFC (same pairwise top-N ordering as de.v8.py / de_approx.v8.py).",
    ],
    [
      :fdr,
      "Table 2: FDR ordering",
      "Within each direction: ascending FDR, then logFC as tiebreak (genes without finite FDR are excluded from these ranked lists).",
    ],
    [
      :abs_lfc,
      "Table 3: |logFC| ordering",
      "Within each direction: descending |logFC| (up: largest positive LFC first; down: most negative first), then ascending p-value as tiebreak.",
    ],
  ].freeze

  # Same ranking as de.v8.py / de_approx.v8.py _de_table_gene_order_pairwise for n_top branch:
  # within up (LFC>0): ascending p-value, then descending LFC;
  # within down (LFC<0): ascending p-value, then ascending LFC.
  def de_parse_float(s)
    return nil if s.nil? || s.strip.empty? || s.strip.casecmp("na").zero?
    Float(s)
  rescue ArgumentError
    nil
  end

  def de_parse_tsv_rows(tsv_path)
    rows = []
    File.foreach(tsv_path).with_index do |line, idx|
      next if idx.zero?
      cols = line.chomp.split("\t")
      next if cols.size < 6
      rows << {
        ensembl: cols[0].to_s.strip,
        gene:    cols[1].to_s.strip,
        lfc:     de_parse_float(cols[2]),
        p:       de_parse_float(cols[3]),
        fdr:     de_parse_float(cols[4]),
      }
    end
    rows
  end

  def de_finite_p?(p)
    p.is_a?(Numeric) && p.finite? && !p.nan?
  end

  def de_rows_ranked_up(rows)
    rows.select { |r| r[:lfc].is_a?(Numeric) && r[:lfc] > 0.0 && de_finite_p?(r[:p]) }
        .sort_by { |r| [r[:p], -r[:lfc]] }
  end

  def de_rows_ranked_down(rows)
    rows.select { |r| r[:lfc].is_a?(Numeric) && r[:lfc] < 0.0 && de_finite_p?(r[:p]) }
        .sort_by { |r| [r[:p], r[:lfc]] }
  end

  def de_finite_fdr?(f)
    f.is_a?(Numeric) && f.finite? && !f.nan? && f >= 0.0 && f <= 1.0
  end

  def de_rows_ranked_up_fdr(rows)
    rows.select { |r| r[:lfc].is_a?(Numeric) && r[:lfc] > 0.0 && de_finite_fdr?(r[:fdr]) }
        .sort_by { |r| [r[:fdr], -r[:lfc]] }
  end

  def de_rows_ranked_down_fdr(rows)
    rows.select { |r| r[:lfc].is_a?(Numeric) && r[:lfc] < 0.0 && de_finite_fdr?(r[:fdr]) }
        .sort_by { |r| [r[:fdr], r[:lfc]] }
  end

  def de_rows_ranked_up_abs_lfc(rows)
    rows.select { |r| r[:lfc].is_a?(Numeric) && r[:lfc] > 0.0 && de_finite_p?(r[:p]) }
        .sort_by { |r| [-r[:lfc].abs, r[:p]] }
  end

  def de_rows_ranked_down_abs_lfc(rows)
    rows.select { |r| r[:lfc].is_a?(Numeric) && r[:lfc] < 0.0 && de_finite_p?(r[:p]) }
        .sort_by { |r| [-r[:lfc].abs, r[:p]] }
  end

  def de_rank_pairs(rows, mode)
    case mode
    when :pvalue
      [de_rows_ranked_up(rows), de_rows_ranked_down(rows)]
    when :fdr
      [de_rows_ranked_up_fdr(rows), de_rows_ranked_down_fdr(rows)]
    when :abs_lfc
      [de_rows_ranked_up_abs_lfc(rows), de_rows_ranked_down_abs_lfc(rows)]
    else
      raise ArgumentError, "unknown rank mode: #{mode.inspect}"
    end
  end

  def de_rank_position_hint(mode)
    case mode
    when :pvalue
      {
        up:   "full UP list: p-value ascending, then logFC descending",
        down: "full DOWN list: p-value ascending, then logFC ascending",
      }
    when :fdr
      {
        up:   "full UP list: FDR ascending, then logFC descending",
        down: "full DOWN list: FDR ascending, then logFC ascending",
      }
    when :abs_lfc
      {
        up:   "full UP list: |logFC| descending, then p-value ascending",
        down: "full DOWN list: |logFC| descending, then p-value ascending",
      }
    else
      { up: "full UP list", down: "full DOWN list" }
    end
  end

  def de_position_in_ranked(ensembl_id, ranked)
    idx = ranked.index { |r| r[:ensembl] == ensembl_id }
    idx ? idx + 1 : nil
  end

  def de_top_ids(ranked, n)
    ranked.first(n).map { |r| r[:ensembl] }
  end

  def de_compare_top_to_reference(ref_up, ref_down, oth_up, oth_down, oth_up_ranked, oth_down_ranked, ref_up_ranked, ref_down_ranked)
    ref_up_ids   = de_top_ids(ref_up, TOP_N)
    ref_down_ids = de_top_ids(ref_down, TOP_N)
    oth_up_ids   = de_top_ids(oth_up, TOP_N)
    oth_down_ids = de_top_ids(oth_down, TOP_N)

    missing_up = ref_up_ids - oth_up_ids
    missing_dn = ref_down_ids - oth_down_ids
    new_up     = oth_up_ids - ref_up_ids
    new_dn     = oth_down_ids - ref_down_ids

    details = {
      missing_up:   missing_up.map { |e| { ensembl: e, pos_in_other: de_position_in_ranked(e, oth_up_ranked) } },
      missing_down: missing_dn.map { |e| { ensembl: e, pos_in_other: de_position_in_ranked(e, oth_down_ranked) } },
      new_up:       new_up.map { |e| { ensembl: e, pos_in_ref: de_position_in_ranked(e, ref_up_ranked) } },
      new_down:     new_dn.map { |e| { ensembl: e, pos_in_ref: de_position_in_ranked(e, ref_down_ranked) } },
    }

    {
      n_missing_up:   missing_up.size,
      n_missing_down: missing_dn.size,
      n_new_up:       new_up.size,
      n_new_down:     new_dn.size,
      details:        details,
    }
  end

  def run_two_group_ontology_benchmark
    base_dir = "/data/asap2_test/tests/de/bench_two_group_onto"
    FileUtils.mkdir_p(base_dir)

    results = []

    BENCH_METHODS.each do |method|
      TWO_GROUP_ONTO_PREVIEW_CONFIGS.each do |cfg_label, preview_args|
        tag     = "#{method}_#{cfg_label.gsub(/[^a-zA-Z0-9]+/, '_')}"
        out_dir = File.join(base_dir, tag)
        label   = "#{method} | #{cfg_label}"

        g1 = Shellwords.escape(BENCH_ONTO_G1)
        g2 = Shellwords.escape(BENCH_ONTO_G2)

        extra = [
          "--group-dataset #{BENCH_ONTO_DS}",
          "--group #{g1}",
          "--group-2 #{g2}",
          "-o #{out_dir}",
          "--write-tsv",
        ].join(" ")

        t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ok, _output = de_run(label, extra, out_dir,
                             method_override: method,
                             preview_override: preview_args)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start

        tsv_path = File.join(out_dir, "output.tsv")
        unless ok && File.exist?(tsv_path)
          results << {
            method: method, config: cfg_label, ok: false,
            is_reference: (method == REF_METHOD && preview_args.empty?),
            elapsed:        elapsed,
          }
          next
        end

        rows = de_parse_tsv_rows(tsv_path)

        is_ref = (method == REF_METHOD && preview_args.empty?)
        results << {
          method:       method,
          config:       cfg_label,
          ok:           true,
          elapsed:      elapsed,
          rows:         rows,
          is_reference: is_ref,
        }
      end
    end

    ref = results.find { |r| r[:is_reference] && r[:ok] }
    unless ref
      puts "ERROR: Reference run (#{REF_METHOD}, no-preview) failed or missing."
      return nil
    end

    failed = []
    results.each { |r| failed << r unless r[:ok] }

    ref_rows = ref[:rows]

    comparisons_by_mode = {}
    ONTOLOGY_RANK_MODES.each { |mode_key, _, _| comparisons_by_mode[mode_key] = [] }

    ONTOLOGY_RANK_MODES.each do |mode_key, _, _|
      ref_up, ref_down = de_rank_pairs(ref_rows, mode_key)
      results.each do |r|
        next unless r[:ok]
        next if r[:is_reference]

        o_up, o_down = de_rank_pairs(r[:rows], mode_key)
        cmp = de_compare_top_to_reference(
          ref_up, ref_down,
          o_up, o_down,
          o_up, o_down,
          ref_up, ref_down,
        )
        comparisons_by_mode[mode_key] << {
          method:  r[:method],
          config:  r[:config],
          elapsed: r[:elapsed],
          mode:    mode_key,
          **cmp,
        }
      end
    end

    { ref: ref, comparisons_by_mode: comparisons_by_mode, failed: failed }
  end

  def print_two_group_run_details(c, mode_key)
    hints = de_rank_position_hint(mode_key)
    d     = c[:details]

    time_s = c[:elapsed] ? format("%.2fs", c[:elapsed]) : "n/a"
    puts ""
    puts "--- #{c[:method]} | #{c[:config]} (#{time_s}) ---"

    if d[:missing_up].empty? && d[:missing_down].empty? && d[:new_up].empty? && d[:new_down].empty?
      puts "  (Top-#{TOP_N} sets identical to reference for both directions)"
      return
    end

    unless d[:missing_up].empty?
      puts "  Reference top-#{TOP_N} UP missing from this run's top-#{TOP_N} UP (1-based position in this run's #{hints[:up]}; blank if not in that list):"
      d[:missing_up].each do |x|
        pos = x[:pos_in_other] ? "##{x[:pos_in_other]}" : "(not in list)"
        puts "    #{x[:ensembl]}  #{pos}"
      end
    end

    unless d[:missing_down].empty?
      puts "  Reference top-#{TOP_N} DOWN missing from this run's top-#{TOP_N} DOWN (#{hints[:down]}):"
      d[:missing_down].each do |x|
        pos = x[:pos_in_other] ? "##{x[:pos_in_other]}" : "(not in list)"
        puts "    #{x[:ensembl]}  #{pos}"
      end
    end

    unless d[:new_up].empty?
      puts "  New in this run's top-#{TOP_N} UP (1-based position in reference #{hints[:up]}):"
      d[:new_up].each do |x|
        pos = x[:pos_in_ref] ? "##{x[:pos_in_ref]}" : "(not in list)"
        puts "    #{x[:ensembl]}  #{pos}"
      end
    end

    unless d[:new_down].empty?
      puts "  New in this run's top-#{TOP_N} DOWN (#{hints[:down]}):"
      d[:new_down].each do |x|
        pos = x[:pos_in_ref] ? "##{x[:pos_in_ref]}" : "(not in list)"
        puts "    #{x[:ensembl]}  #{pos}"
      end
    end
  end

  def print_two_group_ontology_report(data)
    puts ""
    puts "=" * 120
    puts "Two-group DE benchmark: ontology column"
    puts "  Groups: #{BENCH_ONTO_G1} vs #{BENCH_ONTO_G2}"
    puts "  Column: #{BENCH_ONTO_DS}"
    puts "  Reference: #{REF_METHOD}, no-preview (same loom and DE parameters for all runs)"
    if data[:ref][:elapsed]
      puts "  Reference wall time: %.2fs" % data[:ref][:elapsed]
    end
    puts "  Three tables below use the same Miss/New counts pattern; top-#{TOP_N} up/down genes are chosen by three different sort orders."
    puts "=" * 120

    if (data[:failed] || []).any?
      puts ""
      puts "WARNING: #{data[:failed].size} run(s) failed (no output.tsv):"
      data[:failed].each do |f|
        t = f[:elapsed] ? format(" %.2fs", f[:elapsed]) : ""
        puts "  - #{f[:method]} | #{f[:config]}#{t}"
      end
    end

    hdr = "%-22s  %-26s  %10s  %4s  %4s  %4s  %4s" % ["Method", "Preview", "Time (s)", "MissU", "MissD", "NewU", "NewD"]

    ONTOLOGY_RANK_MODES.each do |mode_key, table_title, table_desc|
      comparisons = data[:comparisons_by_mode][mode_key] || []

      puts ""
      puts "=" * 120
      puts table_title
      puts table_desc
      puts "-" * 120
      puts hdr
      puts "-" * hdr.size

      ref_el = data[:ref][:elapsed]
      ref_line = "%-22s  %-26s  %10s  %4s  %4s  %4s  %4s" % [
        REF_METHOD, "no-preview (reference)", ref_el ? format("%.2f", ref_el) : "n/a", "-", "-", "-", "-",
      ]
      puts ref_line

      comparisons.each do |c|
        t = c[:elapsed] ? format("%.2f", c[:elapsed]) : "n/a"
        puts "%-22s  %-26s  %10s  %4d  %4d  %4d  %4d" % [
          c[:method], c[:config], t, c[:n_missing_up], c[:n_missing_down], c[:n_new_up], c[:n_new_down],
        ]
      end

      puts "-" * hdr.size

      comparisons.each do |c|
        print_two_group_run_details(c, mode_key)
      end
    end

    puts ""
    puts "=" * 120
  end

  desc "Benchmark two-group DE on ontology term column; compare top genes to t_test no-preview"
  task benchmark_two_group_ontology: :environment do
    puts "DE v8: two-group ontology benchmark"
    puts "Loom: #{LOOM_FILE}"
    puts "Container: #{CONTAINER}"
    puts ""

    unless File.exist?(LOOM_FILE)
      puts "ERROR: Loom file not found: #{LOOM_FILE}"
      exit 1
    end

    running = `docker inspect -f '{{.State.Running}}' #{CONTAINER} 2>&1`.strip
    unless running == "true"
      puts "ERROR: Container '#{CONTAINER}' is not running."
      exit 1
    end

    data = run_two_group_ontology_benchmark
    exit 1 if data.nil?

    print_two_group_ontology_report(data)
    exit 0
  end
end
