# frozen_string_literal: true

require 'json'

module Scfair
  class PerturbStructureParser
    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
      @rules = Rules.perturb_extension_rules
      @root_prefix = PerturbAssayHelper.uns_root_prefix(@format)
      @root_key = PerturbAssayHelper.uns_root_key(@format)
    end

    def parse
      relative_paths = collect_relative_paths
      perturbation_ids = relative_paths
                         .map { |path| path.split('/').first }
                         .reject { |id| id.blank? || id == @rules[:uns_root_key] }
                         .uniq

      entries = perturbation_ids.index_with { |id| entry_for(id, relative_paths) }

      {
        present: relative_paths.any? || json_root_present?,
        perturbation_ids: perturbation_ids,
        entries: entries,
        relative_paths: relative_paths
      }
    end

    def path_present?(structure, *segments)
      relative = segments.map(&:to_s).join('/')
      structure[:relative_paths].any? do |path|
        path == relative || path.start_with?("#{relative}/")
      end
    end

    def child_keys(structure, *parent_segments)
      prefix = parent_segments.map(&:to_s).join('/')
      return [] if prefix.blank?

      structure[:relative_paths].filter_map do |path|
        next unless path.start_with?("#{prefix}/")

        remainder = path.delete_prefix("#{prefix}/")
        remainder.split('/').first
      end.uniq
    end

    private

    def collect_relative_paths
      paths = @field_values.keys
                           .select { |key| key.start_with?(@root_prefix) && !key.include?('#') }
                           .map { |key| key.delete_prefix(@root_prefix) }
                           .reject(&:blank?)
                           .uniq

      paths.concat(paths_from_json_root)
      paths.uniq
    end

    def paths_from_json_root
      raw = Array(@field_values[@root_key]).first
      return [] if raw.blank?

      parsed = parse_json_hash(raw)
      return [] unless parsed.is_a?(Hash)

      flatten_hash_paths(parsed, '')
    end

    def json_root_present?
      raw = Array(@field_values[@root_key]).first
      return false if raw.blank?

      parsed = parse_json_hash(raw)
      parsed.is_a?(Hash) && parsed.any?
    end

    def entry_for(id, relative_paths)
      prefix = "#{id}/"
      scalar_keys = relative_paths.filter_map do |path|
        next unless path.start_with?(prefix)

        remainder = path.delete_prefix(prefix)
        next if remainder.include?('/')

        remainder
      end

      derived_feature_ids = relative_paths.filter_map do |path|
        next unless path.start_with?("#{id}/derived_features/")

        path.delete_prefix("#{id}/derived_features/")
      end.uniq

      scalar_values = scalar_keys.index_with do |key|
        read_scalar("#{@root_prefix}#{id}/#{key}")
      end

      json_entry = json_entry_for(id)
      scalar_values = json_entry.merge(scalar_values) if json_entry.any?

      {
        scalar_keys: scalar_keys,
        scalar_values: scalar_values,
        derived_feature_ids: derived_feature_ids,
        derived_feature_values: derived_feature_ids.index_with do |feature_id|
          read_scalar("#{@root_prefix}#{id}/derived_features/#{feature_id}")
        end
      }
    end

    def json_entry_for(id)
      raw = Array(@field_values[@root_key]).first
      return {} if raw.blank?

      parsed = parse_json_hash(raw)
      return {} unless parsed.is_a?(Hash)

      entry = parsed[id] || parsed[id.to_sym]
      return {} unless entry.is_a?(Hash)

      entry.each_with_object({}) do |(key, value), out|
        key = key.to_s
        next if key == 'derived_features'

        out[key] = if value.is_a?(Array)
                     value.map(&:to_s)
                   else
                     [value.to_s]
                   end
      end
    end

    def flatten_hash_paths(hash, prefix)
      hash.flat_map do |key, value|
        key = key.to_s
        path = prefix.blank? ? key : "#{prefix}/#{key}"
        case value
        when Hash
          flatten_hash_paths(value, path)
        else
          [path]
        end
      end
    end

    def read_scalar(path)
      Array(@field_values[path]).map(&:to_s).reject(&:blank?)
    end

    def parse_json_hash(raw)
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end
  end
end
