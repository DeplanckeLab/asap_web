# frozen_string_literal: true

module Scfair
  module SpatialArrayMetadata
    module_function

    def read(field_values, path)
      values = field_values || {}
      shape_raw = Array(values["#{path}#shape"]).first.to_s
      dtype = Array(values["#{path}#dtype"]).first.to_s.presence
      has_inf = parse_bool(Array(values["#{path}#has_inf"]).first)
      has_nan = parse_bool(Array(values["#{path}#has_nan"]).first)

      {
        present: Array(values[path]).any? || shape_raw.present?,
        shape: parse_shape(shape_raw),
        dtype: dtype,
        has_inf: has_inf,
        has_nan: has_nan
      }
    end

    def complete?(meta)
      meta[:shape].present? && meta[:dtype].present?
    end

    def parse_shape(raw)
      return [] if raw.blank?

      raw.split(',').map(&:strip).reject(&:blank?).map(&:to_i)
    end

    def parse_bool(value)
      return nil if value.nil?

      %w[true 1 t yes].include?(value.to_s.strip.downcase)
    end

    def dtype_kind(dtype)
      case dtype.to_s.downcase
      when /\Afloat/ then 'f'
      when /\Aint/ then 'i'
      when /\Auint/ then 'u'
      else
        dtype.to_s.strip.first
      end
    end
  end
end
