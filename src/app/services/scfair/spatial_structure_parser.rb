# frozen_string_literal: true

module Scfair
  class SpatialStructureParser
    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
      @prefix = SpatialAssayHelper.spatial_prefix(@format)
    end

    def parse
      relative_paths = collect_relative_paths
      top_level_keys = relative_paths.map { |path| path.split('/').first }.uniq
      library_ids = top_level_keys.reject { |key| key == root_scalar_key }.select do |key|
        relative_paths.any? { |path| path.start_with?("#{key}/") }
      end

      {
        present: relative_paths.any?,
        is_single: read_is_single,
        relative_paths: relative_paths,
        top_level_keys: top_level_keys,
        library_ids: library_ids
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

    def root_scalar_key
      Rules.spatial_extension_rules[:root_scalar_key]
    end

    def collect_relative_paths
      @field_values.keys
                   .select { |key| key.start_with?(@prefix) && !key.include?('#') }
                   .map { |key| key.delete_prefix(@prefix) }
                   .reject(&:blank?)
                   .uniq
    end

    def read_is_single
      SpatialAssayHelper.parse_bool(Array(@field_values[SpatialAssayHelper.spatial_is_single_key(@format)]).first)
    end
  end
end
