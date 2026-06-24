# frozen_string_literal: true

require 'yaml'

module Scfair
  # Discovers versioned rules.yaml bundles under config/scfair/<version>/.
  module RulesRegistry
    DEFAULT_SCHEMA_ID = 'scfair_7_1_0'

    Entry = Struct.new(:id, :version, :label, :path, keyword_init: true)

    module_function

    def default_schema_id
      DEFAULT_SCHEMA_ID
    end

    def normalize_schema_id(schema_id)
      (schema_id.presence || DEFAULT_SCHEMA_ID).to_s
    end

    def entries
      @entries ||= discover_entries.freeze
    end

    def entry_for(schema_id)
      id = normalize_schema_id(schema_id)
      entries[id] || raise(ArgumentError, "Unknown scFAIR schema '#{id}'")
    end

    def rules_path_for(schema_id)
      entry_for(schema_id).path
    end

    def rules_relative_path_for(schema_id)
      entry_for(schema_id).path.relative_path_from(Rails.root).to_s
    end

    def available_schemas
      entries.values.sort_by { |e| e.version }.map do |entry|
        bundle = bundle(entry.id)
        {
          id: entry.id,
          label: entry.label,
          version: entry.version,
          schema_version: bundle.schema_version,
          source_url: bundle.schema_hash[:source_url]
        }
      end
    end

    def bundle(schema_id = nil)
      id = normalize_schema_id(schema_id)
      @bundles ||= {}
      @bundles[id] ||= RulesBundle.new(id)
    end

    def reload!
      @entries = nil
      @bundles = nil
      RulesBundle.clear_caches!
    end

    def discover_entries
      pattern = Rails.root.join('config/scfair/*/rules.yaml')
      discovered = {}

      Dir.glob(pattern).each do |path|
        raw = YAML.safe_load_file(path, aliases: true)
        next if raw.blank?

        schema = (raw['schema'] || raw[:schema] || {}).deep_symbolize_keys
        id = schema[:id].to_s
        next if id.blank?

        version = File.basename(File.dirname(path))
        label = schema[:label].presence || "scFAIR #{schema[:version] || version}"
        discovered[id] = Entry.new(id: id, version: version, label: label, path: Pathname.new(path))
      end

      if discovered.empty?
        raise "No scFAIR rules bundles found under #{pattern}"
      end

      unless discovered.key?(DEFAULT_SCHEMA_ID)
        Rails.logger.warn("[RulesRegistry] Default schema #{DEFAULT_SCHEMA_ID} not found; available: #{discovered.keys.join(', ')}") if defined?(Rails)
      end

      discovered
    end
    private_class_method :discover_entries
  end
end
