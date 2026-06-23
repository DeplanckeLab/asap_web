# frozen_string_literal: true

module Scfair
  # Embedding / coordinate array checks from obsm and col_embeddings metadata in a minimal extract.
  class ExtractEmbeddingsValidator
    MIN_COLUMNS = 2

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
          validate_embedding(path, meta, errors)
        end
      end

      total = embedding_sections.sum { |section| section.size }
      if total.zero?
        warnings << { field: 'obsm', message: 'No embeddings found' }
      else
        valid_checks << { field: 'obsm', message: "#{total} embedding(s) found" }
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

    def validate_embedding(path, meta, errors)
      shape = Array(meta['shape']).map(&:to_i)
      if shape.empty?
        errors << { field: path, message: 'Could not read embedding array' }
        return
      end

      if @n_obs.positive? && shape.first != @n_obs
        errors << { field: path, message: 'Embedding row count does not match n_obs' }
      end

      if shape.size != 2 || shape.last < MIN_COLUMNS
        errors << { field: path, message: 'Embedding must be 2D with at least 2 columns' }
      end

      if meta['has_inf'] == true
        errors << { field: path, message: 'Embedding contains infinity values' }
      end
    end
  end
end
