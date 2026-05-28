# frozen_string_literal: true

module Scfair
  # Shared check definitions for standalone and project validators.
  # This catalog is intentionally format-aware so future schema versions
  # can reuse the same structure with different rule sets.
  module CheckCatalog
    SCHEMAS = {
      'scfair_7_1_0' => {
        id: 'scfair_7_1_0',
        label: 'scFAIR 7.1.0',
        schema_version: '7.1.0_scfair',
        source_url: 'https://github.com/scFAIR/scFAIR/blob/main/schema/7.1.0/schema.md'
      }
    }.freeze

    COMMON_CHECKS = [
      { id: 'obs.required_presence', label: 'Required observation metadata fields', applies_to: %w[loom h5ad] },
      { id: 'uns.required_presence', label: 'Required dataset metadata fields', applies_to: %w[loom h5ad] },
      { id: 'ontology.format', label: 'Ontology identifier format checks', applies_to: %w[loom h5ad] },
      { id: 'cross_field.constraints', label: 'Cross-field schema constraints', applies_to: %w[loom h5ad] },
      { id: 'ontology.database_resolution', label: 'Ontology term resolution in ASAP DB', applies_to: %w[loom h5ad] }
    ].freeze

    LOOM_ONLY_CHECKS = [
      { id: 'loom.paths', label: 'Loom metadata path checks', applies_to: %w[loom] },
      { id: 'loom.mapping_manifest', label: 'anndata_mapping manifest checks', applies_to: %w[loom] }
    ].freeze

    H5AD_ONLY_CHECKS = [
      { id: 'h5ad.structure', label: 'AnnData structural integrity', applies_to: %w[h5ad] },
      { id: 'h5ad.embeddings', label: 'obsm/varm/obsp/varp checks', applies_to: %w[h5ad] },
      { id: 'h5ad.matrix_encoding', label: 'Matrix encoding and finite value checks', applies_to: %w[h5ad] }
    ].freeze

    module_function

    def available_schemas
      SCHEMAS.values
    end

    def schema!(schema_id)
      SCHEMAS.fetch(schema_id) do
        raise ArgumentError, "Unknown schema '#{schema_id}'"
      end
    end

    def checks_for(format)
      checks = COMMON_CHECKS.dup
      checks.concat(LOOM_ONLY_CHECKS) if format == 'loom'
      checks.concat(H5AD_ONLY_CHECKS) if format == 'h5ad'
      checks
    end
  end
end

