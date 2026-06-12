# frozen_string_literal: true

module Scfair
  class CheckDetailBuilder
    CATEGORY_SUMMARIES = {
      'obs.required_presence' => 'Required per-cell observation metadata fields defined by scFAIR 7.1.0.',
      'uns.required_presence' => 'Required dataset-level metadata fields in uns/attrs.',
      'schema.version' => 'The file schema_version must be compatible with the reference schema version.',
      'schema.reference' => 'The file schema_reference should match the canonical URL of the reference schema.',
      'uns.ensembl' => 'Ensembl release, database, and optional assembly used for gene annotation.',
      'obs.experimental_condition' => 'Experimental condition ontology IDs, labels, and perturbation types.',
      'var.required' => 'Required per-gene metadata columns in var / row_attrs.',
      'var.index' => 'Var pandas.DataFrame index: unique feature identifiers (Ensembl gene_id or ERCC spike-in).',
      'var.cross_field' => 'Var metadata must be consistent with uns organism and ensembl_release.',
      'cross-field.uns_ensembl' => 'Ensembl release and assembly must match the dataset organism in ASAP reference data.',
      'schema.reference' => 'The file schema_reference should match the canonical URL of the reference schema.',
      'uns.ensembl' => 'Ensembl release, database, and optional assembly used for gene annotation.',
      'obs.experimental_condition' => 'Experimental condition ontology IDs, labels, and perturbation types.',
      'var.required' => 'Required per-gene metadata columns in var / row_attrs.',
      'var.index' => 'Var pandas.DataFrame index: unique feature identifiers (Ensembl gene_id or ERCC spike-in).',
      'var.cross_field' => 'Var metadata must be consistent with uns organism and ensembl_release.',
      'cross-field.uns_ensembl' => 'Ensembl release and assembly must match the dataset organism in ASAP reference data.',
      'ontology.format' => 'Ontology term identifiers must use valid OBO-style PREFIX:ID format and allowed prefixes.',
      'cross-field.constraints' => 'Metadata fields must satisfy cross-field consistency rules.',
      'ontology.database_resolution' => 'Ontology terms must resolve to known entries in the ASAP ontology database.',
      'ontology.organism_specific' => 'Metadata fields whose allowed ontology terms depend on the dataset organism.',
      'ontology.semantics' => 'Ontology terms must satisfy semantic constraints (roots, forbidden branches, allowed values).',
      'loom.paths' => 'Required Loom HDF5 paths for observation and dataset metadata.',
      'loom.mapping_manifest' => 'The anndata_mapping manifest documents Loom to AnnData path mapping.',
      'h5ad.structure' => 'AnnData object structure (obs, var, layers) integrity checks.',
      'h5ad.embeddings' => 'Optional embedding matrices in obsm/varm/obsp/varp.',
      'h5ad.matrix_encoding' => 'Expression matrix encoding and finite numeric values.',
      'extension.spatial' => 'Spatial transcriptomics extension metadata under uns/spatial.',
      'extension.spatial.structure' => 'uns/spatial dictionary layout (is_single, library identifiers, scalefactors).',
      'extension.spatial.library' => 'Visium library identifier block under uns/spatial when is_single is true.',
      'extension.spatial.obs' => 'Visium spot metadata columns (array_row, array_col, in_tissue).',
      'extension.spatial.assets' => 'Tissue image array content and obsm spatial coordinate embedding.',
      'extension.spatial.obsm' => 'obsm spatial embedding required when spatial.is_single is true.',
      'extension.spatial.images.hires' => 'Visium hires tissue image array (uint8, shape, pixel size).',
      'extension.perturb' => 'Genetic perturbation extension metadata (scFAIR schema_perturb.md).',
      'extension.perturb.presence' => 'Conditional presence of genetic_perturbation_id, genetic_perturbation_strategy, and uns genetic_perturbations.',
      'extension.perturb.obs.id' => 'obs genetic_perturbation_id values and references to uns genetic_perturbations.',
      'extension.perturb.strategy' => 'obs genetic_perturbation_strategy enum values.',
      'extension.perturb.uns' => 'uns genetic_perturbations dictionary structure and curator-required fields.',
      'extension.perturb.organism' => 'Organism restriction for perturbation datasets.',
      'extension.atac' => 'ATAC-seq extension metadata.',
      'extension.analysis_json' => 'analysis_json extension metadata.',
      'metadata.other.reserved_prefix' => 'Metadata field names must not start with "__".',
      'metadata.other.unique_names.obs' => 'Observation metadata field names must be unique.',
      'metadata.other.unique_names.var' => 'Variable (gene) metadata field names must be unique.',
      'metadata.other.deprecated' => 'Deprecated reserved names from prior schema versions must not be present.'
    }.freeze

    METADATA_OTHER_TITLES = {
      'metadata.other.reserved_prefix' => 'Reserved name prefix',
      'metadata.other.unique_names.obs' => 'Unique obs metadata names',
      'metadata.other.unique_names.var' => 'Unique var metadata names',
      'metadata.other.deprecated' => 'Deprecated reserved names'
    }.freeze

    CATEGORY_CHECKS = {
      'obs.required_presence' => [
        'Each required observation (obs / col_attrs) column from scFAIR 7.1.0 is present',
        'Ontology term ID fields: assay, cell_type, disease, development_stage, sex, tissue, ethnicity',
        'Human-readable label columns paired with each ontology term ID',
        'Categorical fields: tissue_type, suspension_type, donor_id, is_primary_data'
      ],
      'uns.required_presence' => [
        'Each required dataset metadata field is validated individually',
        'Open a specific field check for presence requirements'
      ],
      'schema.version' => [
        'Reads schema_version from uns/attrs',
        'Compares major.minor version against the reference scFAIR release',
        'Accepts compatible schema_version identifiers (e.g. 7.1.0_scfair)'
      ],
      'schema.reference' => [
        'Reads schema_reference from uns (H5AD) or /attrs (Loom)',
        'Compares against the canonical schema URL for this validator release',
        'Warns when the URL does not match exactly'
      ],
      'uns.ensembl' => [
        'Each Ensembl metadata field is validated individually',
        'Open a specific field check for presence and value constraints'
      ],
      'obs.experimental_condition' => [
        'experimental_condition_ontology_term_id must be absent when all observations are na',
        'experimental_condition label required when the ID column is present',
        'perturbation_types required when experimental_condition or genetic_perturbation_id is present',
        'Multi-values must be unique and sorted lexically with " || " delimiter'
      ],
      'var.required' => [
        'Each required var / row_attrs column is validated individually',
        'Open a specific field check for column presence and value constraints'
      ],
      'var.index' => [
        'Var index must be present (H5AD var/_index; Loom /row_attrs/feature_id or _index)',
        'Identifiers must be unique across all features',
        'ERCC spike-in and Ensembl gene_id format rules (version suffix stripped for ENS IDs)'
      ],
      'var.cross_field' => [
        'feature_reference must use schema NCBITaxon reference taxa per feature biotype',
        'feature_name must match var index per gene reference rules (gene_name or index; ERCC for spike-ins)',
        'var index gene identifiers must exist for the organism at ensembl_release'
      ],
      'cross-field.uns_ensembl' => [
        'ensembl_release must be supported by at least one ASAP assembly for the organism',
        'ensembl_assembly must match a known assembly for the organism and release when present'
      ],
      'schema.reference' => [
        'Reads schema_reference from uns (H5AD) or /attrs (Loom)',
        'Compares against the canonical schema URL for this validator release',
        'Warns when the URL does not match exactly'
      ],
      'uns.ensembl' => [
        'Each Ensembl metadata field is validated individually',
        'Open a specific field check for presence and value constraints'
      ],
      'obs.experimental_condition' => [
        'experimental_condition_ontology_term_id must be absent when all observations are na',
        'experimental_condition label required when the ID column is present',
        'perturbation_types required when experimental_condition or genetic_perturbation_id is present',
        'Multi-values must be unique and sorted lexically with " || " delimiter'
      ],
      'var.required' => [
        'Each required var / row_attrs column is validated individually',
        'Open a specific field check for column presence and value constraints'
      ],
      'var.index' => [
        'Var index must be present (H5AD var/_index; Loom /row_attrs/feature_id or _index)',
        'Identifiers must be unique across all features',
        'ERCC spike-in and Ensembl gene_id format rules (version suffix stripped for ENS IDs)'
      ],
      'var.cross_field' => [
        'feature_reference must use schema NCBITaxon reference taxa per feature biotype',
        'feature_name must match var index per gene reference rules (gene_name or index; ERCC for spike-ins)',
        'var index gene identifiers must exist for the organism at ensembl_release'
      ],
      'cross-field.uns_ensembl' => [
        'ensembl_release must be supported by at least one ASAP assembly for the organism',
        'ensembl_assembly must match a known assembly for the organism and release when present'
      ],
      'ontology.format' => [
        'Validates OBO-style PREFIX:ID syntax for ontology term fields',
        'Checks allowed ontology prefixes per field (EFO, CL, UBERON, MONDO, etc.)',
        'Allows documented special placeholder values (na, unknown, multiethnic)',
        'Accepts Cellosaurus CVCL_* identifiers where the schema permits them'
      ],
      'cross-field.constraints' => [
        'CF-1: assay_ontology_term_id determines allowed suspension_type values',
        'CF-2a-2f: tissue_type "cell line" forces ethnicity, sex, development_stage, donor_id, suspension_type, and tissue ID rules',
        'CF-3: donor_id must not be "na" except for cell lines',
        'CF-4: organoid tissue must not be embryo (UBERON:0000922)',
        'CF-5 to CF-10: spatial assay uniformity, metadata presence, is_primary_data, and Visium in_tissue rules',
        'CF-8: special ontology IDs (na/unknown) must match their label columns'
      ],
      'ontology.database_resolution' => [
        'Each ontology term ID is looked up in the ASAP ontology database',
        'Reports terms that cannot be resolved or mapped to a known ontology entry',
        'Label columns are checked against authorised ontology names where applicable'
      ],
      'ontology.organism_specific' => [
        'Uses organism_ontology_term_id to select taxon-specific ontology prefix rules',
        'Development stage prefixes (HsapDv, MmusDv, WBls, ZFS, FBdv)',
        'Cell type and tissue prefixes for model organisms (C. elegans, zebrafish, fly)',
        'Ethnicity rules for human vs non-human datasets',
        'C. elegans sex term restrictions'
      ],
      'ontology.semantics' => [
        'Per-field semantic subchecks driven by rules.yaml semantic_rules',
        'Descendant / root restrictions (any_roots)',
        'Banned terms and forbidden branches',
        'Allowed exact terms and special placeholder values',
        'Multi-value ordering for ethnicity (sorted " || " lists)',
        'Label must match ontology ID for special placeholder pairs',
        'organism_ontology_term_id and organism label must match the ASAP organisms table (NCBITaxon tax_id and name)'
      ],
      'loom.paths' => [
        'Required Loom HDF5 paths exist for observation and dataset metadata',
        'Col_attrs paths mirror AnnData obs fields',
        'Global /attrs paths mirror AnnData uns fields'
      ],
      'loom.mapping_manifest' => [
        'Checks for anndata_mapping manifest in /attrs',
        'Recommended for deterministic Loom to H5AD conversion'
      ],
      'h5ad.structure' => [
        'AnnData groups exist: obs, var, X',
        'obs column-order metadata matches stored columns',
        'Required obs and uns fields are present'
      ],
      'h5ad.embeddings' => [
        'obsm/varm/obsp/varp embedding arrays are readable',
        'Embeddings are 2D with at least two columns',
        'Row counts match n_obs where applicable',
        'No all-NaN or infinite values in embeddings'
      ],
      'h5ad.matrix_encoding' => [
        'Expression matrix X has valid shape and encoding',
        'Sparse matrices use supported CSR/CSC layouts',
        'Numeric values are finite where required by the schema'
      ],
      'extension.perturb' => [
        'Detects perturbation datasets from uns/genetic_perturbations or obs genetic_perturbation_id',
        'Requires genetic_perturbation_strategy when genetic_perturbation_id is present',
        'Validates perturbation extension structure per schema_perturb.md'
      ],
      'extension.atac' => [
        'Detects ATAC or 10x multiome assays via ontology lineage',
        'Warns that fragment file assets should be supplied separately'
      ],
      'extension.analysis_json' => [
        'Looks for analysis_pipeline metadata (recommended analysis_json extension)',
        'Warns when analysis pipeline metadata is absent'
      ]
    }.freeze

    METADATA_OTHER_CHECKS = {
      'metadata.other.reserved_prefix' => [
        'Scans obs and var metadata column names',
        'Fails when any name starts with the forbidden "__" prefix'
      ],
      'metadata.other.unique_names.obs' => [
        'Collects all observation metadata column names',
        'Fails when duplicate names are present in obs / col_attrs'
      ],
      'metadata.other.unique_names.var' => [
        'Collects all variable metadata column names',
        'Fails when duplicate names are present in var / row_attrs'
      ],
      'metadata.other.deprecated' => [
        'Checks obs, var, and uns for reserved names deprecated in prior schema versions',
        'Includes legacy fields such as obs/ethnicity and uns/version'
      ]
    }.freeze

    SPATIAL_ROLLUP_CHECKS = [
      'Detects spatial datasets from Visium/Slide-seq assays or uns/spatial metadata',
      'extension.spatial.structure: uns/spatial dictionary layout',
      'extension.spatial.obs: Visium spot columns when is_single is true',
      'extension.spatial.assets: tissue image arrays and spatial embedding'
    ].freeze

    UNS_FIELD_CHECKS = {
      'title' => [
        'Field must be present in uns (H5AD) or /attrs (Loom)',
        'Short human-readable dataset title required by scFAIR'
      ],
      'organism_ontology_term_id' => [
        'Field must be present in uns (H5AD) or /attrs (Loom)',
        'Must use NCBITaxon:tax_id format for the dataset species',
        'Validated for ontology format and semantic constraints when values are present'
      ],
      'organism' => [
        'Field must be present in uns (H5AD) or /attrs (Loom)',
        'Human-readable organism label paired with organism_ontology_term_id',
        'Label must match the organism name for the declared NCBITaxon term'
      ],
      'schema_version' => [
        'Field must be present in uns (H5AD) or /attrs (Loom)',
        'Must be compatible with the reference scFAIR schema version'
      ],
      'schema_reference' => [
        'Field must be present in uns (H5AD only)',
        'Must match the canonical schema URL for this validator release'
      ],
      'ensembl_release' => [
        'Field must be present in uns (H5AD) or /attrs (Loom)',
        'Must be a positive integer Ensembl release number'
      ],
      'ensembl_database' => [
        'Field must be present in uns (H5AD) or /attrs (Loom)',
        'Must be one of the schema Ensembl database enum values'
      ],
      'ensembl_assembly' => [
        'Optional field; skipped when not annotated',
        'When present, must be a non-empty assembly name string'
      ]
    }.freeze

    VAR_FIELD_CHECKS = {
      'feature_is_filtered' => [
        'Column must be present in var (H5AD) or row_attrs (Loom)',
        'Values must be boolean true or false (true, false, True, or False)'
      ],
      'feature_biotype' => [
        'Column must be present in var (H5AD) or row_attrs (Loom)',
        'Values must be one of the schema biotype enum values'
      ],
      'feature_length' => [
        'Column must be present in var (H5AD) or row_attrs (Loom)',
        'Values must be a positive integer (gene length in base pairs)'
      ],
      'feature_name' => [
        'Column must be present in var (H5AD) or row_attrs (Loom)',
        'Spike-in: "{ERCC-ID} (spike-in control)" matching var index',
        'Gene: gene_name from the reference for var index, or var index when gene_name is absent'
      ],
      'feature_reference' => [
        'Column must be present in var (H5AD) or row_attrs (Loom)',
        'Must be the schema NCBITaxon reference organism for the feature (pinned gene annotations table)'
      ],
      'feature_type' => [
        'Column must be present in var (H5AD) or row_attrs (Loom)',
        'Values must be a non-empty string (e.g. protein_coding, synthetic)'
      ],
      'feature_chromosome' => [
        'Column must be present in var (H5AD) or row_attrs (Loom)',
        'Values must be a non-empty string (chromosome name or na for spike-ins)'
      ]
    }.freeze

    FIELD_CHECKS = {
      'extension.spatial.structure' => [
        'spatial.is_single must be a boolean',
        'Spatial root may only contain is_single and library identifier keys',
        'Visium + is_single=true: exactly one library identifier with images and scalefactors sections',
        'Visium + is_single=false: library metadata must not be present',
        'images section: hires key required, fullres optional; scalefactor scalars must be parseable floats'
      ],
      'extension.spatial.obs' => [
        'Applies when assay is Visium and spatial.is_single is true',
        'Requires obs/array_row, obs/array_col, and obs/in_tissue (col_attrs on Loom)',
        'These fields must not be present for non-Visium or is_single=false datasets'
      ],
      'extension.spatial.assets' => [
        'Tissue image (images/hires): uint8 3D array (height x width x channels)',
        'Tissue image (images/hires): channel dimension must be 3 (RGB) or 4 (RGBA)',
        'Tissue image (images/hires): largest dimension 2000 px (4000 px for CytAssist 11mm, EFO:0022860)',
        'Tissue image (images/fullres): same uint8 3D RGB/RGBA rules when present',
        'Spatial embedding (obsm/spatial or /col_attrs/spatial): required when is_single is true',
        'Spatial embedding: 2D array with at least two columns and row count matching n_obs',
        'Spatial embedding: dtype kind must be float, integer, or unsigned integer; no infinity or NaN'
      ],
      'extension.spatial.images.hires' => [
        'images/hires must be present for Visium libraries when is_single is true',
        'Image dtype must be uint8 with a 3D shape (height x width x channels)',
        'Channel dimension must be 3 (RGB) or 4 (RGBA)',
        'Largest image dimension must be 2000 px (4000 px for CytAssist 11mm, EFO:0022860)'
      ],
      'extension.spatial.images.fullres' => [
        'Optional full-resolution tissue image when present',
        'Same uint8 3D RGB/RGBA array requirements as hires'
      ],
      'extension.spatial.obsm' => [
        'obsm/spatial (H5AD) or /col_attrs/spatial (Loom) required when spatial.is_single is true',
        'Embedding must be 2D with at least two columns and row count matching n_obs',
        'Dtype kind must be float, integer, or unsigned integer',
        'Must not contain infinity or NaN values'
      ],
      'extension.spatial.library' => [
        'Exactly one Visium library identifier under uns/spatial when is_single is true',
        'Library dict may only contain images and scalefactors keys'
      ]
    }.freeze

    SEMANTIC_CHECK_TITLES = {
      'allowed_terms' => 'Allowed / known terms',
      'existence' => 'Ontology term existence',
      'banned_terms' => 'Banned terms',
      'forbidden' => 'Banned term',
      'descendants' => 'Descendant / root restrictions',
      'lineage' => 'Lineage restrictions',
      'sorted_multi' => 'Multi-value ordering',
      'ordering' => 'Multi-value ordering',
      'special_values' => 'Special placeholder values',
      'label_pair' => 'ID / label pairs',
      'special_label_pair' => 'Special ID / label pairs'
    }.freeze

    SEMANTIC_CHECK_SUMMARIES = {
      'allowed_terms' => 'Each term must resolve as an active (non-obsolete) entry in the ontology database and match any allowed exact values.',
      'existence' => 'The term must exist as an active (non-obsolete) entry in the ontology database.',
      'banned_terms' => 'Terms must not match a banned identifier or fall under a banned branch.',
      'forbidden' => 'This term is explicitly banned for the field.',
      'descendants' => 'Each term must descend from one of the required ontology roots.',
      'lineage' => 'The term must satisfy the required lineage constraints for this field.',
      'sorted_multi' => 'Multiple values must be unique and sorted lexically, separated by " || ".',
      'ordering' => 'Multiple values must be unique and sorted lexically, separated by " || ".',
      'special_values' => 'Placeholder values allowed instead of a real ontology term.',
      'label_pair' => 'Human-readable labels must match their ontology term identifiers.',
      'special_label_pair' => 'When a special placeholder ID is used, the label must match exactly.'
    }.freeze

    PRESENCE_CHECK = /
      Required\ field\ present |
      Missing\ required\ observation\ field |
      Missing\ required\ dataset\ metadata\ field |
      Missing\ required\ variable\ metadata\ field |
      Missing\ required\ variable\ metadata\ field |
      \AFound\ .+\ metadata\z |
      Missing\ .+\ metadata\ \(required\ by\ schema\) |
      Skipped\ \(pre-analysis\ dataset\)
    /x

    ONTOLOGY_FORMAT_CHECK = /
      Ontology\ terms\ in\ .+\ have\ valid\ format |
      Invalid\ ontology\ term\ format |
      Invalid\ ontology\ format |
      Unexpected\ ontology\ prefix |
      Ontology\ prefix\ .+\ may\ not\ be\ valid
    /x

    def self.presence_check_message?(message)
      message.to_s.match?(PRESENCE_CHECK)
    end

    def self.call(field:, message:, format:, category_id: nil, field_values: nil)
      new(field: field, message: message, format: format, category_id: category_id, field_values: field_values).call
    end

    def self.enrich_item(item, format:, category_id: nil, field_values: nil)
      field = (item[:field] || item['field']).to_s
      message = (item[:message] || item['message']).to_s
      detail = call(field: field, message: message, format: format, category_id: category_id, field_values: field_values)
      status = (item[:status] || item['status']).to_s.strip.downcase.presence
      detail[:status] = status if status.present?
      item.merge(detail: detail)
    end

    def initialize(field:, message:, format:, category_id: nil, field_values: nil)
      @field = field.to_s
      @message = message.to_s
      @format = format.to_s
      @category_id = category_id.to_s.presence
      @field_values = field_values || {}
    end

    def call
      category_id = @category_id || Scfair::ComplianceReportGrouper.category_for(
        field: @field,
        message: @message,
        format: @format
      )

      category_label = catalog_label(category_id)
      field_name = extract_field_name(@field)

      detail = {
        field: @field,
        category_id: category_id,
        category_label: category_label,
        title: detail_title(field_name, category_id),
        summary: detail_summary(field_name, category_id),
        result_message: @message,
        checks_performed: checks_performed(category_id),
        constraints: build_constraints(field_name, category_id),
        schema_url: Rules.schema_hash[:source_url],
        schema_version: Rules.schema_version
      }

      detail_rule = yaml_check_detail_for_field
      if detail_rule
        detail[:title] = detail_rule[:title]
        detail[:summary] = detail_rule[:summary]
        detail[:checks_performed] = yaml_checks_with_paths(
          detail_rule[:checks],
          "check_details.by_field.#{yaml_check_detail_field_key}"
        )
      end

      rule = Rules.cross_field_rule_by_id(@field.delete_prefix('cross-field.'))
      if rule.present? && @field.start_with?('cross-field.')
        detail[:title] ||= rule[:title]
        detail[:summary] ||= rule[:summary]
      end

      metadata_other = Rules.metadata_other_detail(@field)
      if metadata_other
        detail[:title] = metadata_other[:title]
        detail[:summary] = metadata_other[:summary]
        if metadata_other[:checks].present?
          detail[:checks_performed] = yaml_checks_with_paths(
            metadata_other[:checks],
            "check_details.metadata_other.#{@field}"
          )
        end
      end

      detail[:checks_performed] = attach_rules_paths_to_checks(
        detail[:checks_performed],
        checks_rules_path_prefix(category_id)
      )

      detail
    end

    private

    def checks_performed(category_id)
      return Rules.spatial_rollup_checks if @field == 'extension.spatial'

      metadata_other = Rules.metadata_other_detail(@field)
      return metadata_other[:checks] if metadata_other&.dig(:checks)&.present?

      extension_checks = Rules.extension_field_checks(@field)
      return extension_checks if extension_checks.any?

      uns_field = uns_metadata_field_name(@field)
      if uns_field.present?
        uns_checks = Rules.layer_field_checks(:uns, uns_field, format: @format)
        return uns_checks if uns_checks.any?
      end

      obs_field = obs_metadata_field_name(@field)
      if obs_field.present? && obs_presence_check?(category_id)
        obs_checks = Rules.layer_field_checks(:obs, obs_field, format: @format)
        return obs_checks if obs_checks.any?
      end

      var_field = var_metadata_field_name(@field)
      if var_field.present?
        var_checks = Rules.layer_field_checks(:var, var_field, format: @format)
        return var_checks if var_checks.any?
      end

      if var_index_storage_path?(@field)
        presence_checks = Rules.check_detail_for_field('var.index.presence')&.dig(:checks)
        return presence_checks if presence_checks.present?
      end

      field_detail = Rules.check_detail_for_field(@field)
      if @field.start_with?('cross-field.') && field_detail
        return Array(field_detail[:checks]).map(&:to_s)
      end

      if @field.start_with?('obs.label_pairs.') && field_detail&.dig(:checks)&.present?
        return field_detail[:checks]
      end

      if @field.start_with?('ontology.organism_specific.') && field_detail&.dig(:checks)&.present?
        return field_detail[:checks]
      end

      ontology_field = ontology_term_field_name_from_path
      if ontology_field.present? && (ontology_format_check? || category_id == 'ontology.format')
        performed = ontology_format_checks_performed(ontology_field)
        return performed if performed.any?
      end

      if ontology_field.present? && category_id == 'ontology.database_resolution'
        performed = ontology_database_resolution_checks_performed(ontology_field)
        return performed if performed.any?
      end

      if presence_check?
        performed = presence_checks_performed(extract_field_name(@field), category_id)
        return performed if performed.any?
      end

      organism_checks = Rules.check_detail_for_field(@field)&.dig(:checks)
      return organism_checks if @field.start_with?('ontology.organism_specific.') && organism_checks.present?

      ontology_field = ontology_term_field_name_from_path
      if ontology_field.present? && (ontology_format_check? || category_id == 'ontology.format')
        performed = ontology_format_checks_performed(ontology_field)
        return performed if performed.any?
      end

      if ontology_field.present? && category_id == 'ontology.database_resolution'
        performed = ontology_database_resolution_checks_performed(ontology_field)
        return performed if performed.any?
      end

      if presence_check?
        performed = presence_checks_performed(extract_field_name(@field), category_id)
        return performed if performed.any?
      end

      field_name = semantic_ontology_field_name(@field)
      suffix = semantic_rule_suffix(@field)
      if suffix.present? && semantic_ontology_field?(field_name)
        performed = semantic_checks_performed(field_name, suffix)
        return performed if performed.any?
      end

      Rules.category_checks_list(category_id)
    end

    def catalog_label(category_id)
      return nil if category_id.blank?

      Scfair::CheckCatalog.checks_for(@format).find { |entry| entry[:id] == category_id }&.dig(:label)
    end

    def extract_field_name(field)
      return field.sub(/\Across-field\.[^.]+\z/, '') if field.start_with?('cross-field.')
      return semantic_ontology_field_name(field) if field.start_with?('ontology.semantics.')

      segment = field.split('/').last.to_s
      segment.presence || field
    end

    def semantic_ontology_field_name(field)
      field.sub(/\Aontology\.semantics\./, '').split('.').first.to_s
    end

    def semantic_rule_suffix(field)
      return nil unless field.start_with?('ontology.semantics.')

      parts = field.sub(/\Aontology\.semantics\./, '').split('.')
      parts[1].presence
    end

    def detail_title(field_name, category_id)
      suffix = semantic_rule_suffix(@field)
      if suffix && semantic_ontology_field?(field_name)
        check_title = Rules.semantic_check_title(suffix) || suffix.tr('_', ' ')
        return "#{field_name} — #{check_title}"
      end

      return field_name if field_name.present? && !generic_field?(field_name)

      Rules.category_summary?(category_id) ? catalog_label(category_id) : field_name
    end

    def generic_field?(field_name)
      field_name.in?(%w[file dimensions obs X validation loom file_info cross-field])
    end

    def detail_summary(field_name, category_id)
      suffix = semantic_rule_suffix(@field)
      return SEMANTIC_CHECK_SUMMARIES[suffix] if suffix && SEMANTIC_CHECK_SUMMARIES[suffix].present?

      return CATEGORY_SUMMARIES[@field] if CATEGORY_SUMMARIES[@field].present?

      if required_var_field?(field_name)
        return var_field_summary(field_name)
      end

      uns_field = uns_metadata_field_name(@field)
      if uns_field.present?
        return uns_field_summary(uns_field)
      end

      return CATEGORY_SUMMARIES[@field] if CATEGORY_SUMMARIES[@field].present?

      if required_var_field?(field_name)
        return var_field_summary(field_name)
      end

      uns_field = uns_metadata_field_name(@field)
      if uns_field.present?
        return uns_field_summary(uns_field)
      end

      return CATEGORY_SUMMARIES[category_id] if CATEGORY_SUMMARIES[category_id].present?

      if required_observation_field?(field_name)
        return "Required observation metadata field per scFAIR #{Rules.schema_version}."
      end

      if required_uns_field?(field_name)
        return "Required dataset metadata field per scFAIR #{Rules.schema_version}."
      end

      if required_observation_label?(field_name)
        return "Human-readable label paired with an ontology term field."
      end

      if enum_field?(field_name)
        return "Categorical field with a fixed set of allowed values."
      end

      if ontology_term_field?(field_name)
        return 'Ontology term identifier field validated for format, semantics, and database resolution.'
      end

      'Compliance check against the scFAIR schema.'
    end

    def yaml_check_detail_field_key
      return 'var.index.presence' if var_index_storage_path?(@field)

      @field
    end

    def yaml_checks_with_paths(checks, prefix)
      Array(checks).each_with_index.map do |check, idx|
        {
          text: check.to_s,
          from_rules: true,
          rules_path: "#{prefix}.checks.#{idx}"
        }
      end
    end

    def attach_rules_paths_to_checks(checks, prefix)
      return checks if prefix.blank?
      return checks if Array(checks).all? { |check| check.is_a?(Hash) && check[:rules_path].present? }

      Array(checks).map.with_index do |check, idx|
        next check if check.is_a?(Hash) && check[:rules_path].present?

        text = check.is_a?(Hash) ? check[:text].to_s : check.to_s
        {
          text: text,
          from_rules: true,
          rules_path: "#{prefix}.#{idx}"
        }
      end
    end

    def checks_rules_path_prefix(category_id)
      return 'check_details.spatial_rollup_checks' if @field == 'extension.spatial'

      if (uns = uns_metadata_field_name(@field)) && Rules.layer_field_checks(:uns, uns, format: @format).any?
        return "check_details.layer_field_checks.uns.#{uns}"
      end

      if (obs = obs_metadata_field_name(@field)) && obs_presence_check?(category_id) &&
         Rules.layer_field_checks(:obs, obs, format: @format).any?
        return "check_details.layer_field_checks.obs.#{obs}"
      end

      if (var = var_metadata_field_name(@field)) && Rules.layer_field_checks(:var, var, format: @format).any?
        return "check_details.layer_field_checks.var.#{var}"
      end

      if Rules.extension_field_checks(@field).any?
        return "check_details.extension_field_checks.#{@field}"
      end

      if category_id.present? && Rules.category_checks_list(category_id).any?
        return "check_details.categories.checks.#{category_id}"
      end

      nil
    end

    def yaml_check_detail_for_field
      if var_index_storage_path?(@field)
        Rules.check_detail_for_field('var.index.presence')
      else
        Rules.check_detail_for_field(@field)
      end
    end

    def append_field_constraint_rows(rows, layer, field_name)
      Rules.field_constraint_entries(layer, field_name).each_with_index do |entry, idx|
        rows << constraint_row(
          entry[:label],
          Rules.field_constraint_display_value(entry),
          from_rules: true,
          rules_path: "field_constraints.#{layer}.#{field_name}.#{idx}"
        )
      end
    end

    def append_ontology_semantics_constraint_rows(rows, suffix)
      Rules.ontology_semantics_display_constraints(suffix).each do |entry|
        rows << constraint_row(entry[:label], entry[:value], from_rules: true, rules_path: entry[:rules_path])
      end
    end

    def yaml_check_detail_for_field
      if var_index_storage_path?(@field)
        Rules.check_detail_for_field('var.index.presence')
      else
        Rules.check_detail_for_field(@field)
      end
    end

    def append_field_constraint_rows(rows, layer, field_name)
      Rules.field_constraint_entries(layer, field_name).each_with_index do |entry, idx|
        rows << constraint_row(
          entry[:label],
          Rules.field_constraint_display_value(entry),
          from_rules: true,
          rules_path: "field_constraints.#{layer}.#{field_name}.#{idx}"
        )
      end
    end

    def append_ontology_semantics_constraint_rows(rows, suffix)
      Rules.ontology_semantics_display_constraints(suffix).each do |entry|
        rows << constraint_row(entry[:label], entry[:value], from_rules: true, rules_path: entry[:rules_path])
      end
    end

    def constraint_row(label, value, from_rules: false, from_file: false, rules_path: nil)
      row = { label: label.to_s, value: value.to_s }
      if from_rules
        row[:from_rules] = true
        row[:rules_path] = rules_path.to_s if rules_path.present?
      elsif from_file
        row[:from_file] = true
        row[:rules_path] = (rules_path.presence || 'organism_specific_display.file_organism').to_s
      end
      row
    end

    def file_organism_row(organism)
      constraint_row(
        Rules.organism_specific_file_organism_label,
        organism_display_name(organism),
        from_file: true
      )
    end

    def build_constraints(field_name, category_id)
      return [] if presence_check?
      return format_check_constraints(field_name) if ontology_format_check?

      suffix = semantic_rule_suffix(@field)
      return semantic_subcheck_constraints(field_name, suffix) if suffix.present? && semantic_ontology_field?(field_name)

      rows = []

      if Rules.var_index_field?(@field) || category_id == 'var.index'
        cfg = Rules.var_index_config
        rows << { label: 'AnnData schema', value: cfg[:schema] }
        rows << { label: 'H5AD logical path', value: "#{cfg[:h5ad][:logical]} (file: #{cfg[:h5ad][:path]})" }
        rows << { label: 'Loom logical path', value: "#{cfg[:loom][:logical]} (file: #{cfg[:loom][:path]} or anndata_mapping #{cfg[:loom][:manifest_key]})" }
      end

      if category_id == 'schema.version'
        rows << constraint_row('Reference version', Rules.schema_version, from_rules: true, rules_path: 'schema.version')
        rows << constraint_row('Required identifier', Rules.schema_hash[:schema_version].to_s, from_rules: true, rules_path: 'schema.schema_version')
      end

      if category_id == 'schema.reference'
        rows << constraint_row('Reference schema URL', Rules.schema_hash[:source_url].to_s, from_rules: true, rules_path: 'schema.source_url')
      end

      append_ensembl_uns_constraints(rows, field_name) if category_id == 'uns.ensembl' || ensembl_uns_field?(field_name)
      append_uns_field_constraints(rows, field_name) if uns_metadata_field_name(@field).present?

      append_var_field_constraints(rows, field_name) if required_var_field?(field_name)

      if enum_field?(field_name) && !required_var_field?(field_name)
        rows << constraint_row(
          'Allowed values',
          Rules.enum_field_values(field_name).join(', '),
          from_rules: true,
          rules_path: "enum_fields.#{field_name}.values"
        )
      end

      ontology_cfg = Rules.ontology_field(field_name)
      if ontology_cfg.present?
        append_prefix_rows(rows, ontology_cfg, field_name: field_name)
        append_ontology_field_special_rows(rows, ontology_cfg, field_name: field_name)
      end

      semantic = Rules.semantic_rules_for(field_name)
      if semantic.present?
        append_root_rows(rows, semantic, field_name: field_name)
        banned_rule = semantic_rule_suffix(@field).in?(%w[banned_terms forbidden])
        append_forbidden_rows(rows, semantic, field_name: field_name, as_banned: banned_rule)
        append_allowed_exact_rows(rows, semantic, field_name: field_name)
        append_special_value_rows(rows, semantic, field_name: field_name)
      end

      if category_id == 'ontology.organism_specific'
        rule = @field.sub(/\Aontology\.organism_specific\./, '')
        append_organism_specific_check_constraints(rows, rule)
      end

      if category_id == 'cross-field.constraints' && field_name == 'suspension_type'
        rows << constraint_row(
          'Assay map entries',
          "#{Rules.assay_suspension_type_map.size} assay terms defined in schema",
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path('CF-1', 'mapping', 'suspension_by_assay_ontology_term_id')
        )
      end

      append_spatial_extension_constraints(rows, category_id) if category_id.to_s.start_with?('extension.spatial')
      append_metadata_other_constraints(rows) if @field.start_with?('metadata.other.')
      append_var_index_translation_constraints(rows) if var_index_storage_path?(@field)
      append_obs_label_pair_constraints(rows)
      append_cross_field_rule_constraints(rows)

      label_field = Rules.label_pairs[field_name]
      if label_field.present?
        rows << constraint_row('Paired label field', label_field, from_rules: true, rules_path: "label_pairs.#{field_name}")
      end

      rows
    end

    def semantic_subcheck_constraints(field_name, suffix)
      semantic = Rules.semantic_rules_for(field_name)
      return [] if semantic.blank?

      rows = []
      ontology_cfg = Rules.ontology_field(field_name)

      case suffix
      when 'allowed_terms', 'existence'
        append_ontology_semantics_constraint_rows(rows, 'allowed_terms')
        append_allowed_exact_rows(rows, semantic, field_name: field_name)
        append_prefix_rows(rows, ontology_cfg, field_name: field_name)
      when 'banned_terms', 'forbidden'
        append_forbidden_rows(rows, semantic, field_name: field_name, as_banned: true)
      when 'descendants'
        append_root_rows(rows, semantic, field_name: field_name)
      when 'lineage'
        if @message.match?(/must not be under/i)
          append_forbidden_rows(rows, semantic, field_name: field_name, as_banned: true)
        else
          append_root_rows(rows, semantic, field_name: field_name)
        end
      when 'sorted_multi', 'ordering'
        append_ontology_semantics_constraint_rows(rows, 'sorted_multi')
      when 'special_values', 'special_label_pair'
        append_ontology_semantics_constraint_rows(rows, 'special_values')
        append_special_value_rows(rows, semantic, field_name: field_name)
      when 'label_pair'
        label_field = Rules.label_pairs[field_name]
        if label_field.present?
          rows << constraint_row('Paired label field', label_field, from_rules: true, rules_path: "label_pairs.#{field_name}")
        end
        append_ontology_semantics_constraint_rows(rows, 'label_pair')
      end

      append_organism_specific_semantic_context(rows, field_name, suffix)

      rows
    end

    def ontology_term_field_name_from_path
      name = @field.split('/').last.to_s
      return name if semantic_ontology_field?(name) && Rules.ontology_field(name).present?

      nil
    end

    def ontology_format_checks_performed(field_name)
      cfg = Rules.ontology_field(field_name)
      return [] if cfg.blank?

      prefixes = Array(cfg[:prefixes]).map(&:to_s)
      special = Array(cfg[:special_values]).map(&:to_s)
      checks = [
        Rules.ontology_format_requirement_text(field_name),
        "Allowed ontology prefixes: #{prefixes.join(', ')}"
      ]

      if prefixes.include?('CVCL')
        checks << 'Accepts Cellosaurus CVCL_* identifiers (underscore format) in addition to PREFIX:ID terms'
      end

      if special.any?
        checks << "Allows special placeholder values: #{special.join(', ')}"
      end

      checks
    end

    def ontology_database_resolution_checks_performed(field_name)
      cfg = Rules.ontology_field(field_name)
      prefixes = Array(cfg[:prefixes]).map(&:to_s)
      label_field = Rules.label_pairs[field_name]
      checks = [
        "Each #{field_name} value is looked up in the ASAP ontology database",
        'Obsolete ontology terms are excluded from resolution (treated as not found)'
      ]
      checks << "Term must be valid for authorised ontologies: #{prefixes.join(', ')}" if prefixes.any?
      if label_field.present?
        label_path = Rules.field_path(@format, :obs, label_field)
        checks << "Paired label column #{label_path} is checked against authorised ontology names when present"
      end
      checks
    end

    def presence_checks_performed(field_name, category_id)
      return [] if field_name.blank?

      case category_id
      when 'obs.required_presence'
        obs_checks = Rules.layer_field_checks(:obs, field_name, format: @format)
        return obs_checks if obs_checks.any?

        path = Rules.field_path(@format, :obs, field_name)
        ["Verifies required observation column #{path} is present"]
      when 'uns.required_presence'
        uns_checks = Rules.layer_field_checks(:uns, field_name, format: @format)
        return uns_checks if uns_checks.any?

        path = Rules.field_path(@format, :uns, field_name)
        ["Verifies required dataset metadata field #{path} is present"]
      when 'var.required'
        path = Rules.field_path(@format, :var, field_name)
        ["Verifies required gene metadata column #{path} is present"]
      else
        []
      end
    end

    def ontology_term_field_name_from_path
      name = @field.split('/').last.to_s
      return name if semantic_ontology_field?(name) && Rules.ontology_field(name).present?

      nil
    end

    def ontology_format_checks_performed(field_name)
      cfg = Rules.ontology_field(field_name)
      return [] if cfg.blank?

      prefixes = Array(cfg[:prefixes]).map(&:to_s)
      special = Array(cfg[:special_values]).map(&:to_s)
      checks = [
        Rules.ontology_format_requirement_text(field_name),
        "Allowed ontology prefixes: #{prefixes.join(', ')}"
      ]

      if prefixes.include?('CVCL')
        checks << 'Accepts Cellosaurus CVCL_* identifiers (underscore format) in addition to PREFIX:ID terms'
      end

      if special.any?
        checks << "Allows special placeholder values: #{special.join(', ')}"
      end

      checks
    end

    def ontology_database_resolution_checks_performed(field_name)
      cfg = Rules.ontology_field(field_name)
      prefixes = Array(cfg[:prefixes]).map(&:to_s)
      label_field = Rules.label_pairs[field_name]
      checks = [
        "Each #{field_name} value is looked up in the ASAP ontology database",
        'Obsolete ontology terms are excluded from resolution (treated as not found)'
      ]
      checks << "Term must be valid for authorised ontologies: #{prefixes.join(', ')}" if prefixes.any?
      if label_field.present?
        label_path = Rules.field_path(@format, :obs, label_field)
        checks << "Paired label column #{label_path} is checked against authorised ontology names when present"
      end
      checks
    end

    def presence_checks_performed(field_name, category_id)
      return [] if field_name.blank?

      case category_id
      when 'obs.required_presence'
        path = Rules.field_path(@format, :obs, field_name)
        checks = ["Verifies required observation column #{path} is present"]
        label_field = Rules.label_pairs[field_name]
        if label_field.present?
          checks << "Paired label column #{Rules.field_path(@format, :obs, label_field)} is required for this ontology ID field"
        elsif Rules.enum_field_values(field_name).any?
          checks << "Values must be one of: #{Rules.enum_field_values(field_name).join(', ')}"
        end
        checks
      when 'uns.required_presence'
        path = Rules.field_path(@format, :uns, field_name)
        ["Verifies required dataset metadata field #{path} is present"]
      when 'var.required'
        path = Rules.field_path(@format, :var, field_name)
        ["Verifies required gene metadata column #{path} is present"]
      else
        []
      end
    end

    def semantic_checks_performed(field_name, suffix)
      semantic = Rules.semantic_rules_for(field_name) || {}

      case suffix
      when 'allowed_terms', 'existence'
        checks = [
          'Term must resolve as an active (non-obsolete) entry in the ontology database',
          'Obsolete ontology terms are treated as not found'
        ]
        checks << 'Terms in the allowed exact list satisfy this check without further lineage validation' if semantic[:allowed_exact].present?
        checks
      when 'banned_terms', 'forbidden'
        checks = []
        checks << 'Term must not match a forbidden exact identifier' if semantic[:forbidden_exact].present?
        checks << 'Term must not fall under a forbidden ontology branch' if semantic[:forbidden_branches].present?
        checks
      when 'descendants'
        roots = Array(semantic[:any_roots]).map(&:to_s)
        roots.any? ? ["Each term must descend from: #{roots.join(' or ')}"] : []
      when 'lineage'
        @message.match?(/must not be under/i) ? semantic_checks_performed(field_name, 'banned_terms') : semantic_checks_performed(field_name, 'descendants')
      when 'sorted_multi', 'ordering'
        ['Multiple values must be unique and sorted lexically with " || " separator']
      when 'special_values', 'special_label_pair'
        special = Array(semantic[:allowed_special_values]).map(&:to_s)
        special.any? ? ["Placeholder values allowed: #{special.join(', ')}"] : []
      when 'label_pair'
        label_field = Rules.label_pairs[field_name]
        checks = ['Each label must match the canonical name of its ontology term ID']
        checks << "Compared against paired field #{label_field}" if label_field.present?
        checks
      else
        []
      end
    end

    def append_root_rows(rows, semantic, field_name:)
      roots = Array(semantic[:any_roots]).map(&:to_s)
      return unless roots.any?

      rows << constraint_row(
        'Must descend from',
        roots.join(', '),
        from_rules: true,
        rules_path: "semantic_rules.#{field_name}.any_roots"
      )
    end

    def append_forbidden_rows(rows, semantic, field_name:, as_banned: false)
      branches = Array(semantic[:forbidden_branches]).map(&:to_s)
      if branches.any?
        label = as_banned ? 'Banned branches' : 'Forbidden branches'
        rows << constraint_row(
          label,
          branches.join(', '),
          from_rules: true,
          rules_path: "semantic_rules.#{field_name}.forbidden_branches"
        )
      end

      exact = Array(semantic[:forbidden_exact]).map(&:to_s)
      return unless exact.any?

      label = as_banned ? 'Banned terms' : 'Forbidden terms'
      rows << constraint_row(
        label,
        exact.join(', '),
        from_rules: true,
        rules_path: "semantic_rules.#{field_name}.forbidden_exact"
      )
    end

    def append_allowed_exact_rows(rows, semantic, field_name:)
      allowed_exact = semantic[:allowed_exact]
      rules_path = allowed_exact_rules_path(field_name)
      if allowed_exact.is_a?(Hash)
        rows << constraint_row(
          'Allowed terms',
          allowed_exact.map { |id, name| "#{id} (#{name})" }.join(', '),
          from_rules: true,
          rules_path: rules_path
        )
      elsif allowed_exact.is_a?(Array) && allowed_exact.any?
        rows << constraint_row(
          'Allowed terms',
          allowed_exact.join(', '),
          from_rules: true,
          rules_path: rules_path
        )
      end
    end

    def allowed_exact_rules_path(field_name)
      if Rules.ontology_field(field_name)[:valid_terms].present?
        "ontology_fields.#{field_name}.valid_terms"
      else
        "semantic_rules.#{field_name}.allowed_exact"
      end
    end

    def append_special_value_rows(rows, semantic, field_name:)
      special = Array(semantic[:allowed_special_values]).map(&:to_s)
      return unless special.any?

      rows << constraint_row(
        'Allowed special values',
        special.join(', '),
        from_rules: true,
        rules_path: "semantic_rules.#{field_name}.allowed_special_values"
      )
    end

    def append_ontology_field_special_rows(rows, ontology_cfg, field_name:)
      special = Array(ontology_cfg[:special_values]).map(&:to_s)
      return unless special.any?

      rows << constraint_row(
        'Special values',
        special.join(', '),
        from_rules: true,
        rules_path: "ontology_fields.#{field_name}.special_values"
      )
    end

    def append_prefix_rows(rows, ontology_cfg, field_name:)
      return if ontology_cfg.blank?

      prefixes = Array(ontology_cfg[:prefixes]).map(&:to_s)
      return unless prefixes.any?

      rows << constraint_row(
        'Allowed prefixes',
        prefixes.join(', '),
        from_rules: true,
        rules_path: "ontology_fields.#{field_name}.prefixes"
      )
    end

    def append_metadata_other_constraints(rows)
      rules = Rules.metadata_rules

      case @field
      when 'metadata.other.reserved_prefix'
        rows << constraint_row(
          'Forbidden name prefix',
          rules[:forbidden_name_prefix],
          from_rules: true,
          rules_path: 'metadata_rules.forbidden_name_prefix'
        )
        layers = %w[obs var].map { |layer| Rules.path_prefix(@format, layer.to_sym) }.join(', ')
        rows << constraint_row('Checked layers', layers, from_rules: true, rules_path: 'metadata_rules.unique_layers')
      when 'metadata.other.unique_names.obs'
        rows << constraint_row('Layer', Rules.path_prefix(@format, :obs), from_rules: true, rules_path: 'paths.obs')
        rows << constraint_row('Requirement', Rules.metadata_rules[:unique_names_requirement], from_rules: true, rules_path: 'metadata_rules.unique_names_requirement')
      when 'metadata.other.unique_names.var'
        rows << constraint_row('Layer', Rules.path_prefix(@format, :var), from_rules: true, rules_path: 'paths.var')
        rows << constraint_row('Requirement', Rules.metadata_rules[:unique_names_requirement], from_rules: true, rules_path: 'metadata_rules.unique_names_requirement')
      when 'metadata.other.deprecated'
        deprecated = rules[:deprecated_names].map do |entry|
          "#{Rules.path_prefix(@format, entry[:layer].to_sym)}/#{entry[:name]} (deprecated in #{entry[:deprecated_in]})"
        end
        rows << constraint_row(
          'Deprecated reserved names',
          deprecated.join('; '),
          from_rules: true,
          rules_path: 'metadata_rules.deprecated_names'
        )
      end
    end

    def append_metadata_other_constraints(rows)
      rules = Rules.metadata_rules

      case @field
      when 'metadata.other.reserved_prefix'
        rows << constraint_row(
          'Forbidden name prefix',
          rules[:forbidden_name_prefix],
          from_rules: true,
          rules_path: 'metadata_rules.forbidden_name_prefix'
        )
        layers = %w[obs var].map { |layer| Rules.path_prefix(@format, layer.to_sym) }.join(', ')
        rows << constraint_row('Checked layers', layers, from_rules: true, rules_path: 'metadata_rules.unique_layers')
      when 'metadata.other.unique_names.obs'
        rows << constraint_row('Layer', Rules.path_prefix(@format, :obs), from_rules: true, rules_path: 'paths.obs')
        rows << constraint_row('Requirement', Rules.metadata_rules[:unique_names_requirement], from_rules: true, rules_path: 'metadata_rules.unique_names_requirement')
      when 'metadata.other.unique_names.var'
        rows << constraint_row('Layer', Rules.path_prefix(@format, :var), from_rules: true, rules_path: 'paths.var')
        rows << constraint_row('Requirement', Rules.metadata_rules[:unique_names_requirement], from_rules: true, rules_path: 'metadata_rules.unique_names_requirement')
      when 'metadata.other.deprecated'
        deprecated = rules[:deprecated_names].map do |entry|
          "#{Rules.path_prefix(@format, entry[:layer].to_sym)}/#{entry[:name]} (deprecated in #{entry[:deprecated_in]})"
        end
        rows << constraint_row(
          'Deprecated reserved names',
          deprecated.join('; '),
          from_rules: true,
          rules_path: 'metadata_rules.deprecated_names'
        )
      end
    end

    def append_var_index_translation_constraints(rows)
      cfg = Rules.var_index_config
      rows << constraint_row(
        'AnnData schema',
        cfg[:schema],
        from_rules: true,
        rules_path: 'anndata_indices.var.schema'
      )
      rows << constraint_row(
        'H5AD file path',
        cfg[:h5ad][:path],
        from_rules: true,
        rules_path: 'anndata_indices.var.h5ad.path'
      )
      rows << constraint_row(
        'Loom file path',
        "#{cfg[:loom][:path]} (or anndata_mapping #{cfg[:loom][:manifest_key]})",
        from_rules: true,
        rules_path: 'anndata_indices.var.loom.path'
      )
    end

    def append_obs_label_pair_constraints(rows)
      prefix = Rules.label_pair_validation_config[:check_prefix]
      return unless @field.start_with?("#{prefix}.")

      id_field = @field.delete_prefix("#{prefix}.")
      label_field = Rules.label_pairs[id_field]
      return if label_field.blank?

      rows << constraint_row(
        'Paired label field',
        label_field,
        from_rules: true,
        rules_path: "label_pairs.#{id_field}"
      )
      allowed = OntologySemanticRules.allowed_special_values_for(id_field)
      if allowed.any?
        rows << constraint_row(
          'Special ID values',
          allowed.join(', '),
          from_rules: true,
          rules_path: "semantic_rules.#{id_field}.allowed_special_values"
        )
      end
    end

    def append_cross_field_rule_constraints(rows)
      return unless @field.start_with?('cross-field.CF-')

      rule_id = @field.delete_prefix('cross-field.')
      rule = Rules.cross_field_rule_by_id(rule_id)
      cell_line_rule = Rules.cross_field_cell_line_checks.find { |entry| entry[:id] == rule_id }
      if cell_line_rule
        rows << constraint_row(
          'Applies when',
          'tissue_type is "cell line"',
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(cell_line_rule[:key], 'summary')
        )
        rows << constraint_row(
          'Requirement',
          cell_line_rule[:fail].to_s,
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(cell_line_rule[:key], 'messages', 'fail')
        )
        return
      end

      if rule&.dig(:messages, 'fail').present?
        rows << constraint_row(
          'Requirement',
          rule[:messages]['fail'].to_s,
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(rule[:key], 'messages', 'fail')
        )
      end

      append_cf_rule_constraints(rows, rule)
    end

    def append_cf_rule_constraints(rows, rule)
      return if rule.blank?

      case rule[:key]
      when Rules::CF8_RULE_KEY
        rows << constraint_row(
          'Requires',
          Rules.cross_field_cf8_message('skipped_not_single'),
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(Rules::CF8_RULE_KEY, 'messages', 'skipped_not_single')
        )
        rows << constraint_row(
          'Fail condition',
          Rules.cross_field_cf8_message('fail'),
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(Rules::CF8_RULE_KEY, 'messages', 'fail')
        )
      when Rules::CF9_RULE_KEY
        spatial_root = @format == 'h5ad' ? 'uns/spatial' : '/attrs/spatial'
        rows << constraint_row(
          'Missing metadata',
          Rules.cross_field_cf9_message('fail_missing_metadata', spatial_root: spatial_root),
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(Rules::CF9_RULE_KEY, 'messages', 'fail_missing_metadata')
        )
        rows << constraint_row(
          'Unexpected metadata',
          Rules.cross_field_cf9_message('fail_metadata_without_spatial_assay', spatial_root: spatial_root),
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(Rules::CF9_RULE_KEY, 'messages', 'fail_metadata_without_spatial_assay')
        )
      end
    end

    def append_spatial_extension_constraints(rows, category_id)
      rules = Rules.spatial_extension_rules
      spatial_root = @format == 'h5ad' ? 'uns/spatial' : '/attrs/spatial'
      obsm_key = @format == 'h5ad' ? rules.dig(:obsm_spatial, :h5ad_key) : rules.dig(:obsm_spatial, :loom_key)
      image_rules = rules.dig(:images, :array) || {}
      hires_dims = rules.dig(:images, :hires_max_dimension) || {}
      spatial_category = spatial_detail_category(category_id)

      case spatial_category
      when 'extension.spatial'
        rows << constraint_row('Spatial metadata root', spatial_root)
        rows << constraint_row(
          'Sub-checks',
          rules[:display][:rollup_sub_checks],
          from_rules: true,
          rules_path: 'spatial_extension.display.rollup_sub_checks'
        )
      when 'extension.spatial.structure', 'extension.spatial.library'
        rows << constraint_row('Spatial metadata root', spatial_root)
        rows << constraint_row(
          'Library sections',
          Array(rules.dig(:library, :allowed_keys)).join(', '),
          from_rules: true,
          rules_path: 'spatial_extension.library.allowed_keys'
        )
        rows << constraint_row(
          'Required when Visium is_single',
          Array(rules.dig(:library, :required_when_visium_is_single)).join(', '),
          from_rules: true,
          rules_path: 'spatial_extension.library.required_when_visium_is_single'
        )
      when 'extension.spatial.images.hires', 'extension.spatial.images.fullres', 'extension.spatial.assets'
        append_spatial_image_constraints(rows, image_rules, hires_dims, spatial_category)
        append_spatial_obsm_constraints(rows, rules, obsm_key) if spatial_category == 'extension.spatial.assets'
      when 'extension.spatial.obsm'
        rows << constraint_row('Spatial embedding path', obsm_key, from_rules: true, rules_path: 'spatial_extension.obsm_spatial')
        append_spatial_obsm_constraints(rows, rules, obsm_key)
        rows << constraint_row(
          'Required when is_single',
          rules.dig(:obsm_spatial, :required_when_is_single) ? 'yes' : 'no',
          from_rules: true,
          rules_path: 'spatial_extension.obsm_spatial.required_when_is_single'
        )
      when 'extension.spatial.obs'
        rows << constraint_row(
          'Required columns',
          rules[:obs][:required_columns],
          from_rules: true,
          rules_path: 'spatial_extension.obs.required_columns'
        )
        rows << constraint_row(
          'Condition',
          rules[:obs][:condition],
          from_rules: true,
          rules_path: 'spatial_extension.obs.condition'
        )
      end
    end

    def append_spatial_image_constraints(rows, image_rules, hires_dims, spatial_category)
      if image_rules[:dtype].present?
        rows << constraint_row('Image dtype', image_rules[:dtype].to_s, from_rules: true, rules_path: 'spatial_extension.images.array.dtype')
      end
      if image_rules[:ndim].present?
        rows << constraint_row('Image dimensions', "#{image_rules[:ndim]}D array", from_rules: true, rules_path: 'spatial_extension.images.array.ndim')
      end
      if image_rules[:channel_sizes].present?
        rows << constraint_row(
          'Channel sizes',
          Array(image_rules[:channel_sizes]).join(' or '),
          from_rules: true,
          rules_path: 'spatial_extension.images.array.channel_sizes'
        )
      end
      return unless spatial_category.include?('hires') || spatial_category == 'extension.spatial.assets'

      default_dim = hires_dims[:default]
      display = Rules.spatial_extension_display_rules
      cytassist_assay = display[:cytassist_assay]
      cytassist_dim = hires_dims.dig(:by_assay, cytassist_assay)
      rows << constraint_row(
        'Hires max dimension',
        format(
          display[:hires_max_dimension_template],
          default: default_dim,
          assay: cytassist_assay,
          cytassist: cytassist_dim
        ),
        from_rules: true,
        rules_path: 'spatial_extension.display.hires_max_dimension_template'
      )
    end

    def append_spatial_obsm_constraints(rows, rules, obsm_key)
      rows << constraint_row('Spatial embedding path', obsm_key, from_rules: true, rules_path: 'spatial_extension.obsm_spatial')
      rows << constraint_row(
        'Minimum embedding columns',
        rules.dig(:obsm_spatial, :min_columns).to_s,
        from_rules: true,
        rules_path: 'spatial_extension.obsm_spatial.min_columns'
      )
      rows << constraint_row(
        'Embedding dtype kinds',
        Array(rules.dig(:obsm_spatial, :dtype_kinds)).join(', '),
        from_rules: true,
        rules_path: 'spatial_extension.obsm_spatial.dtype_kinds'
      )
    end

    def spatial_detail_category(category_id)
      return @field if @field.start_with?('extension.spatial.') && @field != 'extension.spatial'

      category_id
    end

    def append_organism_specific_semantic_context(rows, field_name, check_suffix)
      case field_name
      when 'self_reported_ethnicity_ontology_term_id'
        append_organism_specific_yaml_constraints(rows, field_name, check_suffix)
      when 'development_stage_ontology_term_id'
        append_organism_dev_stage_semantic_context(rows)
      when 'cell_type_ontology_term_id'
        append_organism_cell_type_semantic_context(rows)
      when 'tissue_ontology_term_id'
        append_organism_tissue_semantic_context(rows)
      when 'disease_ontology_term_id'
        rows << constraint_row(
          'Organism-specific rules',
          Rules.organism_specific_context_text(:disease_not_applicable),
          from_rules: true,
          rules_path: 'organism_specific_display.semantic_context.disease_not_applicable'
        )
      end
    end

    def append_organism_specific_yaml_constraints(rows, field_name, check_suffix)
      organism = organism_from_field_values
      term_id = organism[:term_id]

      if term_id.blank?
        append_organism_specific_yaml_entries(rows, field_name, check_suffix, :missing_organism, organism)
        return
      end

      variant = organism_specific_yaml_variant(field_name, term_id)
      return if variant.blank?

      append_organism_specific_yaml_entries(rows, field_name, check_suffix, variant, organism)
    end

    def organism_specific_yaml_variant(field_name, term_id)
      case field_name
      when 'self_reported_ethnicity_ontology_term_id'
        term_id == Rules.organism_ethnicity_human ? :human : :non_human
      end
    end

    def append_organism_specific_yaml_entries(rows, field_name, check_suffix, variant, organism)
      entries = Rules.ontology_semantics_organism_specific_entries(field_name, check_suffix, variant: variant)

      entries.each_with_index do |entry, idx|
        rules_path = organism_specific_yaml_rules_path(field_name, check_suffix, variant, idx)
        append_organism_specific_yaml_entry(rows, entry, organism, rules_path)
      end
    end

    def organism_specific_yaml_rules_path(field_name, check_suffix, variant, idx)
      base = "ontology_semantics_display.organism_specific.#{field_name}"
      if variant == :missing_organism
        "#{base}._missing_organism.#{idx}"
      else
        check_key = Rules.ontology_semantics_organism_specific_check_key(field_name, check_suffix)
        "#{base}.#{check_key}.#{variant}.#{idx}"
      end
    end

    def append_organism_specific_yaml_entry(rows, entry, organism, rules_path)
      entry = entry.deep_symbolize_keys
      return rows << file_organism_row(organism) if entry[:from_file]

      label = entry[:label].to_s
      value = if entry[:context].present?
                Rules.organism_specific_context_text(entry[:context].to_sym)
              else
                entry[:value].to_s
              end
      return if label.blank? || value.blank?

      rows << constraint_row(label, value, from_rules: true, rules_path: rules_path)
    end

    def append_organism_dev_stage_semantic_context(rows)
      organism = organism_from_field_values
      mapping = Rules.organism_dev_stage_mapping
      term_id = organism[:term_id]

      if term_id.blank?
        rows << organism_context_row('Organism-specific prefix rules', :not_applicable_no_organism)
        return
      end

      expected_prefix = mapping[term_id]
      organism_display = organism_display_name(organism)

      if expected_prefix.blank?
        rows << organism_context_row(
          'Organism-specific prefix rules',
          :not_applicable_no_dev_stage_mapping,
          organism: organism_display,
          schema_version: Rules.schema_version
        )
        return
      end

      rows << organism_context_row('Organism-specific prefix rules', :applicable_under_category)
      rows << file_organism_row(organism)
      rows << organism_context_row(
        'Required development stage prefix',
        :required_dev_stage_prefix_template,
        prefix: expected_prefix
      )
      rows << organism_context_row('Interaction with semantic rules', :interaction_semantic_dev_stage)

      prefix_status = organism_dev_stage_prefix_status(expected_prefix)
      rows << prefix_status if prefix_status
    end

    def append_organism_cell_type_semantic_context(rows)
      organism = organism_from_field_values
      term_id = organism[:term_id]

      if term_id.blank?
        rows << organism_context_row('Organism-specific prefix rules', :not_applicable_no_organism)
        return
      end

      allowed_prefixes = Rules.organism_cell_type_prefixes_for(term_id)
      mapped = Rules.organism_cell_type_mapping.key?(term_id)
      prefix_list = allowed_prefixes.map { |prefix| "#{prefix}:*" }.join(' or ')

      rows << organism_context_row('Organism-specific prefix rules', :applicable_under_category)
      rows << file_organism_row(organism)
      rows << organism_context_row('Allowed cell type prefixes', :allowed_prefixes_template, prefixes: prefix_list)
      unless mapped
        rows << organism_context_row('Schema note', :schema_note_cell_type)
      end
      rows << organism_context_row('Interaction with semantic rules', :interaction_semantic_cell_type)

      prefix_status = organism_cell_type_prefix_status(allowed_prefixes)
      rows << prefix_status if prefix_status
    end

    def append_organism_tissue_semantic_context(rows)
      organism = organism_from_field_values
      term_id = organism[:term_id]
      tissue_type = first_obs_value('tissue_type')

      if term_id.blank?
        rows << organism_context_row('Organism-specific prefix rules', :not_applicable_no_organism)
        return
      end

      if tissue_type == 'cell line'
        rows << organism_context_row('Organism-specific prefix rules', :applicable_cell_line_tissue)
        rows << file_organism_row(organism)
        rows << constraint_row(
          'Required tissue format',
          Rules.organism_specific_display_constraint(:required_tissue_format),
          from_rules: true,
          rules_path: 'organism_specific_display.constraints.required_tissue_format'
        )
        return
      end

      allowed_prefixes = tissue_type == 'primary cell culture' ? Rules.organism_cell_type_prefixes_for(term_id) : Rules.organism_tissue_prefixes_for(term_id)
      prefix_list = allowed_prefixes.map { |prefix| "#{prefix}:*" }.join(' or ')
      suffix = tissue_type == 'primary cell culture' ? Rules.organism_specific_context_text(:allowed_tissue_prefixes_primary_cell_suffix) : ''
      rows << organism_context_row('Organism-specific prefix rules', :applicable_under_category)
      rows << file_organism_row(organism)
      rows << constraint_row(
        'Allowed tissue prefixes',
        Rules.organism_specific_context_text(:allowed_prefixes_template, prefixes: prefix_list) + suffix,
        from_rules: true,
        rules_path: 'organism_specific_display.semantic_context.allowed_prefixes_template'
      )
      prefix_status = organism_tissue_prefix_status(allowed_prefixes, tissue_type)
      rows << prefix_status if prefix_status
    end

    def append_organism_ethnicity_semantic_context(rows)
      organism = organism_from_field_values
      term_id = organism[:term_id]

      if term_id.blank?
        rows << organism_context_row('Organism-specific rules', :not_applicable_no_organism)
        return
      end

      if term_id == Rules.organism_ethnicity_human
        rows << organism_context_row('Organism-specific rules', :applicable_human_ethnicity)
        rows << file_organism_row(organism)
        rows << constraint_row(
          'Requirement',
          Rules.organism_specific_display_constraint(:human_ethnicity_requirement),
          from_rules: true,
          rules_path: 'organism_specific_display.constraints.human_ethnicity_requirement'
        )
        human_specials = Rules.organism_ethnicity_human_allowed_special_values
        if human_specials.any?
          rows << constraint_row(
            'Allowed special values',
            human_specials.join(', '),
            from_rules: true,
            rules_path: Rules.organism_specific_human_ethnicity_special_values_path
          )
        end
      else
        rows << organism_context_row('Organism-specific rules', :applicable_non_human_ethnicity)
        rows << file_organism_row(organism)
        rows << constraint_row(
          'Requirement',
          Rules.organism_specific_display_constraint(:non_human_ethnicity),
          from_rules: true,
          rules_path: 'organism_specific_display.constraints.non_human_ethnicity'
        )
      end
    end

    def organism_context_row(label, key, **kwargs)
      constraint_row(
        label,
        Rules.organism_specific_context_text(key, **kwargs),
        from_rules: true,
        rules_path: "organism_specific_display.semantic_context.#{key}"
      )
    end

    def append_organism_specific_check_constraints(rows, rule)
      case rule
      when 'development_stage'
        mapping = Rules.organism_dev_stage_mapping
        rows << constraint_row(
          'Organism to stage prefix',
          mapping.map { |org, prefix| "#{org} -> #{prefix}" }.join('; '),
          from_rules: true,
          rules_path: Rules.organism_specific_mappings_yaml_path('development_stage', 'by_organism')
        )
        rows << constraint_row('Special values', 'unknown, na', from_rules: true, rules_path: 'ontology_fields.development_stage_ontology_term_id.special_values')
      when 'cell_type'
        rows << constraint_row(
          'Default prefixes',
          Rules.organism_cell_type_default_prefixes.join(', '),
          from_rules: true,
          rules_path: Rules.organism_specific_mappings_yaml_path('cell_type', 'default_prefixes')
        )
        mapped = Rules.organism_cell_type_mapping.map { |org, prefixes| "#{org} -> #{prefixes.join('/')}" }.join('; ')
        if mapped.present?
          rows << constraint_row('Model organism prefixes', mapped, from_rules: true, rules_path: Rules.organism_specific_mappings_yaml_path('cell_type', 'by_organism'))
        end
        rows << constraint_row('Special values', 'unknown, na', from_rules: true, rules_path: 'ontology_fields.cell_type_ontology_term_id.special_values')
      when 'tissue'
        rows << constraint_row(
          'Default prefixes',
          Rules.organism_tissue_default_prefixes.join(', '),
          from_rules: true,
          rules_path: Rules.organism_specific_mappings_yaml_path('tissue', 'default_prefixes')
        )
        mapped = Rules.organism_tissue_mapping.map { |org, prefixes| "#{org} -> #{prefixes.join('/')}" }.join('; ')
        if mapped.present?
          rows << constraint_row('Model organism prefixes', mapped, from_rules: true, rules_path: Rules.organism_specific_mappings_yaml_path('tissue', 'by_organism'))
        end
        rows << constraint_row(
          'Cell line tissue',
          Rules.organism_specific_display_constraint(:cell_line_tissue),
          from_rules: true,
          rules_path: 'organism_specific_display.constraints.cell_line_tissue'
        )
        rows << constraint_row(
          'Primary cell culture',
          Rules.organism_specific_display_constraint(:primary_cell_culture),
          from_rules: true,
          rules_path: 'organism_specific_display.constraints.primary_cell_culture'
        )
      when 'ethnicity'
        rows << constraint_row('Human organism', Rules.organism_ethnicity_human, from_rules: true, rules_path: Rules.organism_specific_mappings_yaml_path('ethnicity', 'human_organism'))
        rows << constraint_row(
          'Human allowed prefixes',
          Rules.organism_ethnicity_prefixes.join(', '),
          from_rules: true,
          rules_path: Rules.organism_specific_mappings_yaml_path('ethnicity', 'prefixes')
        )
        rows << constraint_row(
          'Human special values',
          Rules.organism_ethnicity_special_values.join(', '),
          from_rules: true,
          rules_path: Rules.organism_specific_mappings_yaml_path('ethnicity', 'special_values')
        )
        rows << constraint_row(
          'Non-human requirement',
          Rules.organism_specific_display_constraint(:non_human_ethnicity),
          from_rules: true,
          rules_path: 'organism_specific_display.constraints.non_human_ethnicity'
        )
      when 'sex'
        rows << constraint_row('Organism', Rules.organism_celegans_sex_organism, from_rules: true, rules_path: Rules.organism_specific_mappings_yaml_path('sex', 'celegans_organism'))
        rows << constraint_row(
          'Allowed sex terms',
          Rules.organism_celegans_sex_terms.join(', '),
          from_rules: true,
          rules_path: Rules.organism_specific_mappings_yaml_path('sex', 'celegans_terms')
        )
        rows << constraint_row('Special values', 'unknown, na', from_rules: true, rules_path: 'ontology_fields.sex_ontology_term_id.special_values')
      end
    end

    def organism_from_field_values
      term_key = Rules.field_path(@format, :uns, 'organism_ontology_term_id')
      label_key = @format == 'h5ad' ? 'uns/organism' : '/attrs/organism'
      term_id = Array(@field_values[term_key]).first.to_s.strip.presence
      label = Array(@field_values[label_key]).first.to_s.strip.presence
      { term_id: term_id, label: label }
    end

    def organism_display_name(organism)
      organism[:label].present? ? "#{organism[:label]} (#{organism[:term_id]})" : organism[:term_id].to_s
    end

    def organism_dev_stage_prefix_status(expected_prefix)
      dev_key = Rules.field_path(@format, :obs, 'development_stage_ontology_term_id')
      dev_values = split_field_values(@field_values[dev_key])
      return nil if dev_values.empty?

      invalid = dev_values.reject do |value|
        %w[unknown na].include?(value) || value.start_with?("#{expected_prefix}:")
      end

      organism_prefix_status_row(
        invalid.any? ? :prefix_status_dev_stage_unexpected : :prefix_status_dev_stage_satisfied,
        terms: invalid.uniq.first(5).join(', ')
      )
    end

    def organism_cell_type_prefix_status(allowed_prefixes)
      cell_key = Rules.field_path(@format, :obs, 'cell_type_ontology_term_id')
      cell_values = split_field_values(@field_values[cell_key])
      return nil if cell_values.empty?

      invalid = cell_values.reject do |value|
        %w[unknown na].include?(value) || allowed_prefixes.any? { |prefix| value.start_with?("#{prefix}:") }
      end

      organism_prefix_status_row(
        invalid.any? ? :prefix_status_cell_type_unexpected : :prefix_status_cell_type_satisfied,
        terms: invalid.uniq.first(5).join(', ')
      )
    end

    def organism_tissue_prefix_status(allowed_prefixes, tissue_type)
      tissue_key = Rules.field_path(@format, :obs, 'tissue_ontology_term_id')
      tissue_values = split_field_values(@field_values[tissue_key])
      return nil if tissue_values.empty?

      invalid = if tissue_type == 'cell line'
                  tissue_values.reject { |value| value.start_with?('CVCL_') }
                else
                  special = tissue_type == 'primary cell culture' ? %w[unknown na] : []
                  tissue_values.reject do |value|
                    special.include?(value) || allowed_prefixes.any? { |prefix| value.start_with?("#{prefix}:") }
                  end
                end

      organism_prefix_status_row(
        invalid.any? ? :prefix_status_tissue_unexpected : :prefix_status_tissue_satisfied,
        terms: invalid.uniq.first(5).join(', ')
      )
    end

    def organism_prefix_status_row(key, terms: '')
      value = if key.to_s.include?('unexpected')
                Rules.organism_specific_context_text(key, terms: terms)
              else
                Rules.organism_specific_context_text(key)
              end
      constraint_row('Organism-specific prefix status', value, from_rules: true, rules_path: "organism_specific_display.semantic_context.#{key}")
    end

    def first_obs_value(field_name)
      Array(@field_values[Rules.field_path(@format, :obs, field_name)]).first.to_s.strip.presence
    end

    def split_field_values(raw)
      Array(raw).flat_map { |value| value.to_s.split(' || ') }.map(&:strip).reject(&:blank?)
    end

    def presence_check?
      Rules.message_matches_pattern?(:presence, @message)
    end

    def obs_presence_check?(category_id)
      presence_check? || category_id.to_s == 'obs.required_presence'
    end

    def ontology_format_check?
      Rules.message_matches_pattern?(:ontology_format, @message)
    end

    def format_check_constraints(field_name)
      ontology_cfg = Rules.ontology_field(field_name)
      cfg = Rules.ontology_term_format_config
      rows = []

      rows << constraint_row(
        'Requirement',
        Rules.ontology_format_requirement_text(field_name),
        from_rules: true,
        rules_path: Rules.ontology_format_requirement_rules_path(field_name)
      )

      if Rules.ontology_allows_cellosaurus_format?(field_name)
        rows << constraint_row(
          'Cellosaurus format',
          cfg[:cellosaurus_requirement],
          from_rules: true,
          rules_path: 'ontology_term_formats.cellosaurus.requirement'
        )
      end

      append_prefix_rows(rows, ontology_cfg, field_name: field_name)
      append_ontology_field_special_rows(rows, ontology_cfg, field_name: field_name)
      rows
    end

    def semantic_ontology_field?(field_name)
      field_name.end_with?('_ontology_term_id')
    end

    def required_observation_field?(field_name)
      Rules.required_observation_fields.include?(field_name)
    end

    def required_observation_label?(field_name)
      Rules.required_observation_labels.include?(field_name)
    end

    def required_uns_field?(field_name)
      Rules.required_uns_fields(@format).include?(field_name) ||
        Rules.required_uns_labels.include?(field_name)
    end

    def ensembl_uns_field?(field_name)
      %w[ensembl_release ensembl_database ensembl_assembly].include?(field_name)
    end

    def uns_metadata_field_name(field)
      return nil unless field.match?(/\A(uns\/|\/attrs\/)/)

      name = field.split('/').last.to_s
      return name if required_uns_field?(name) || ensembl_uns_field?(name)

      nil
    end

    def obs_metadata_field_name(field)
      return nil unless field.match?(/\A(obs\/|\/col_attrs\/)/)

      name = field.split('/').last.to_s
      required_observation_field?(name) ? name : nil
    end

    def uns_field_summary(field_name)
      Rules.field_summary_text(:uns, field_name) || Rules.default_summary_text(:required_uns)
    end

    def append_uns_field_constraints(rows, field_name)
      case field_name
      when 'organism_ontology_term_id'
        ontology_cfg = Rules.ontology_field(field_name)
        append_prefix_rows(rows, ontology_cfg, field_name: field_name)
      when 'organism'
        rows << constraint_row('Paired term field', 'organism_ontology_term_id', from_rules: true, rules_path: 'label_pairs.organism_ontology_term_id')
        append_field_constraint_rows(rows, :uns, field_name)
      when 'schema_version'
        rows << constraint_row('Reference version', Rules.schema_version, from_rules: true, rules_path: 'schema.version')
        rows << constraint_row('Required identifier', Rules.schema_hash[:schema_version].to_s, from_rules: true, rules_path: 'schema.schema_version')
      when 'schema_reference'
        rows << constraint_row('Reference schema URL', Rules.schema_hash[:source_url].to_s, from_rules: true, rules_path: 'schema.source_url')
      end
    end

    def append_ensembl_uns_constraints(rows, field_name)
      case field_name
      when 'ensembl_database'
        rows << constraint_row(
          'Allowed values',
          Rules.ensembl_database_values.join(', '),
          from_rules: true,
          rules_path: 'constants.ensembl_database_values'
        )
      else
        append_field_constraint_rows(rows, :uns, field_name) if Rules.field_constraint_entries(:uns, field_name).any?
      end
    end

    def required_var_field?(field_name)
      Rules.required_var_fields.include?(field_name)
    end

    def var_metadata_field_name(field)
      return nil if Rules.var_index_field?(field)
      return nil unless field.match?(/\A(var\/|\/row_attrs\/)/)

      name = field.split('/').last.to_s
      required_var_field?(name) ? name : nil
    end

    def var_index_storage_path?(field)
      field.to_s == Rules.var_index_schema_field ||
        field.to_s.match?(/\A(var\/_index|var\/index|\/row_attrs\/(_index|index|feature_id))\z/)
    end

    def var_field_summary(field_name)
      Rules.field_summary_text(:var, field_name) || Rules.default_summary_text(:required_var)
    end

    def append_var_field_constraints(rows, field_name)
      append_field_constraint_rows(rows, :var, field_name)
      case field_name
      when 'feature_biotype'
        rows << constraint_row(
          'Allowed values',
          Rules.enum_field_values('feature_biotype').join(', '),
          from_rules: true,
          rules_path: 'enum_fields.feature_biotype.values'
        )
      when 'feature_reference'
        rows << constraint_row(
          'Allowed values',
          Rules.feature_reference_taxa.keys.join(', '),
          from_rules: true,
          rules_path: 'constants.feature_reference_taxa'
        )
      end
    end

    def ensembl_uns_field?(field_name)
      %w[ensembl_release ensembl_database ensembl_assembly].include?(field_name)
    end

    def uns_metadata_field_name(field)
      return nil unless field.match?(/\A(uns\/|\/attrs\/)/)

      name = field.split('/').last.to_s
      return name if required_uns_field?(name) || ensembl_uns_field?(name)

      nil
    end

    def uns_field_summary(field_name)
      case field_name
      when 'title'
        'Short human-readable dataset title required in uns metadata.'
      when 'organism_ontology_term_id'
        'Species ontology term (NCBITaxon:tax_id) identifying the dataset organism.'
      when 'organism'
        'Human-readable organism name label paired with organism_ontology_term_id.'
      when 'schema_version'
        "Schema version identifier; must be compatible with scFAIR #{Rules.schema_version}."
      when 'schema_reference'
        'Canonical URL of the scFAIR schema this file claims to follow (H5AD only).'
      when 'ensembl_release'
        'Ensembl release number used for gene annotation (positive integer).'
      when 'ensembl_database'
        'Ensembl database source used for gene annotation (Ensembl, EnsemblMetazoa, or EnsemblCOVID-19).'
      when 'ensembl_assembly'
        'Optional genome assembly name for the Ensembl annotation (non-empty when present).'
      else
        "Required dataset metadata field per scFAIR #{Rules.schema_version}."
      end
    end

    def append_uns_field_constraints(rows, field_name)
      case field_name
      when 'organism_ontology_term_id'
        ontology_cfg = Rules.ontology_field(field_name)
        append_prefix_rows(rows, ontology_cfg, field_name: field_name)
      when 'organism'
        rows << constraint_row('Paired term field', 'organism_ontology_term_id', from_rules: true, rules_path: 'label_pairs.organism_ontology_term_id')
        append_field_constraint_rows(rows, :uns, field_name)
      when 'schema_version'
        rows << constraint_row('Reference version', Rules.schema_version, from_rules: true, rules_path: 'schema.version')
        rows << constraint_row('Required identifier', Rules.schema_hash[:schema_version].to_s, from_rules: true, rules_path: 'schema.schema_version')
      when 'schema_reference'
        rows << constraint_row('Reference schema URL', Rules.schema_hash[:source_url].to_s, from_rules: true, rules_path: 'schema.source_url')
      end
    end

    def append_ensembl_uns_constraints(rows, field_name)
      case field_name
      when 'ensembl_database'
        rows << constraint_row(
          'Allowed values',
          Rules.ensembl_database_values.join(', '),
          from_rules: true,
          rules_path: 'constants.ensembl_database_values'
        )
      else
        append_field_constraint_rows(rows, :uns, field_name) if Rules.field_constraint_entries(:uns, field_name).any?
      end
    end

    def required_var_field?(field_name)
      Rules.required_var_fields.include?(field_name)
    end

    def var_metadata_field_name(field)
      return nil unless field.match?(/\A(var\/|\/row_attrs\/)/)

      name = field.split('/').last.to_s
      required_var_field?(name) ? name : nil
    end

    def var_index_storage_path?(field)
      field.to_s.match?(/\A(var\/_index|var\/index|\/row_attrs\/(_index|index|feature_id))\z/)
    end

    def var_field_summary(field_name)
      summaries = {
        'feature_is_filtered' => 'Per-gene filter flag indicating whether the feature was filtered out of the matrix.',
        'feature_biotype' => 'Gene biotype: distinguishes annotated genes from ERCC spike-in controls.',
        'feature_length' => 'Gene length in base pairs as a positive integer.',
        'feature_name' => 'Display name from the gene reference: gene_name when assigned to var index, otherwise the index identifier; spike-ins use ERCC-ID (spike-in control).',
        'feature_reference' => 'NCBITaxon term for the reference organism of the feature from the schema pinned gene annotations table.',
        'feature_type' => 'Feature type label such as protein_coding or synthetic (non-empty string).',
        'feature_chromosome' => 'Chromosome name for the feature, or na for spike-ins (non-empty string).'
      }
      summaries[field_name] || "Required variable (gene) metadata field per scFAIR #{Rules.schema_version}."
    end

    def append_var_field_constraints(rows, field_name)
      append_field_constraint_rows(rows, :var, field_name)
      case field_name
      when 'feature_biotype'
        rows << constraint_row(
          'Allowed values',
          Rules.enum_field_values('feature_biotype').join(', '),
          from_rules: true,
          rules_path: 'enum_fields.feature_biotype.values'
        )
      when 'feature_reference'
        rows << constraint_row(
          'Allowed values',
          Rules.feature_reference_taxa.keys.join(', '),
          from_rules: true,
          rules_path: 'constants.feature_reference_taxa'
        )
      end
    end

    def enum_field?(field_name)
      Rules.enum_field_values(field_name).present?
    end

    def ontology_term_field?(field_name)
      field_name.end_with?('_ontology_term_id') || field_name == 'organism'
    end
  end
end
