# frozen_string_literal: true

require "json"
require "set"

# Applies Step and StdMethod rows from a JSON snapshot produced by
# ReferenceDataCompare / bin/rake reference_data:export.
#
# Matching: Step by +name+; StdMethod by (+step name+, +std_method name+).
# Foreign keys +docker_image_id+, +version_id+, +speed_id+ are remapped for the
# target database using snapshot side tables when ids differ.
class ReferenceDataStepsStdMethodsSync
  SyncError = Class.new(StandardError)

  JSON_TEXT_COLUMNS = {
    "Step" => %w[
      attrs_json command_json dashboard_card_json method_attrs_json
      output_json show_view_json
    ],
    "StdMethod" => %w[
      attr_layout_json attrs_json command_json obj_attrs_json output_json
    ]
  }.freeze

  def initialize(snapshot_path:, dry_run: false, verbose: false)
    @snapshot_path = snapshot_path
    @dry_run = dry_run
    @verbose = verbose
    @snapshot = nil
  end

  def run
    @snapshot = load_snapshot!(@snapshot_path)
    steps_in = fetch_records!("Step")
    methods_in = fetch_records!("StdMethod")

    docker_by_src_id = index_optional_model!("DockerImage")
    version_by_src_id = index_optional_model!("Version")
    speed_by_src_id = index_optional_model!("Speed")

    docker_remap = build_docker_image_remap(steps_in + methods_in, docker_by_src_id)
    version_remap = build_version_remap(steps_in + methods_in, version_by_src_id)
    speed_remap = build_speed_remap(methods_in, speed_by_src_id)

    snapshot_step_names = assert_unique_step_names!(steps_in)
    snapshot_step_id_to_name = build_step_id_to_name(steps_in)

    summary = {
      steps_created: 0,
      steps_updated: 0,
      steps_unchanged: 0,
      std_methods_created: 0,
      std_methods_updated: 0,
      std_methods_unchanged: 0,
      dry_run: @dry_run
    }

    ActiveRecord::Base.transaction(requires_new: true) do
      apply_steps!(steps_in, docker_remap, version_remap, summary)
      apply_std_methods!(
        steps_in,
        methods_in,
        snapshot_step_id_to_name,
        docker_remap,
        version_remap,
        speed_remap,
        summary
      )

      raise ActiveRecord::Rollback if @dry_run
    end

    print_summary(summary, snapshot_step_names)
    summary
  end

  private

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

  def assert_unique_step_names!(steps_in)
    seen = {}
    steps_in.each do |row|
      n = row["name"].to_s
      raise SyncError, "Step row without name: #{row.inspect}" if n.empty?

      seen[n] = (seen[n] || 0) + 1
    end
    dup = seen.select { |_, c| c > 1 }.keys
    raise SyncError, "Duplicate step names in snapshot (cannot sync): #{dup.join(', ')}" if dup.any?

    seen.keys
  end

  def build_step_id_to_name(steps_in)
    steps_in.each_with_object({}) do |row, h|
      h[row["id"]] = row["name"].to_s
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
        raise SyncError,
              "docker_image_id #{src_id} referenced but DockerImage id #{src_id} is missing from snapshot. " \
              "Export with MODELS=Step,StdMethod,DockerImage,Version,Speed (include DockerImage)."
      end

      dst = DockerImage.find_by(name: src["name"].to_s, tag: src["tag"].to_s)
      unless dst
        raise SyncError,
              "No production DockerImage for snapshot id #{src_id} name=#{src['name'].inspect} tag=#{src['tag'].inspect}"
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
            "version_id #{source_id} is not present on production and snapshot has no Version row for it. " \
            "Export with MODELS=...,Version or align Version primary keys."
    end

    by_desc = Version.where(description: src["description"]).load
    return by_desc.first.id if by_desc.one?

    by_rel = Version.where(release_date: src["release_date"], beta: src["beta"]).load
    return by_rel.first.id if by_rel.one?

    raise SyncError,
          "Cannot map snapshot version id #{source_id} to production (description and release_date+beta not unique)"
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
            "speed_id #{source_id} is not present on production and snapshot has no Speed row for it. " \
            "Export with MODELS=...,Speed or align Speed primary keys."
    end

    dst = Speed.find_by(name: src["name"].to_s)
    raise SyncError, "No production Speed named #{src['name'].inspect} for snapshot speed id #{source_id}" unless dst

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
    steps_in.sort_by { |r| [r["rank"].to_i, r["name"].to_s] }.each do |src|
      name = src["name"].to_s
      prepared = prepare_row_for_model(Step, src, fk)
      existing = Step.where(name: name).order(:id).to_a
      if existing.size > 1
        raise SyncError, "Multiple production Step rows with name #{name.inspect}; resolve manually before sync"
      end

      if existing.empty?
        puts "[#{mode_label}] create Step name=#{name}"
        summary[:steps_created] += 1
        next if @dry_run

        Step.create!(prepared)
      else
        record = existing.first
        if record_attributes_match?(record, prepared)
          summary[:steps_unchanged] += 1
          next
        end

        puts "[#{mode_label}] update Step id=#{record.id} name=#{name}"
        log_verbose_diff!(record, prepared)
        summary[:steps_updated] += 1
        next if @dry_run

        record.update!(prepared)
      end
    end
  end

  def apply_std_methods!(steps_in, methods_in, snapshot_step_id_to_name, docker_remap, version_remap, speed_remap, summary)
    fk = { docker: docker_remap, version: version_remap, speed: speed_remap }
    names_in_snapshot = steps_in.map { |s| s["name"].to_s }.to_set
    methods_in.sort_by { |r| [snapshot_step_id_to_name[r["step_id"]].to_s, r["name"].to_s] }.each do |src|
      step_src_id = src["step_id"]
      step_name = snapshot_step_id_to_name[step_src_id]
      if step_name.blank?
        raise SyncError, "StdMethod #{src['name'].inspect} references unknown snapshot step_id #{step_src_id}"
      end

      prod_step = Step.find_by(name: step_name)
      pending_new_step = prod_step.nil? && names_in_snapshot.include?(step_name)
      if prod_step.nil? && !pending_new_step
        raise SyncError,
              "StdMethod #{src['name'].inspect} needs Step name=#{step_name.inspect} on production (missing from snapshot and database)"
      end

      if pending_new_step && @dry_run
        mname = src["name"].to_s
        raise SyncError, "StdMethod row without name (step #{step_name})" if mname.empty?

        puts "[#{mode_label}] create StdMethod step=#{step_name} name=#{mname} (after new Step #{step_name} in same run)"
        summary[:std_methods_created] += 1
        next
      end

      mname = src["name"].to_s
      raise SyncError, "StdMethod row without name (step #{step_name})" if mname.empty?

      prepared = prepare_row_for_model(StdMethod, src, fk)
      prepared["step_id"] = prod_step.id

      existing = StdMethod.where(step_id: prod_step.id, name: mname).order(:id).to_a
      if existing.size > 1
        raise SyncError, "Multiple StdMethod rows for step=#{step_name} name=#{mname.inspect}"
      end

      if existing.empty?
        puts "[#{mode_label}] create StdMethod step=#{step_name} name=#{mname}"
        summary[:std_methods_created] += 1
        next if @dry_run

        StdMethod.create!(prepared)
      else
        record = existing.first
        if record_attributes_match?(record, prepared)
          summary[:std_methods_unchanged] += 1
          next
        end

        puts "[#{mode_label}] update StdMethod id=#{record.id} step=#{step_name} name=#{mname}"
        log_verbose_diff!(record, prepared)
        summary[:std_methods_updated] += 1
        next if @dry_run

        record.update!(prepared)
      end
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
    v = value
    if json_text_column?(column)
      return nil if v.nil?

      str = v.is_a?(String) ? v : JSON.generate(v)
      normalize_json_string(str)
    end
    v
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

  def print_summary(summary, step_names)
    puts ""
    puts "Summary (#{mode_label})"
    puts "  steps: created=#{summary[:steps_created]} updated=#{summary[:steps_updated]} unchanged=#{summary[:steps_unchanged]}"
    puts "  std_methods: created=#{summary[:std_methods_created]} updated=#{summary[:std_methods_updated]} unchanged=#{summary[:std_methods_unchanged]}"
    puts "  snapshot step names: #{step_names.size}"
    puts "  rolled back (dry-run)" if @dry_run
  end
end
