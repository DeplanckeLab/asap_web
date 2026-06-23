# frozen_string_literal: true

module Scfair
  # Structural integrity checks derived from file_inventory in a minimal extract.
  class ExtractStructureValidator
    H5AD_REQUIRED_GROUPS = %w[obs var X].freeze
    LOOM_REQUIRED_GROUPS = %w[matrix col_attrs row_attrs attrs].freeze

    def initialize(extract:, format:)
      @extract = extract || {}
      @format = format.to_s
      @inventory = @extract['file_inventory'] || {}
    end

    def call
      errors = []
      warnings = []
      valid_checks = []

      if @format == 'h5ad'
        validate_h5ad_structure(errors, warnings, valid_checks)
      else
        validate_loom_structure(errors, warnings, valid_checks)
      end

      { errors: errors, warnings: warnings, valid_checks: valid_checks }
    end

    private

    def structure
      @inventory['structure'] || {}
    end

    def groups_present
      Array(structure['groups_present']).map(&:to_s)
    end

    def matrix
      @inventory['matrix'] || {}
    end

    def n_obs
      matrix['n_obs'].to_i
    end

    def n_vars
      matrix['n_vars'].to_i
    end

    def obs_columns
      Array(@inventory.dig('obs', 'column_names')).map(&:to_s)
    end

    def declared_obs_columns
      Array(@inventory.dig('obs', 'declared_column_names')).map(&:to_s)
    end

    def validate_h5ad_structure(errors, warnings, valid_checks)
      missing_groups = H5AD_REQUIRED_GROUPS - groups_present
      if missing_groups.any?
        missing_groups.each do |group|
          errors << { field: group, message: "Missing #{group} group" }
        end
      end

      if n_obs <= 0 || n_vars <= 0
        errors << { field: 'X', message: 'AnnData has invalid or unreadable matrix shape' }
      else
        valid_checks << { field: 'X', message: "Matrix shape OK (#{n_obs} cells x #{n_vars} genes)" }
      end

      if groups_present.include?('obs')
        validate_column_order(errors, warnings)
      else
        errors << { field: 'obs', message: 'Missing obs group' }
      end
    end

    def validate_column_order(errors, warnings)
      declared = declared_obs_columns
      return if declared.empty?

      stored = obs_columns.to_set
      missing_declared = declared.reject { |col| stored.include?(col) }.sort
      if missing_declared.any?
        sample = missing_declared.first(8).join(', ')
        suffix = missing_declared.size > 8 ? " (+#{missing_declared.size - 8} more)" : ''
        errors << {
          field: 'obs',
          message: "obs column-order lists #{missing_declared.size} column(s) not stored in the file (e.g. #{sample}#{suffix}); the H5AD obs table is inconsistent"
        }
      end

      extra = obs_columns.reject { |col| declared.include?(col) }.sort
      return if extra.empty?

      warnings << {
        field: 'obs',
        message: "#{extra.size} obs column(s) stored but not listed in column-order (e.g. #{extra.first(5).join(', ')})"
      }
    end

    def validate_loom_structure(errors, warnings, valid_checks)
      missing_groups = LOOM_REQUIRED_GROUPS - groups_present
      missing_groups.each do |group|
        errors << { field: 'loom', message: "Missing /#{group} group" }
      end

      if n_obs <= 0 || n_vars <= 0
        errors << { field: 'loom', message: 'Loom file missing /matrix dataset or invalid shape' }
      else
        valid_checks << {
          field: 'dimensions',
          message: "Matrix dimensions: #{n_obs} cells, #{n_vars} genes"
        }
      end

      if obs_columns.include?('CellID')
        valid_checks << { field: '/col_attrs/CellID', message: 'Found /col_attrs/CellID' }
      else
        warnings << { field: '/col_attrs/CellID', message: 'Missing /col_attrs/CellID (recommended for observation identifiers)' }
      end

      if structure['anndata_mapping_present']
        valid_checks << { field: '/attrs/anndata_mapping', message: 'Found anndata_mapping manifest' }
      else
        warnings << {
          field: '/attrs/anndata_mapping',
          message: 'Missing anndata_mapping manifest (recommended for deterministic Loom->H5AD conversion)'
        }
      end
    end
  end
end
