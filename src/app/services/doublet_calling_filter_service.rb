# frozen_string_literal: true

require "open3"
require "json"

# Runs asap_run doublet.calling.v8.py against an existing doublet score in a LOOM file.
class DoubletCallingFilterService
  CONTAINER = ENV.fetch("ASAP_RUN_CONTAINER")
  SCRIPT = "/srv/doublet.calling.v8.py"

  class FilterError < StandardError; end

  def self.run!(loom_path:, input_score_meta:, output_call_meta:, method:, output_dir: nil,
                threshold: nil, n_doublets: nil, doublet_rate: nil)
    loom_path = loom_path.to_s
    raise FilterError, "LOOM file not found: #{loom_path}" unless File.file?(loom_path)

    cmd = [
      "docker", "exec", CONTAINER,
      "python", "-u", SCRIPT,
      "-f", loom_path,
      "--input_score_meta", input_score_meta.to_s,
      "--output_call_meta", output_call_meta.to_s,
      "--method", method.to_s
    ]
    cmd += ["-o", output_dir.to_s] if output_dir.present?
    cmd += ["--threshold", threshold.to_s] if threshold.present? && threshold.to_s.strip != ""
    cmd += ["--n_doublets", n_doublets.to_s] if n_doublets.present? && n_doublets.to_s.strip != ""
    cmd += ["--doublet_rate", doublet_rate.to_s] if doublet_rate.present? && doublet_rate.to_s.strip != ""

    stdout, stderr, status = Open3.capture3(*cmd)
    parsed = parse_stdout_json(stdout)
    if parsed.blank? && output_dir.present?
      output_json_path = File.join(output_dir.to_s, "output.json")
      if File.file?(output_json_path)
        parsed = Basic.safe_parse_json(File.read(output_json_path), {})
      end
    end

    unless status.success?
      msg = parsed.is_a?(Hash) && parsed["displayed_error"].present? ? parsed["displayed_error"].to_s : stderr.to_s.strip
      msg = stdout.to_s.strip[0, 500] if msg.blank?
      raise FilterError, "doublet.calling.v8.py failed (exit #{status.exitstatus}): #{msg}"
    end

    parsed
  end

  # Refresh the Annot row for output_call_meta after dynamic calling rewrites the LOOM dataset.
  def self.reload_call_annot!(project, run, ctx, filter_result, logger: Rails.logger)
    call_meta_path = ctx[:output_call_meta].to_s
    loom_rel = ctx[:loom_rel].to_s
    raise FilterError, "Missing output_call_meta path" if call_meta_path.blank?
    raise FilterError, "Missing loom relative path" if loom_rel.blank?

    metadata = call_metadata_from_result(filter_result, call_meta_path)
    discrete_type = DataType.find_by(name: "DISCRETE")
    metadata["output_attr_name"] = "output_call_meta"
    metadata["data_class_names"] = %w[dataset mdata col_mdata discrete_mdata]
    metadata["forced_type_id"] = discrete_type.id if discrete_type

    h_data_types = {}
    DataType.find_each { |dt| h_data_types[dt.name] = dt }
    h_data_classes = {}
    DataClass.find_each { |dc| h_data_classes[dc.name] = dc; h_data_classes[dc.id] = dc }

    annot = Basic.load_annot(run, metadata, loom_rel, h_data_types, h_data_classes, logger, {})
    raise FilterError, "Failed to reload call annotation for #{call_meta_path}" unless annot

    sync_run_output_call_meta!(run, annot, loom_rel, call_meta_path)
    annot
  end

  def self.call_metadata_from_result(filter_result, call_meta_path)
    list = filter_result.is_a?(Hash) ? filter_result["metadata"] : nil
    if list.is_a?(Array)
      found = list.find { |m| m.is_a?(Hash) && m["name"].to_s == call_meta_path }
      return found.dup if found
    end

    { "name" => call_meta_path, "on" => "CELL" }
  end
  private_class_method :call_metadata_from_result

  def self.sync_run_output_call_meta!(run, annot, loom_rel, call_meta_path)
    h_outputs = Basic.safe_parse_json(run.output_json, {})
    block = h_outputs["output_call_meta"]
    return unless block.is_a?(Hash)

    output_key = "#{loom_rel}:#{call_meta_path}"
    target_key = block.key?(output_key) ? output_key : block.keys.find { |k| k.end_with?(":#{call_meta_path}") }
    return unless target_key && block[target_key].is_a?(Hash)

    block[target_key] = Basic.update_h_output_files(block[target_key], annot)
    run.update!(output_json: h_outputs.to_json)
  end
  private_class_method :sync_run_output_call_meta!

  def self.parse_stdout_json(stdout)
    text = stdout.to_s.strip
    return {} if text.blank?

    JSON.parse(text)
  rescue JSON::ParserError
    lines = text.lines.map(&:strip).reject(&:empty?)
    line = lines.reverse.find { |l| l.start_with?("{") }
    raise FilterError, "Invalid JSON from doublet.calling.v8.py: #{text[0, 300]}" unless line

    JSON.parse(line)
  end
  private_class_method :parse_stdout_json

  # Resolve loom path and score/call metadata paths for a completed doublet run.
  def self.context_for_run(project, run, step)
    project_dir = Pathname.new(ENV.fetch("USER_DATA_DIR")) + project.user_id.to_s + project.key
    step_dir = project_dir + step.name.to_s
    output_dir = step.multiple_runs ? (step_dir + run.id.to_s) : step_dir
    output_json_path = output_dir + "output.json"

    h_res = File.file?(output_json_path) ? Basic.safe_parse_json(File.read(output_json_path), {}) : {}

    h_attrs = Basic.safe_parse_json(run.attrs_json, {})
    im = h_attrs["input_matrix"] || h_attrs[:input_matrix]
    raise FilterError, "Run is missing input_matrix in attrs_json" unless im.is_a?(Hash)

    loom_rel = im["output_filename"] || im[:output_filename]
    raise FilterError, "Run input_matrix has no output_filename" if loom_rel.blank?

    loom_path = (project_dir + loom_rel.to_s).to_s
    raise FilterError, "Input LOOM not found: #{loom_path}" unless File.file?(loom_path)

    score_meta, call_meta = resolve_score_and_call_meta_paths(run, step, h_res)

    raise FilterError, "Could not resolve doublet score metadata path" if score_meta.blank?
    raise FilterError, "Could not resolve doublet call metadata path" if call_meta.blank?

    {
      loom_path: loom_path,
      loom_rel: loom_rel.to_s,
      input_score_meta: score_meta,
      output_call_meta: call_meta,
      filter_output_dir: output_dir.to_s,
      h_res: h_res
    }
  end

  def self.resolve_score_and_call_meta_paths(run, step, h_res)
    params = h_res["parameters"].is_a?(Hash) ? h_res["parameters"] : {}

    score_meta = first_present(
      params,
      %w[output_score_loom_path input_score_loom_path score_loom_path score_meta_path]
    )
    call_meta = first_present(
      params,
      %w[output_call_loom_path input_call_loom_path call_loom_path call_meta_path]
    )

    if h_res["metadata"].is_a?(Array)
      score_meta ||= h_res["metadata"].map { |m| m["name"] }.find { |n| n.to_s.include?("_score_") }
      call_meta ||= h_res["metadata"].map { |m| m["name"] }.find { |n| n.to_s.include?("_call_") }
    end

    if h_res["doublet_score"].is_a?(Hash)
      score_meta ||= h_res["doublet_score"]["loom_path"].presence || h_res["doublet_score"]["output_path"].presence
    end
    if h_res["doublet_call"].is_a?(Hash)
      call_meta ||= h_res["doublet_call"]["loom_path"].presence || h_res["doublet_call"]["output_path"].presence
    end

    cmd_paths = meta_paths_from_command_json(run)
    score_meta ||= cmd_paths[:score]
    call_meta ||= cmd_paths[:call]

    score_meta ||= default_meta_path(step, run, "score_df")
    call_meta ||= default_meta_path(step, run, "call_df")

    unless score_meta.present? && call_meta.present?
      annots = Annot.where(run_id: run.id, dim: 1).order(:id).to_a
      score_meta ||= annots.find { |a| a.name.to_s.include?("_score_") }&.name
      call_meta ||= annots.find { |a| a.name.to_s.include?("_call_") }&.name
    end

    [score_meta, call_meta]
  end
  private_class_method :resolve_score_and_call_meta_paths

  def self.first_present(hash, keys)
    keys.each do |key|
      val = hash[key]
      return val if val.present?
    end
    nil
  end
  private_class_method :first_present

  def self.meta_paths_from_command_json(run)
    h_cmd = Basic.safe_parse_json(run.command_json, {})
    score = nil
    call = nil
    (h_cmd["opts"] || []).each do |opt|
      next unless opt.is_a?(Hash)

      case opt["opt"].to_s
      when "--output_score_meta"
        score = opt["value"].presence
      when "--output_call_meta"
        call = opt["value"].presence
      end
    end
    { score: score, call: call }
  end
  private_class_method :meta_paths_from_command_json

  def self.default_meta_path(step, run, suffix)
    std_method = run.std_method || StdMethod.find_by(id: run.std_method_id)
    step_tag = step&.tag
    return nil unless std_method && step_tag.present?

    "/col_attrs/_#{step_tag}_#{std_method.name}_#{suffix}"
  end
  private_class_method :default_meta_path

  # Histogram bins for score distribution plot (max 120 bins).
  def self.score_histogram(scores, bins: 80)
    vals = Array(scores).flatten.map { |v| Float(v) rescue nil }.compact
    return { bins: [], counts: [], min: 0.0, max: 0.0, n: 0 } if vals.empty?

    min_v, max_v = vals.minmax
    return { bins: [min_v], counts: [vals.size], min: min_v, max: max_v, n: vals.size } if min_v == max_v

    n_bins = [[bins.to_i, 10].max, 120].min
    width = (max_v - min_v) / n_bins.to_f
    counts = Array.new(n_bins, 0)
    vals.each do |v|
      idx = ((v - min_v) / width).floor
      idx = n_bins - 1 if idx >= n_bins
      counts[idx] += 1
    end
    centers = (0...n_bins).map { |i| min_v + (i + 0.5) * width }
    { bins: centers, counts: counts, min: min_v, max: max_v, n: vals.size }
  end
end
