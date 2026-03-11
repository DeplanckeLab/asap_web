#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "time"

DEFAULT_MODELS = %w[
  DockerImage
  Version
  Step
  StdMethod
  Status
  FileFormat
  ProjectType
  IdentifierType
  ToolType
  Tool
  DataType
  OutputAttr
].freeze

DEFAULT_IGNORED_COLUMNS = %w[created_at updated_at].freeze
JSON_LIKE_COLUMN_SUFFIX = "_json"
JSON_LIKE_COLUMN_NAMES = %w[tools_json docker_json env_json].freeze

class CompareReferenceData
  def initialize
    @options = {
      models: DEFAULT_MODELS.dup,
      include_timestamps: false,
      pretty: true
    }
  end

  def run(argv)
    command = argv.shift
    case command
    when "export"
      parse_export_options(argv)
      load_rails_environment!
      export_snapshot!
    when "compare"
      parse_compare_options(argv)
      compare_snapshots!
    else
      abort <<~MSG
        Usage:
          ruby bin/compare_reference_data.rb export --label dev --out /tmp/asap-dev.json
          ruby bin/compare_reference_data.rb export --label prod --out /tmp/asap-prod.json
          ruby bin/compare_reference_data.rb compare --left /tmp/asap-dev.json --right /tmp/asap-prod.json

        Optional:
          --models Step,StdMethod,DockerImage,Version
          --include-timestamps
      MSG
    end
  end

  private

  def parse_export_options(argv)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: export --label LABEL --out PATH [options]"
      opts.on("--label LABEL", "Environment label (dev/prod)") { |v| @options[:label] = v }
      opts.on("--out PATH", "Output snapshot JSON path") { |v| @options[:out] = v }
      opts.on("--models LIST", "Comma-separated model names") do |v|
        @options[:models] = parse_models(v)
      end
      opts.on("--include-timestamps", "Include created_at/updated_at columns") do
        @options[:include_timestamps] = true
      end
      opts.on("--[no-]pretty", "Pretty JSON output (default: true)") { |v| @options[:pretty] = v }
    end

    parser.parse!(argv)

    abort "Missing --label" if blank?(@options[:label])
    abort "Missing --out" if blank?(@options[:out])
  end

  def parse_compare_options(argv)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: compare --left PATH --right PATH [options]"
      opts.on("--left PATH", "Left snapshot JSON path") { |v| @options[:left] = v }
      opts.on("--right PATH", "Right snapshot JSON path") { |v| @options[:right] = v }
      opts.on("--out PATH", "Optional JSON report output path") { |v| @options[:out] = v }
      opts.on("--models LIST", "Comma-separated model names to compare") do |v|
        @options[:models] = parse_models(v)
      end
    end

    parser.parse!(argv)

    abort "Missing --left" if blank?(@options[:left])
    abort "Missing --right" if blank?(@options[:right])
  end

  def parse_models(value)
    models = value.to_s.split(",").map(&:strip).reject(&:empty?)
    abort "--models cannot be empty" if models.empty?
    models
  end

  def load_rails_environment!
    require_relative "../config/environment"
  end

  def export_snapshot!
    snapshot = {
      metadata: {
        label: @options[:label],
        rails_env: ENV["RAILS_ENV"] || "development",
        generated_at: Time.now.utc.iso8601,
        models: @options[:models],
        include_timestamps: @options[:include_timestamps]
      },
      records: {}
    }

    @options[:models].each do |model_name|
      model = resolve_model!(model_name)
      snapshot[:records][model_name] = export_model(model)
    end

    payload = @options[:pretty] ? JSON.pretty_generate(snapshot) : JSON.generate(snapshot)
    File.write(@options[:out], payload)
    puts "Snapshot written to #{@options[:out]}"
    puts "Models: #{@options[:models].join(', ')}"
  end

  def export_model(model)
    ignored_columns = @options[:include_timestamps] ? [] : DEFAULT_IGNORED_COLUMNS
    columns = model.column_names - ignored_columns
    pk = model.primary_key
    abort "Model #{model.name} has no primary key" if blank?(pk)

    model.order(pk.to_sym).map do |record|
      normalized = {}
      columns.each do |column|
        normalized[column] = normalize_value(column, record.public_send(column))
      end
      normalized
    end
  end

  def normalize_value(column, value)
    return value unless json_like_column?(column)
    return value if value.nil?
    return deep_sort(value) if value.is_a?(Hash) || value.is_a?(Array)
    return value unless value.is_a?(String)

    parsed = JSON.parse(value)
    deep_sort(parsed)
  rescue JSON::ParserError => e
    {
      "__invalid_json__" => true,
      "parse_error" => e.message,
      "raw" => value
    }
  end

  def json_like_column?(column)
    column.end_with?(JSON_LIKE_COLUMN_SUFFIX) || JSON_LIKE_COLUMN_NAMES.include?(column)
  end

  def deep_sort(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) do |key, out|
        out[key] = deep_sort(value[key])
      end
    when Array
      value.map { |entry| deep_sort(entry) }
    else
      value
    end
  end

  def resolve_model!(name)
    Object.const_get(name)
  rescue NameError
    abort "Unknown model: #{name}"
  end

  def compare_snapshots!
    left = load_snapshot!(@options[:left])
    right = load_snapshot!(@options[:right])

    report = {
      metadata: {
        left: left.dig("metadata", "label") || @options[:left],
        right: right.dig("metadata", "label") || @options[:right],
        compared_at: Time.now.utc.iso8601,
        models: @options[:models]
      },
      differences: {}
    }

    @options[:models].each do |model_name|
      left_records = fetch_model_records(left, model_name)
      right_records = fetch_model_records(right, model_name)
      report[:differences][model_name] = compare_model_records(left_records, right_records)
    end

    print_human_report(report)
    if @options[:out]
      File.write(@options[:out], JSON.pretty_generate(report))
      puts "\nJSON diff report written to #{@options[:out]}"
    end
  end

  def load_snapshot!(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT
    abort "File not found: #{path}"
  rescue JSON::ParserError => e
    abort "Invalid JSON in #{path}: #{e.message}"
  end

  def fetch_model_records(snapshot, model_name)
    records = snapshot.dig("records", model_name)
    abort "Snapshot missing records for model #{model_name}" if records.nil?
    abort "Snapshot records for #{model_name} must be an array" unless records.is_a?(Array)
    records
  end

  def compare_model_records(left_records, right_records)
    left_by_id = index_by_id!(left_records, "left")
    right_by_id = index_by_id!(right_records, "right")

    left_ids = left_by_id.keys
    right_ids = right_by_id.keys

    only_in_left = left_ids - right_ids
    only_in_right = right_ids - left_ids
    shared_ids = left_ids & right_ids

    changed = shared_ids.each_with_object({}) do |id, out|
      diffs = diff_hash(left_by_id[id], right_by_id[id])
      out[id] = diffs unless diffs.empty?
    end

    {
      only_in_left_ids: only_in_left,
      only_in_right_ids: only_in_right,
      changed_count: changed.size,
      changed: changed
    }
  end

  def index_by_id!(records, side)
    indexed = {}
    records.each do |record|
      abort "Record in #{side} snapshot is not a hash: #{record.inspect}" unless record.is_a?(Hash)
      id = record["id"]
      abort "Record in #{side} snapshot has nil id: #{record.inspect}" if id.nil?
      abort "Duplicate id=#{id} in #{side} snapshot" if indexed.key?(id)
      indexed[id] = record
    end
    indexed
  end

  def diff_hash(left_hash, right_hash)
    keys = (left_hash.keys + right_hash.keys).uniq.sort
    keys.each_with_object({}) do |key, out|
      lv = left_hash[key]
      rv = right_hash[key]
      next if lv == rv
      out[key] = { left: lv, right: rv }
    end
  end

  def print_human_report(report)
    left_label = report.dig(:metadata, :left)
    right_label = report.dig(:metadata, :right)

    puts "Comparing snapshots: #{left_label} vs #{right_label}"
    puts "-" * 72

    report[:differences].each do |model_name, payload|
      only_left = payload[:only_in_left_ids]
      only_right = payload[:only_in_right_ids]
      changed_count = payload[:changed_count]

      has_diffs = only_left.any? || only_right.any? || changed_count.positive?
      status = has_diffs ? "DIFF" : "OK"

      puts "#{model_name}: #{status}"
      puts "  only in left: #{only_left.size}#{only_left.any? ? " (#{only_left.join(', ')})" : ''}"
      puts "  only in right: #{only_right.size}#{only_right.any? ? " (#{only_right.join(', ')})" : ''}"
      puts "  changed ids: #{changed_count}"

      if changed_count.positive?
        payload[:changed].keys.sort.each do |id|
          fields = payload[:changed][id].keys.sort
          puts "    id=#{id} changed fields: #{fields.join(', ')}"
        end
      end
    end
  end

  def blank?(value)
    value.nil? || value.to_s.strip.empty?
  end
end

CompareReferenceData.new.run(ARGV)
