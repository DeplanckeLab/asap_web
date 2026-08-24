# frozen_string_literal: true

require "json"
require "set"

# Compares Step and StdMethod rows with version_id below a threshold between a source
# (development) dataset and the current Rails database (typically production).
#
# Matching follows ReferenceDataStepsStdMethodsSync with legacy scope: Step and
# StdMethod by primary key +id+.
# Obsolete std_methods are included so obsolete flag drift is visible.
# Hidden steps are included when +include_hidden+ is true.
# Foreign keys are remapped on the source side.
class ReferenceDataStepsStdMethodsCompare
  CompareError = Class.new(StandardError)

  IGNORED_COLUMNS = %w[id created_at updated_at].freeze

  def initialize(
    source_steps:,
    source_std_methods:,
    source_docker_images:,
    source_versions:,
    source_speeds:,
    max_version_id: 8,
    include_hidden: false,
    verbose: false
  )
    @source_steps = source_steps
    @source_std_methods = source_std_methods
    @source_docker_images = source_docker_images
    @source_versions = source_versions
    @source_speeds = source_speeds
    @max_version_id = max_version_id
    @include_hidden = include_hidden
    @verbose = verbose
  end

  def run
    steps_in = filter_legacy_version!(@source_steps)
    steps_in = filter_not_hidden_steps!(steps_in) unless @include_hidden
    methods_in = filter_std_methods_for_steps!(
      filter_legacy_version!(@source_std_methods),
      steps_in
    )

    docker_by_src_id = index_by_id!(@source_docker_images, "DockerImage")
    version_by_src_id = index_by_id!(@source_versions, "Version")
    speed_by_src_id = index_by_id!(@source_speeds, "Speed")

    docker_remap = build_docker_image_remap(steps_in + methods_in, docker_by_src_id)
    version_remap = build_version_remap(steps_in + methods_in, version_by_src_id)
    speed_remap = build_speed_remap(methods_in, speed_by_src_id)

    assert_unique_steps!(steps_in)
    assert_unique_std_methods!(methods_in)
    snapshot_step_id_lookup = build_step_id_lookup(steps_in)

    target_steps = target_steps_scope.order(:id).to_a
    target_std_methods = std_methods_for_steps(target_steps, target_std_methods_scope.order(:id).to_a)

    step_report = compare_steps!(steps_in, target_steps, docker_remap, version_remap)
    std_method_report = compare_std_methods!(
      methods_in,
      target_std_methods,
      snapshot_step_id_lookup,
      docker_remap,
      version_remap,
      speed_remap
    )

    report = {
      max_version_id: @max_version_id,
      version_filter: version_filter_label,
      steps: step_report,
      std_methods: std_method_report,
      has_differences: step_report[:has_differences] || std_method_report[:has_differences]
    }

    print_report(report)
    report
  end

  private

  def filter_legacy_version!(rows)
    rows.select do |row|
      vid = row["version_id"]
      !vid.nil? && vid.to_i < @max_version_id
    end
  end

  def filter_not_hidden_steps!(rows)
    rows.reject { |row| row["hidden"] == true }
  end

  def filter_std_methods_for_steps!(methods_in, steps_in)
    step_ids = steps_in.map { |row| row["id"] }.to_set
    skipped = methods_in.reject { |row| step_ids.include?(row["step_id"]) }
    @skipped_std_methods_without_step = skipped.size
    if skipped.any? && @verbose
      skipped.each do |row|
        puts "Skipping std_method #{row['name'].inspect} step_id=#{row['step_id']} (parent step outside version filter)"
      end
    end
    methods_in.select { |row| step_ids.include?(row["step_id"]) }
  end

  def std_methods_for_steps(steps, std_methods)
    step_ids = steps.map(&:id).to_set
    std_methods.select { |row| step_ids.include?(row.step_id) }
  end

  def version_filter_label
    scope = "version_id < #{@max_version_id}, match by id, obsolete std_methods included"
    @include_hidden ? "#{scope}, hidden steps included" : "#{scope}, hidden steps excluded"
  end

  def target_steps_scope
    if @include_hidden
      Step.where("version_id < ?", @max_version_id)
    else
      active_steps_scope
    end
  end

  def target_std_methods_scope
    StdMethod.where("version_id < ?", @max_version_id)
  end

  def active_steps_scope
    Step.where("version_id < ? AND COALESCE(hidden, false) = ?", @max_version_id, false)
  end

  def active_std_methods_scope
    StdMethod.where("version_id < ? AND COALESCE(obsolete, false) = ?", @max_version_id, false)
  end

  def index_by_id!(rows, label)
    rows.each_with_object({}) do |row, h|
      id = row["id"]
      raise CompareError, "#{label} row without id: #{row.inspect}" if id.nil?

      h[id] = row
    end
  end

  def assert_unique_steps!(steps_in)
    seen = {}
    steps_in.each do |row|
      key = row["id"]
      raise CompareError, "Step row without id: #{row.inspect}" if key.nil?

      seen[key] = (seen[key] || 0) + 1
    end
    dup = seen.select { |_, c| c > 1 }.keys
    return if dup.empty?

    raise CompareError, "Duplicate step ids in source: #{dup.join(', ')}"
  end

  def assert_unique_std_methods!(methods_in)
    seen = {}
    methods_in.each do |row|
      key = row["id"]
      raise CompareError, "StdMethod row without id: #{row.inspect}" if key.nil?

      seen[key] = (seen[key] || 0) + 1
    end
    dup = seen.select { |_, c| c > 1 }.keys
    return if dup.empty?

    raise CompareError, "Duplicate std_method ids in source: #{dup.join(', ')}"
  end

  def build_step_id_lookup(steps_in)
    steps_in.each_with_object({}) do |row, h|
      h[row["id"]] = { "name" => row["name"].to_s, "version_id" => row["version_id"] }
    end
  end

  def collect_docker_image_ids(rows)
    rows.map { |r| r["docker_image_id"] }.compact.uniq
  end

  def collect_version_ids(rows)
    rows.map { |r| r["version_id"] }.compact.uniq
  end

  def collect_speed_ids(rows)
    rows.map { |r| r["speed_id"] }.compact.uniq
  end

  def build_docker_image_remap(all_rows, docker_by_src_id)
    remap = {}
    collect_docker_image_ids(all_rows).each do |src_id|
      src = docker_by_src_id[src_id]
      if src.nil?
        raise CompareError,
              "docker_image_id #{src_id} referenced but missing from source DockerImage rows"
      end

      dst = DockerImage.find_by(name: src["name"].to_s, tag: src["tag"].to_s)
      unless dst
        raise CompareError,
              "No target DockerImage for source id #{src_id} name=#{src['name'].inspect} tag=#{src['tag'].inspect}"
      end

      remap[src_id] = dst.id
    end
    remap
  end

  def build_version_remap(all_rows, version_by_src_id)
    remap = {}
    collect_version_ids(all_rows).each do |src_id|
      remap[src_id] = resolve_version_id!(src_id, version_by_src_id)
    end
    remap
  end

  def resolve_version_id!(source_id, version_by_src_id)
    return source_id if Version.exists?(id: source_id)

    src = version_by_src_id[source_id]
    if src.nil?
      raise CompareError,
            "version_id #{source_id} is not present on target and source has no Version row for it"
    end

    by_desc = Version.where(description: src["description"]).load
    return by_desc.first.id if by_desc.one?

    by_rel = Version.where(release_date: src["release_date"], beta: src["beta"]).load
    return by_rel.first.id if by_rel.one?

    raise CompareError,
          "Cannot map source version id #{source_id} to target (description and release_date+beta not unique)"
  end

  def build_speed_remap(std_methods_in, speed_by_src_id)
    remap = {}
    collect_speed_ids(std_methods_in).each do |src_id|
      remap[src_id] = resolve_speed_id!(src_id, speed_by_src_id)
    end
    remap
  end

  def resolve_speed_id!(source_id, speed_by_src_id)
    return source_id if Speed.exists?(id: source_id)

    src = speed_by_src_id[source_id]
    if src.nil?
      raise CompareError,
            "speed_id #{source_id} is not present on target and source has no Speed row for it"
    end

    dst = Speed.find_by(name: src["name"].to_s)
    raise CompareError, "No target Speed named #{src['name'].inspect} for source speed id #{source_id}" unless dst

    dst.id
  end

  def remap_fk(value, table)
    return nil if value.nil?

    mapped = table[value]
    raise CompareError, "Internal error: missing remap for fk value #{value}" if mapped.nil?

    mapped
  end

  def prepare_row_for_model(model_class, row, fk_maps)
    attrs = row.except(*IGNORED_COLUMNS)
    attrs["docker_image_id"] = remap_fk(attrs["docker_image_id"], fk_maps[:docker]) if fk_maps[:docker]
    if fk_maps[:version] && attrs.key?("version_id")
      attrs["version_id"] = remap_fk(attrs["version_id"], fk_maps[:version])
    end
    if model_class == StdMethod && fk_maps[:speed] && attrs.key?("speed_id") && !attrs["speed_id"].nil?
      attrs["speed_id"] = remap_fk(attrs["speed_id"], fk_maps[:speed])
    end
    encode_json_columns!(model_class.name, attrs)
    attrs
  end

  def encode_json_columns!(model_name, attrs)
    (ReferenceDataStepsStdMethodsSync::JSON_TEXT_COLUMNS[model_name] || []).each do |col|
      next unless attrs.key?(col)

      v = attrs[col]
      next if v.nil?
      next if v.is_a?(String)

      attrs[col] = JSON.generate(v)
    end
  end

  def compare_steps!(steps_in, target_steps, docker_remap, version_remap)
    fk = { docker: docker_remap, version: version_remap }
    source_by_key = {}
    steps_in.each do |src|
      src_id = src["id"]
      raise CompareError, "Source Step row without id: #{src.inspect}" if src_id.nil?

      prepared = prepare_row_for_model(Step, src, fk)
      source_by_key[src_id] = prepared
    end

    target_by_key = {}
    target_steps.each do |record|
      target_by_key[record.id] = target_attributes(record)
    end

    only_in_source = source_by_key.keys - target_by_key.keys
    only_in_target = target_by_key.keys - source_by_key.keys
    changed = {}

    (source_by_key.keys & target_by_key.keys).sort.each do |key|
      diffs = diff_attributes(target_by_key[key], source_by_key[key])
      changed[key] = diffs unless diffs.empty?
    end

    {
      source_count: source_by_key.size,
      target_count: target_by_key.size,
      only_in_source: only_in_source.sort,
      only_in_target: only_in_target.sort,
      changed: changed,
      changed_count: changed.size,
      has_differences: only_in_source.any? || only_in_target.any? || changed.any?
    }
  end

  def compare_std_methods!(methods_in, target_std_methods, _snapshot_step_id_lookup, docker_remap, version_remap, speed_remap)
    fk = { docker: docker_remap, version: version_remap, speed: speed_remap }
    source_by_key = {}

    methods_in.each do |src|
      src_id = src["id"]
      raise CompareError, "Source StdMethod row without id: #{src.inspect}" if src_id.nil?

      prepared = prepare_row_for_model(StdMethod, src, fk)
      prepared["step_id"] = src["step_id"]
      source_by_key[src_id] = prepared
    end

    target_by_key = {}
    target_std_methods.each do |record|
      target_by_key[record.id] = target_attributes(record)
    end

    only_in_source = source_by_key.keys - target_by_key.keys
    only_in_target = target_by_key.keys - source_by_key.keys
    changed = {}

    (source_by_key.keys & target_by_key.keys).sort.each do |key|
      diffs = diff_attributes(target_by_key[key], source_by_key[key])
      changed[key] = diffs unless diffs.empty?
    end

    {
      source_count: source_by_key.size,
      target_count: target_by_key.size,
      only_in_source: only_in_source.sort,
      only_in_target: only_in_target.sort,
      changed: changed,
      changed_count: changed.size,
      has_differences: only_in_source.any? || only_in_target.any? || changed.any?
    }
  end

  def target_attributes(record)
    record.attributes.except(*IGNORED_COLUMNS)
  end

  def diff_attributes(target_attrs, source_attrs)
    keys = (target_attrs.keys + source_attrs.keys).uniq.sort
    keys.each_with_object({}) do |key, out|
      target_val = comparable_value(key, target_attrs[key])
      source_val = comparable_value(key, source_attrs[key])
      next if target_val == source_val

      out[key] = { target: target_val, source: source_val }
    end
  end

  def comparable_value(column, value)
    v = value
    if json_text_column?(column)
      return nil if v.nil?

      str = v.is_a?(String) ? v : JSON.generate(v)
      return normalize_json_string(str)
    end
    v
  end

  def json_text_column?(column)
    ReferenceDataStepsStdMethodsSync::JSON_TEXT_COLUMNS.values.flatten.include?(column)
  end

  def normalize_json_string(str)
    parsed = JSON.parse(str)
    ReferenceDataStepsStdMethodsSync.deep_sort(parsed)
  rescue JSON::ParserError
    str
  end

  def print_report(report)
    puts "Step and StdMethod comparison (#{report[:version_filter]})"
    puts "  source: development (SOURCE_DATABASE_URL or DEV_POSTGRES_DB)"
    puts "  target: #{Rails.env} database"
    if @skipped_std_methods_without_step.to_i.positive?
      puts "  skipped source std_methods (parent step hidden or excluded): #{@skipped_std_methods_without_step}"
    end
    puts "-" * 72

    print_model_report("Step", report[:steps], key_label: "id")
    print_model_report("StdMethod", report[:std_methods], key_label: "id")

    if report[:has_differences]
      puts ""
      puts "Differences found (production may have manual fixes for these legacy versions)."
    else
      puts ""
      puts "No differences for legacy version_id rows."
    end
  end

  def print_model_report(model_name, payload, key_label:)
    only_source = payload[:only_in_source]
    only_target = payload[:only_in_target]
    changed_count = payload[:changed_count]
    status = payload[:has_differences] ? "DIFF" : "OK"

    puts "#{model_name}: #{status}"
    puts "  source rows: #{payload[:source_count]}"
    puts "  target rows: #{payload[:target_count]}"
    puts "  only in source (dev): #{only_source.size}"
    only_source.each { |key| puts "    - #{format_key(key, key_label)}" } if only_source.any?
    puts "  only in target (#{Rails.env}): #{only_target.size}"
    only_target.each { |key| puts "    - #{format_key(key, key_label)}" } if only_target.any?
    puts "  changed (#{key_label}): #{changed_count}"

    return unless changed_count.positive?

    payload[:changed].keys.sort.each do |key|
      field_diffs = payload[:changed][key]
      puts "    #{format_key(key, key_label)}"
      field_diffs.keys.sort.each do |field|
        diff = field_diffs[field]
        puts "      #{field}:"
        puts "        target (#{Rails.env}): #{format_value(diff[:target], truncate: !@verbose)}"
        puts "        source (dev):     #{format_value(diff[:source], truncate: !@verbose)}"
      end
    end
  end

  def format_key(key, key_label)
    case key_label
    when "id"
      "id=#{key}"
    when "name+version"
      "name=#{key[0].inspect} version_id=#{key[1]}"
    when "step+version+name"
      "step=#{key[0].inspect} version_id=#{key[1]} name=#{key[2].inspect}"
    when "step+name"
      "step=#{key[0].inspect} name=#{key[1].inspect}"
    else
      key.inspect
    end
  end

  def format_value(value, truncate: true)
    str =
      case value
      when String
        value
      when NilClass
        "null"
      else
        JSON.generate(value)
      end

    one_line = str.gsub(/\s+/, " ").strip
    return one_line if !truncate || one_line.length <= 220

    "#{one_line[0, 220]}... (truncated, use VERBOSE=1)"
  end
end
