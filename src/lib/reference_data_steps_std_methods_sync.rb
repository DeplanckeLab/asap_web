# frozen_string_literal: true

require "json"
require "set"

# Applies Step, StdMethod, and Version rows from a JSON snapshot produced by
# ReferenceDataCompare / bin/rake reference_data:export.
#
# Matching: Step by +name+ for full sync; Step, StdMethod, and Version by +id+ when
# +max_version_id+ is set (legacy prod/dev alignment). StdMethod names must be unique
# per snapshot +step_id+ for full sync only.
# Foreign keys +docker_image_id+, +version_id+, +speed_id+ are remapped for the
# target database using snapshot side tables when ids differ.
# Version rows (env_json, tools_json, docker_json, activated, ...) are applied by id
# when present in the snapshot.
class ReferenceDataStepsStdMethodsSync
  SyncError = Class.new(StandardError)

  JSON_TEXT_COLUMNS = {
    "Step" => %w[
      attrs_json command_json dashboard_card_json method_attrs_json
      output_json show_view_json
    ],
    "StdMethod" => %w[
      attr_layout_json attrs_json command_json obj_attrs_json output_json
    ],
    "Version" => %w[env_json tools_json docker_json]
  }.freeze

  TIMESTAMP_COLUMNS = %w[created_at updated_at activated_at].freeze
  BOOLEAN_COLUMNS = %w[activated beta hidden obsolete].freeze

  def initialize(snapshot_path:, dry_run: false, verbose: false, max_version_id: nil)
    @snapshot_path = snapshot_path
    @dry_run = dry_run
    @verbose = verbose
    @max_version_id = max_version_id
    @snapshot = nil
  end

  def run
    @snapshot = load_snapshot!(@snapshot_path)
    versions_in = filter_legacy_version_ids!(fetch_optional_records!("Version"))
    steps_in = filter_legacy_version!(fetch_records!("Step"))
    methods_in = filter_legacy_version!(fetch_records!("StdMethod"))

    docker_by_src_id = index_optional_model!("DockerImage")
    version_by_src_id = index_optional_model!("Version")
    speed_by_src_id = index_optional_model!("Speed")

    docker_remap = build_docker_image_remap(steps_in + methods_in, docker_by_src_id)
    version_remap = build_version_remap(steps_in + methods_in, version_by_src_id)
    speed_remap = build_speed_remap(methods_in, speed_by_src_id)

    assert_unique_steps!(steps_in)
    assert_unique_std_methods!(methods_in)
    snapshot_step_id_lookup = build_step_id_lookup(steps_in)

    summary = {
      versions_created: 0,
      versions_updated: 0,
      versions_unchanged: 0,
      steps_created: 0,
      steps_updated: 0,
      steps_unchanged: 0,
      std_methods_created: 0,
      std_methods_updated: 0,
      std_methods_unchanged: 0,
      dry_run: @dry_run
    }

    ActiveRecord::Base.transaction(requires_new: true) do
      apply_versions!(versions_in, summary)
      apply_steps!(steps_in, docker_remap, version_remap, summary)
      apply_std_methods!(
        steps_in,
        methods_in,
        snapshot_step_id_lookup,
        docker_remap,
        version_remap,
        speed_remap,
        summary
      )

      raise ActiveRecord::Rollback if @dry_run
    end

    print_summary(summary, versions_in, steps_in)
    summary
  end

  private

  def match_by_version?
    !@max_version_id.nil?
  end

  def match_by_id?
    match_by_version?
  end

  def filter_legacy_version!(rows)
    return rows if @max_version_id.nil?

    rows.select do |row|
      vid = row["version_id"]
      !vid.nil? && vid.to_i < @max_version_id
    end
  end

  def filter_legacy_version_ids!(rows)
    return rows if @max_version_id.nil?

    rows.select { |row| row["id"].to_i < @max_version_id }
  end

  def load_snapshot!(path)
    raw = File.read(path)
    JSON.parse(raw)
  rescue Errno::ENOENT
    raise SyncError, "Snapshot file not found: #{path}"
  rescue JSON::ParserError => e
    raise SyncError, "Invalid JSON in #{path}: #{e.message}"
  end

  def fetch_records!(model_name)
    list = @snapshot["records"] && @snapshot["records"][model_name]
    raise SyncError, "Snapshot missing records[#{model_name}]" if list.nil?
    raise SyncError, "records[#{model_name}] must be an array" unless list.is_a?(Array)

    list
  end

  def fetch_optional_records!(model_name)
    list = @snapshot["records"] && @snapshot["records"][model_name]
    return [] if list.nil?
    raise SyncError, "records[#{model_name}] must be an array" unless list.is_a?(Array)

    list
  end

  def index_optional_model!(model_name)
    list = @snapshot["records"] && @snapshot["records"][model_name]
    return {} if list.nil?

    raise SyncError, "records[#{model_name}] must be an array" unless list.is_a?(Array)

    list.each_with_object({}) do |row, h|
      id = row["id"]
      raise SyncError, "#{model_name} row without id: #{row.inspect}" if id.nil?

      h[id] = row
    end
  end

  def assert_unique_steps!(steps_in)
    seen = {}
    steps_in.each do |row|
      if match_by_id?
        key = row["id"]
        raise SyncError, "Step row without id: #{row.inspect}" if key.nil?
      else
        key = step_snapshot_key(row)
        n = row["name"].to_s
        raise SyncError, "Step row without name: #{row.inspect}" if n.empty?
      end

      seen[key] = (seen[key] || 0) + 1
    end
    dup = seen.select { |_, c| c > 1 }.keys
    return if dup.empty?

    message =
      if match_by_id?
        "Duplicate step ids in snapshot: #{dup.join(', ')}"
      elsif match_by_version?
        "Duplicate steps in snapshot (same name and version_id): #{format_step_keys(dup)}"
      else
        "Duplicate step names in snapshot (cannot sync): #{dup.map(&:first).join(', ')}"
      end
    raise SyncError, message
  end

  def assert_unique_std_methods!(methods_in)
    seen = {}
    methods_in.each do |row|
      if match_by_id?
        key = row["id"]
        raise SyncError, "StdMethod row without id: #{row.inspect}" if key.nil?
      else
        sid = row["step_id"]
        n = row["name"].to_s
        raise SyncError, "StdMethod row without name (step_id=#{sid}): #{row.inspect}" if n.empty?
        raise SyncError, "StdMethod row without step_id: #{row.inspect}" if sid.nil?

        key = [sid, n]
      end
      seen[key] = (seen[key] || 0) + 1
    end
    dup = seen.select { |_, c| c > 1 }.keys
    return if dup.empty?

    message =
      if match_by_id?
        "Duplicate std_method ids in snapshot: #{dup.join(', ')}"
      else
        "Duplicate std_methods in snapshot (same step_id and name): #{dup.map { |sid, n| "step_id=#{sid} name=#{n.inspect}" }.join(', ')}"
      end
    raise SyncError, message
  end

  def step_snapshot_key(row)
    name = row["name"].to_s
    return name unless match_by_version?

    vid = row["version_id"]
    raise SyncError, "Step #{name.inspect} missing version_id (required for legacy sync)" if vid.nil?

    [name, vid]
  end

  def format_step_keys(keys)
    keys.map do |key|
      match_by_version? ? "name=#{key[0].inspect} version_id=#{key[1]}" : key.inspect
    end.join(", ")
  end

  def build_step_id_lookup(steps_in)
    steps_in.each_with_object({}) do |row, h|
      h[row["id"]] = { "name" => row["name"].to_s, "version_id" => row["version_id"] }
    end
  end

  def snapshot_step_keys_set(steps_in, version_remap)
    steps_in.map do |row|
      vid = row["version_id"]
      mapped_vid = version_remap[vid] || vid
      match_by_version? ? [row["name"].to_s, mapped_vid] : row["name"].to_s
    end.to_set
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
        raise SyncError,
              "docker_image_id #{src_id} referenced but DockerImage id #{src_id} is missing from snapshot. " \
              "Export with MODELS=Step,StdMethod,DockerImage,Version,Speed (include DockerImage)."
      end

      dst = DockerImage.find_by(name: src["name"].to_s, tag: src["tag"].to_s)
      unless dst
        raise SyncError,
              "No target DockerImage for snapshot id #{src_id} name=#{src['name'].inspect} tag=#{src['tag'].inspect}"
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
      raise SyncError,
            "version_id #{source_id} is not present on target and snapshot has no Version row for it. " \
            "Export with MODELS=...,Version or align Version primary keys."
    end

    by_desc = Version.where(description: src["description"]).load
    return by_desc.first.id if by_desc.one?

    by_rel = Version.where(release_date: src["release_date"], beta: src["beta"]).load
    return by_rel.first.id if by_rel.one?

    raise SyncError,
          "Cannot map snapshot version id #{source_id} to target (description and release_date+beta not unique)"
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
      raise SyncError,
            "speed_id #{source_id} is not present on target and snapshot has no Speed row for it. " \
            "Export with MODELS=...,Speed or align Speed primary keys."
    end

    dst = Speed.find_by(name: src["name"].to_s)
    raise SyncError, "No target Speed named #{src['name'].inspect} for snapshot speed id #{source_id}" unless dst

    dst.id
  end

  def remap_fk(value, table)
    return nil if value.nil?

    mapped = table[value]
    raise SyncError, "Internal error: missing remap for fk value #{value}" if mapped.nil?

    mapped
  end

  def prepare_row_for_model(model_class, row, fk_maps)
    attrs = row.except("id")
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

  def prepare_version_row(row)
    attrs = row.except("id")
    encode_json_columns!("Version", attrs)
    attrs
  end

  def apply_versions!(versions_in, summary)
    return if versions_in.empty?

    versions_in.sort_by { |row| row["id"].to_i }.each do |src|
      src_id = src["id"]
      raise SyncError, "Version row without id: #{src.inspect}" if src_id.nil?

      prepared = prepare_version_row(src)
      record = Version.find_by(id: src_id)

      if record.nil?
        puts "[#{mode_label}] create Version id=#{src_id}"
        summary[:versions_created] += 1
        next if @dry_run

        Version.create!(prepared.merge("id" => src_id))
        next
      end

      if record_attributes_match?(record, prepared)
        summary[:versions_unchanged] += 1
        next
      end

      puts "[#{mode_label}] update Version id=#{src_id}"
      log_verbose_diff!(record, prepared)
      summary[:versions_updated] += 1
      next if @dry_run

      record.update!(prepared)
    end
  end

  def encode_json_columns!(model_name, attrs)
    (JSON_TEXT_COLUMNS[model_name] || []).each do |col|
      next unless attrs.key?(col)

      v = attrs[col]
      next if v.nil?
      next if v.is_a?(String)

      attrs[col] = JSON.generate(v)
    end
  end

  def apply_steps!(steps_in, docker_remap, version_remap, summary)
    fk = { docker: docker_remap, version: version_remap }
    sort_steps = match_by_id? ? ->(r) { r["id"].to_i } : ->(r) { [r["version_id"].to_i, r["rank"].to_i, r["name"].to_s] }
    steps_in.sort_by(&sort_steps).each do |src|
      if match_by_id?
        apply_step_by_id!(src, fk, summary)
      else
        apply_step_by_name!(src, fk, summary)
      end
    end
  end

  def apply_step_by_id!(src, fk, summary)
    src_id = src["id"]
    raise SyncError, "Step row without id: #{src.inspect}" if src_id.nil?

    prepared = prepare_row_for_model(Step, src, fk)
    step_label = step_log_label(src_id, prepared["name"], prepared["version_id"])
    record = Step.find_by(id: src_id)

    if record.nil?
      puts "[#{mode_label}] create Step #{step_label}"
      summary[:steps_created] += 1
      return if @dry_run

      Step.create!(prepared.merge("id" => src_id))
      return
    end

    if record_attributes_match?(record, prepared)
      summary[:steps_unchanged] += 1
      return
    end

    puts "[#{mode_label}] update Step #{step_label}"
    log_verbose_diff!(record, prepared)
    summary[:steps_updated] += 1
    return if @dry_run

    record.update!(prepared)
  end

  def apply_step_by_name!(src, fk, summary)
    name = src["name"].to_s
    prepared = prepare_row_for_model(Step, src, fk)
    existing = find_target_steps(name, prepared["version_id"])
    step_label = step_log_label(nil, name, prepared["version_id"])

    if existing.size > 1
      raise SyncError, "Multiple target Step rows for #{step_label}; resolve manually before sync"
    end

    if existing.empty?
      puts "[#{mode_label}] create Step #{step_label}"
      summary[:steps_created] += 1
      return if @dry_run

      Step.create!(prepared)
      return
    end

    record = existing.first
    if record_attributes_match?(record, prepared)
      summary[:steps_unchanged] += 1
      return
    end

    puts "[#{mode_label}] update Step id=#{record.id} #{step_label}"
    log_verbose_diff!(record, prepared)
    summary[:steps_updated] += 1
    return if @dry_run

    record.update!(prepared)
  end

  def apply_std_methods!(steps_in, methods_in, snapshot_step_id_lookup, docker_remap, version_remap, speed_remap, summary)
    fk = { docker: docker_remap, version: version_remap, speed: speed_remap }
    snapshot_step_ids = steps_in.map { |row| row["id"].to_i }.to_set
    sort_methods =
      if match_by_id?
        ->(r) { r["id"].to_i }
      else
        lambda do |r|
          info = snapshot_step_id_lookup[r["step_id"]] || {}
          [info["name"].to_s, info["version_id"].to_i, r["name"].to_s]
        end
      end
    methods_in.sort_by(&sort_methods).each do |src|
      if match_by_id?
        apply_std_method_by_id!(src, fk, summary, snapshot_step_ids: snapshot_step_ids)
      else
        apply_std_method_by_name!(src, snapshot_step_id_lookup, steps_in, version_remap, fk, summary)
      end
    end
  end

  def apply_std_method_by_id!(src, fk, summary, snapshot_step_ids:)
    src_id = src["id"]
    step_src_id = src["step_id"]
    raise SyncError, "StdMethod row without id: #{src.inspect}" if src_id.nil?
    raise SyncError, "StdMethod id=#{src_id} row without step_id: #{src.inspect}" if step_src_id.nil?

    prepared = prepare_row_for_model(StdMethod, src, fk)
    prepared["step_id"] = step_src_id
    method_label = std_method_log_label(src_id, step_src_id, prepared["name"], prepared["version_id"])
    pending_new_step = !Step.exists?(id: step_src_id) && snapshot_step_ids.include?(step_src_id.to_i)

    if pending_new_step && @dry_run
      record = StdMethod.find_by(id: src_id)
      if record.nil?
        puts "[#{mode_label}] create StdMethod #{method_label} (after new Step in same run)"
        summary[:std_methods_created] += 1
      elsif record_attributes_match?(record, prepared)
        summary[:std_methods_unchanged] += 1
      else
        puts "[#{mode_label}] update StdMethod #{method_label} (after new Step in same run)"
        log_verbose_diff!(record, prepared)
        summary[:std_methods_updated] += 1
      end
      return
    end

    unless Step.exists?(id: step_src_id)
      raise SyncError,
            "StdMethod id=#{src_id} references step_id=#{step_src_id} which is missing on target " \
            "(create the Step first or align primary keys)"
    end

    record = StdMethod.find_by(id: src_id)

    if record.nil?
      puts "[#{mode_label}] create StdMethod #{method_label}"
      summary[:std_methods_created] += 1
      return if @dry_run

      StdMethod.create!(prepared.merge("id" => src_id))
      return
    end

    if record_attributes_match?(record, prepared)
      summary[:std_methods_unchanged] += 1
      return
    end

    puts "[#{mode_label}] update StdMethod #{method_label}"
    log_verbose_diff!(record, prepared)
    summary[:std_methods_updated] += 1
    return if @dry_run

    record.update!(prepared)
  end

  def apply_std_method_by_name!(src, snapshot_step_id_lookup, steps_in, version_remap, fk, summary)
    step_src_id = src["step_id"]
    step_info = snapshot_step_id_lookup[step_src_id]
    if step_info.nil?
      raise SyncError, "StdMethod #{src['name'].inspect} references unknown snapshot step_id #{step_src_id}"
    end

    step_name = step_info["name"]
    target_step = find_target_step(step_name, step_info["version_id"], version_remap)
    step_keys_in_snapshot = snapshot_step_keys_set(steps_in, version_remap)
    step_key = match_by_version? ? [step_name, remap_fk(step_info["version_id"], version_remap)] : step_name
    pending_new_step = target_step.nil? && step_keys_in_snapshot.include?(step_key)
    if target_step.nil? && !pending_new_step
      raise SyncError,
            "StdMethod #{src['name'].inspect} needs Step #{step_log_label(nil, step_name, step_info['version_id'])} on target " \
            "(missing from snapshot and database)"
    end

    if pending_new_step && @dry_run
      mname = src["name"].to_s
      raise SyncError, "StdMethod row without name (step #{step_name})" if mname.empty?

      puts "[#{mode_label}] create StdMethod #{std_method_log_label(nil, nil, mname, step_info['version_id'], step_name: step_name)} " \
           "(after new Step in same run)"
      summary[:std_methods_created] += 1
      return
    end

    mname = src["name"].to_s
    raise SyncError, "StdMethod row without name (step #{step_name})" if mname.empty?

    prepared = prepare_row_for_model(StdMethod, src, fk)
    prepared["step_id"] = target_step.id

    existing = StdMethod.where(step_id: target_step.id, name: mname).order(:id).to_a
    if existing.size > 1
      raise SyncError,
            "Multiple StdMethod rows for step_id=#{target_step.id} (#{step_log_label(nil, step_name, target_step.version_id)}) " \
            "name=#{mname.inspect}"
    end

    method_label = std_method_log_label(nil, target_step.id, mname, target_step.version_id, step_name: step_name)

    if existing.empty?
      puts "[#{mode_label}] create StdMethod #{method_label}"
      summary[:std_methods_created] += 1
      return if @dry_run

      StdMethod.create!(prepared)
      return
    end

    record = existing.first
    if record_attributes_match?(record, prepared)
      summary[:std_methods_unchanged] += 1
      return
    end

    puts "[#{mode_label}] update StdMethod id=#{record.id} #{method_label}"
    log_verbose_diff!(record, prepared)
    summary[:std_methods_updated] += 1
    return if @dry_run

    record.update!(prepared)
  end

  def find_target_steps(name, version_id)
    if match_by_version?
      Step.where(name: name, version_id: version_id).order(:id).to_a
    else
      Step.where(name: name).order(:id).to_a
    end
  end

  def find_target_step(name, source_version_id, version_remap)
    if match_by_version?
      target_version_id = remap_fk(source_version_id, version_remap)
      Step.find_by(name: name, version_id: target_version_id)
    else
      Step.find_by(name: name)
    end
  end

  def step_log_label(id, name, version_id)
    if match_by_id?
      "id=#{id} name=#{name.inspect} version_id=#{version_id}"
    elsif match_by_version?
      "name=#{name.inspect} version_id=#{version_id}"
    else
      "name=#{name.inspect}"
    end
  end

  def std_method_log_label(id, step_id, method_name, version_id, step_name: nil)
    if match_by_id?
      "id=#{id} step_id=#{step_id} name=#{method_name.inspect} version_id=#{version_id}"
    elsif match_by_version?
      "step=#{step_name.inspect} version_id=#{version_id} name=#{method_name.inspect}"
    else
      "step=#{step_name.inspect} name=#{method_name.inspect}"
    end
  end

  def record_attributes_match?(record, prepared)
    prepared.all? do |column, value|
      comparable_column_value(record, column) == comparable_value(column, value)
    end
  end

  def comparable_column_value(record, column)
    comparable_value(column, record.public_send(column))
  end

  def comparable_value(column, value)
    return ActiveModel::Type::Boolean.new.cast(value) if BOOLEAN_COLUMNS.include?(column)
    return timestamp_epoch_seconds(value) if TIMESTAMP_COLUMNS.include?(column)

    v = value
    if json_text_column?(column)
      return nil if v.nil?

      str = v.is_a?(String) ? v : JSON.generate(v)
      normalize_json_string(str)
    end
    v
  end

  # Snapshot JSON stores timestamps as strings without subseconds; compare at second resolution.
  def timestamp_epoch_seconds(value)
    return nil if value.nil?

    time =
      case value
      when ActiveSupport::TimeWithZone, Time
        value
      when String
        Time.zone.parse(value)
      else
        nil
      end
    return nil if time.nil?

    time.utc.to_i
  end

  def json_text_column?(column)
    JSON_TEXT_COLUMNS.values.flatten.include?(column)
  end

  def normalize_json_string(str)
    parsed = JSON.parse(str)
    ReferenceDataStepsStdMethodsSync.deep_sort(parsed)
  rescue JSON::ParserError
    str
  end

  def self.deep_sort(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) { |k, out| out[k] = deep_sort(value[k]) }
    when Array
      value.map { |e| deep_sort(e) }
    else
      value
    end
  end

  def log_verbose_diff!(record, prepared)
    return unless @verbose

    prepared.each do |column, new_val|
      old_comp = comparable_column_value(record, column)
      new_comp = comparable_value(column, new_val)
      next if old_comp == new_comp

      puts "    #{column}: was #{old_comp.inspect} -> #{new_comp.inspect}"
    end
  end

  def mode_label
    @dry_run ? "dry-run" : "apply"
  end

  def print_summary(summary, versions_in, steps_in)
    puts ""
    puts "Summary (#{mode_label})"
    if versions_in.any?
      puts "  versions: created=#{summary[:versions_created]} updated=#{summary[:versions_updated]} unchanged=#{summary[:versions_unchanged]}"
      puts "  snapshot versions: #{versions_in.size}"
    end
    puts "  steps: created=#{summary[:steps_created]} updated=#{summary[:steps_updated]} unchanged=#{summary[:steps_unchanged]}"
    puts "  std_methods: created=#{summary[:std_methods_created]} updated=#{summary[:std_methods_updated]} unchanged=#{summary[:std_methods_unchanged]}"
    puts "  snapshot steps: #{steps_in.size}"
    puts "  match key: #{match_by_id? ? 'id' : (match_by_version? ? 'name + version_id' : 'name')}"
    puts "  version filter: id/version_id < #{@max_version_id}" if @max_version_id
    puts "  rolled back (dry-run)" if @dry_run
  end
end
