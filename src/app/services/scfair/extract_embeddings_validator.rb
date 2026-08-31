# frozen_string_literal: true

module Scfair
  # Embedding / coordinate array checks from obsm and col_embeddings metadata in a minimal extract.
  #
  # scFAIR 7.1.0:
  # - general obsm arrays: shape (n_obs, m) with m >= 1
  # - X_{suffix} embeddings: at least two columns; suffix must not be "spatial"
  class ExtractEmbeddingsValidator
    X_EMBEDDING_KEY = /\AX_[A-Za-z][A-Za-z0-9_.-]*\z/
    X_MIN_COLUMNS = 2
    GENERAL_MIN_COLUMNS = 1

    def initialize(extract:, format:)
      @extract = extract || {}
      @format = format.to_s
      @n_obs = @extract.dig('file_inventory', 'matrix', 'n_obs').to_i
    end

    def call
      errors = []
      warnings = []
      valid_checks = []

      embedding_sections.each do |section|
        section.each do |key, meta|
          path = embedding_path(key)
          validate_embedding(path, key, meta, errors)
        end
      end

      total = embedding_sections.sum { |section| section.size }
      if total.positive?
        valid_checks << {
          field: summary_field,
          status: 'passed',
          message: "#{total} embedding(s) found"
        }
      else
        valid_checks << {
          field: summary_field,
          status: 'skipped',
          message: 'No embeddings present (optional per schema)'
        }
      end

      { errors: errors, warnings: warnings, valid_checks: valid_checks }
    end

    private

    def embedding_sections
      sections = []
      obsm = @extract['obsm']
      sections << obsm if obsm.is_a?(Hash) && obsm.any?

      col = @extract['col_embeddings']
      sections << col if col.is_a?(Hash) && col.any?

      sections
    end

    def embedding_path(key)
      key.to_s.start_with?('/') ? key.to_s : "obsm/#{key}"
    end

    def summary_field
      @format == 'loom' ? 'loom.embeddings' : 'obsm'
    end

    def embedding_base_key(path_or_key)
      path_or_key.to_s.sub(%r{\Aobsm/}, '').sub(%r{\A/col_attrs/}, '')
    end

    # Schema X_{suffix} keys (not X_spatial). Other obsm keys only need m >= 1.
    def schema_x_embedding_key?(path_or_key)
      base = embedding_base_key(path_or_key)
      return false if base == 'X_spatial'

      base.match?(X_EMBEDDING_KEY)
    end

    def min_columns_for(path_or_key)
      schema_x_embedding_key?(path_or_key) ? X_MIN_COLUMNS : GENERAL_MIN_COLUMNS
    end

    def validate_embedding(path, key, meta, errors)
      shape = Array(meta['shape']).map(&:to_i)
      if shape.empty?
        errors << { field: path, message: 'Could not read embedding array' }
        return
      end

      if @n_obs.positive? && shape.first != @n_obs
        errors << { field: path, message: 'Embedding row count does not match n_obs' }
      end

      min_columns = min_columns_for(key)
      if shape.size != 2 || shape.last < min_columns
        if schema_x_embedding_key?(key)
          errors << {
            field: path,
            message: "X_* embedding must be 2D with at least #{X_MIN_COLUMNS} columns"
          }
        else
          errors << {
            field: path,
            message: "obsm array must be 2D with at least #{GENERAL_MIN_COLUMNS} column"
          }
        end
      end

      if meta['has_inf'] == true
        errors << { field: path, message: 'Embedding contains infinity values' }
      end
    end
  end
end
