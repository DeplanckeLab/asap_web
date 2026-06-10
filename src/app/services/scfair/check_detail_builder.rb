# frozen_string_literal: true

module Scfair
  class CheckDetailBuilder
    CROSS_FIELD_RULES = {
      'cross-field.CF-1-assay-suspension' => {
        title: 'CF-1: Assay and suspension_type',
        summary: 'suspension_type must be consistent with assay_ontology_term_id according to the schema assay map.',
        checks: [
          'Looks up assay_ontology_term_id in the schema assay to suspension_type map',
          'Falls back to ancestor assay terms when an exact map entry is missing',
          'Fails when suspension_type is not one of the allowed values for the assay'
        ]
      },
      'cross-field.CF-2a-cell-line-ethnicity' => {
        title: 'CF-2a: Cell line ethnicity',
        summary: 'When tissue_type is "cell line", self_reported_ethnicity_ontology_term_id must be "na".'
      },
      'cross-field.CF-2b-cell-line-sex' => {
        title: 'CF-2b: Cell line sex',
        summary: 'When tissue_type is "cell line", sex_ontology_term_id must be "na".'
      },
      'cross-field.CF-2c-cell-line-development-stage' => {
        title: 'CF-2c: Cell line development stage',
        summary: 'When tissue_type is "cell line", development_stage_ontology_term_id must be "unknown".'
      },
      'cross-field.CF-2d-cell-line-donor-id' => {
        title: 'CF-2d: Cell line donor_id',
        summary: 'When tissue_type is "cell line", donor_id must be "na".'
      },
      'cross-field.CF-2e-cell-line-suspension' => {
        title: 'CF-2e: Cell line suspension_type',
        summary: 'When tissue_type is "cell line", suspension_type must be "na".'
      },
      'cross-field.CF-2f-cell-line-tissue-id' => {
        title: 'CF-2f: Cell line tissue identifier',
        summary: 'When tissue_type is "cell line", tissue_ontology_term_id should be a Cellosaurus term (CVCL_*).'
      },
      'cross-field.CF-3-donor-id' => {
        title: 'CF-3: donor_id consistency',
        summary: 'donor_id must not be "na" unless tissue_type is "cell line".'
      },
      'cross-field.CF-4-organoid-tissue' => {
        title: 'CF-4: Organoid tissue constraint',
        summary: 'When tissue_type is "organoid", tissue_ontology_term_id must not be embryo (UBERON:0000922).'
      },
      'cross-field.CF-5-spatial-assay-uniformity' => {
        title: 'CF-5: Spatial assay uniformity',
        summary: 'Spatial assay datasets (Visium, Slide-seq) must use a single assay value across all cells.',
        checks: [
          'Runs when assay_ontology_term_id is a Visium descendant (EFO:0010961) or Slide-seqV2 (EFO:0030062)',
          'Collects all unique assay values in the dataset',
          'Fails if more than one distinct assay value is present while a spatial assay is detected'
        ]
      },
      'cross-field.CF-6-spatial-primary-data' => {
        title: 'CF-6: Spatial is_primary_data',
        summary: 'When spatial.is_single is false, is_primary_data must be false.',
        checks: [
          'Reads spatial.is_single from uns/spatial (H5AD) or /attrs/spatial/is_single (Loom)',
          'Compares against is_primary_data on each observation',
          'Fails when is_single is false and is_primary_data is true'
        ]
      },
      'cross-field.CF-7-cell-line-cell-type' => {
        title: 'CF-7: Cell line cell type',
        summary: 'When tissue_type is "cell line", cell_type_ontology_term_id should be "na" or "unknown".'
      },
      'cross-field.CF-9-visium-in-tissue' => {
        title: 'CF-9: Visium in_tissue spots',
        summary: 'When spatial.is_single is true, Visium spots with in_tissue=0 must use cell_type_ontology_term_id=unknown.',
        checks: [
          'Applies to Visium assays when spatial.is_single is true',
          'Requires in_tissue observation metadata to be present',
          'When all spots are out of tissue (in_tissue=0 only), cell_type_ontology_term_id must be unknown',
          'Skipped when in_tissue mixes 0 and 1 (per-spot pairing not available in metadata summary)'
        ]
      },
      'cross-field.CF-10-spatial-metadata-presence' => {
        title: 'CF-10: Spatial metadata presence',
        summary: 'uns/spatial (or /attrs/spatial on Loom) must be present for Visium or Slide-seqV2 assays and absent otherwise.',
        checks: [
          'Reads assay_ontology_term_id and checks for Visium (EFO:0010961 descendants) or Slide-seqV2 (EFO:0030062)',
          'Detects spatial metadata from keys under uns/spatial or /attrs/spatial',
          'Fails when spatial metadata is present but the assay is not spatial',
          'Fails when the assay is spatial but spatial metadata is missing'
        ]
      }
    }.freeze

    ORGANISM_SPECIFIC_RULES = {
      'ontology.organism_specific.development_stage' => {
        title: 'Development stage ontology prefix',
        summary: 'development_stage_ontology_term_id must use the taxon-specific stage ontology prefix for the organism (e.g. HsapDv for human).'
      },
      'ontology.organism_specific.cell_type' => {
        title: 'Cell type ontology prefix',
        summary: 'cell_type_ontology_term_id must use CL or the taxon-specific cell ontology prefix for model organisms.'
      },
      'ontology.organism_specific.tissue' => {
        title: 'Tissue ontology prefix',
        summary: 'tissue_ontology_term_id must use UBERON, Cellosaurus (cell lines), or taxon-specific anatomy prefixes for model organisms.'
      },
      'ontology.organism_specific.ethnicity' => {
        title: 'Ethnicity vs organism',
        summary: 'Non-human datasets must use ethnicity "na"; Homo sapiens must use HANCESTRO/AfPO terms (not "na").'
      },
      'ontology.organism_specific.sex' => {
        title: 'C. elegans sex terms',
        summary: 'For Caenorhabditis elegans, sex_ontology_term_id must be male, hermaphrodite, unknown, or na.'
      }
    }.freeze

    CATEGORY_SUMMARIES = {
      'obs.required_presence' => 'Required per-cell observation metadata fields defined by scFAIR 7.1.0.',
      'uns.required_presence' => 'Required dataset-level metadata fields in uns/attrs.',
      'schema.version' => 'The file schema_version must be compatible with the reference schema version.',
      'schema.reference' => 'The file schema_reference should match the canonical URL of the reference schema.',
      'uns.ensembl' => 'Ensembl release, database, and optional assembly used for gene annotation.',
      'obs.experimental_condition' => 'Experimental condition ontology IDs, labels, and perturbation types.',
      'var.required' => 'Required per-gene metadata columns in var / row_attrs.',
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
        'Each required dataset metadata field is present in uns (H5AD) or /attrs (Loom)',
        'Common fields: title, organism_ontology_term_id, organism label, schema_version',
        'Common fields include ensembl_release and ensembl_database; H5AD-only: schema_reference'
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
        'ensembl_release and ensembl_database presence use uns/ or /attrs/ field paths',
        'Value checks use uns.ensembl.release, uns.ensembl.database, and uns.ensembl.assembly',
        'ensembl_release must be a positive integer; ensembl_database must be Ensembl, EnsemblMetazoa, or EnsemblCOVID-19',
        'ensembl_assembly is optional; when present it must be a non-empty string'
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
        'Values must be a non-empty string (gene symbol or spike-in name)'
      ],
      'feature_reference' => [
        'Column must be present in var (H5AD) or row_attrs (Loom)',
        'Values must be a schema NCBITaxon identifier for the reference genome or spike-in mix'
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
      'allowed_terms' => 'Each term must resolve in the ontology database and match any allowed exact values.',
      'existence' => 'The term must exist in the ontology database.',
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

      cross_field = CROSS_FIELD_RULES[@field]
      if cross_field
        detail[:title] = cross_field[:title]
        detail[:summary] = cross_field[:summary]
        detail[:checks_performed] = cross_field[:checks] if cross_field[:checks].present?
      end

      organism_rule = ORGANISM_SPECIFIC_RULES[@field]
      if organism_rule
        detail[:title] = organism_rule[:title]
        detail[:summary] = organism_rule[:summary]
      end

      cf8 = @field.match(/\Across-field\.CF-8-(.+)\z/)
      if cf8
        id_field = cf8[1]
        label_field = Rules.label_pairs[id_field]
        detail[:title] = 'CF-8: Label and ontology ID consistency'
        detail[:summary] = "When #{id_field} is a special value (na or unknown), the paired label field #{label_field} must match."
      end

      if METADATA_OTHER_TITLES[@field]
        detail[:title] = METADATA_OTHER_TITLES[@field]
        detail[:summary] = CATEGORY_SUMMARIES[@field]
      end

      detail
    end

    private

    def checks_performed(category_id)
      return SPATIAL_ROLLUP_CHECKS if @field == 'extension.spatial'
      return METADATA_OTHER_CHECKS[@field] if METADATA_OTHER_CHECKS[@field].present?
      return FIELD_CHECKS[@field] if FIELD_CHECKS[@field].present?

      var_field = var_metadata_field_name(@field)
      return VAR_FIELD_CHECKS[var_field] if var_field.present?

      CATEGORY_CHECKS[category_id] || []
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
        check_title = SEMANTIC_CHECK_TITLES[suffix] || suffix.tr('_', ' ')
        return "#{field_name} — #{check_title}"
      end

      return field_name if field_name.present? && !generic_field?(field_name)

      CATEGORY_SUMMARIES[category_id] ? catalog_label(category_id) : field_name
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

    def build_constraints(field_name, category_id)
      return [] if presence_check?
      return format_check_constraints(field_name) if ontology_format_check?

      suffix = semantic_rule_suffix(@field)
      return semantic_subcheck_constraints(field_name, suffix) if suffix.present? && semantic_ontology_field?(field_name)

      rows = []

      if category_id == 'schema.version'
        rows << { label: 'Reference version', value: Rules.schema_version }
        rows << { label: 'Required identifier', value: Rules.schema_hash[:schema_version].to_s }
      end

      if category_id == 'schema.reference'
        rows << { label: 'Reference schema URL', value: Rules.schema_hash[:source_url].to_s }
      end

      if category_id == 'uns.ensembl'
        rows << { label: 'ensembl_release', value: 'Positive integer (e.g. 115)' }
        rows << { label: 'ensembl_database', value: Rules.ensembl_database_values.join(', ') }
        rows << { label: 'ensembl_assembly', value: 'Optional non-empty string (e.g. GRCh38.p14)' }
      end

      append_var_field_constraints(rows, field_name) if required_var_field?(field_name)

      if enum_field?(field_name) && !required_var_field?(field_name)
        rows << { label: 'Allowed values', value: Rules.enum_field_values(field_name).join(', ') }
      end

      ontology_cfg = Rules.ontology_field(field_name)
      if ontology_cfg.present?
        prefixes = Array(ontology_cfg[:prefixes]).map(&:to_s)
        rows << { label: 'Allowed prefixes', value: prefixes.join(', ') } if prefixes.any?

        special = Array(ontology_cfg[:special_values]).map(&:to_s)
        rows << { label: 'Special values', value: special.join(', ') } if special.any?
      end

      semantic = Rules.semantic_rules_for(field_name)
      if semantic.present?
        roots = Array(semantic[:any_roots]).map(&:to_s)
        rows << { label: 'Must descend from', value: roots.join(', ') } if roots.any?

        forbidden_branches = Array(semantic[:forbidden_branches]).map(&:to_s)
        forbidden_exact = Array(semantic[:forbidden_exact]).map(&:to_s)
        banned_rule = semantic_rule_suffix(@field).in?(%w[banned_terms forbidden])

        if forbidden_branches.any?
          label = banned_rule ? 'Banned branches' : 'Forbidden branches'
          rows << { label: label, value: forbidden_branches.join(', ') }
        end

        if forbidden_exact.any?
          label = banned_rule ? 'Banned terms' : 'Forbidden terms'
          rows << { label: label, value: forbidden_exact.join(', ') }
        end

        allowed_exact = semantic[:allowed_exact]
        if allowed_exact.is_a?(Hash)
          rows << { label: 'Allowed terms', value: allowed_exact.keys.join(', ') }
        elsif allowed_exact.is_a?(Array) && allowed_exact.any?
          rows << { label: 'Allowed terms', value: allowed_exact.join(', ') }
        end

        allowed_special = Array(semantic[:allowed_special_values]).map(&:to_s)
        rows << { label: 'Allowed special values', value: allowed_special.join(', ') } if allowed_special.any?
      end

      if category_id == 'ontology.organism_specific'
        rule = @field.sub(/\Aontology\.organism_specific\./, '')
        append_organism_specific_check_constraints(rows, rule)
      end

      if category_id == 'cross-field.constraints' && field_name == 'suspension_type'
        rows << { label: 'Assay map entries', value: "#{Rules.assay_suspension_type_map.size} assay terms defined in schema" }
      end

      append_spatial_extension_constraints(rows, category_id) if category_id.to_s.start_with?('extension.spatial')
      append_metadata_other_constraints(rows) if @field.start_with?('metadata.other.')

      label_field = Rules.label_pairs[field_name]
      rows << { label: 'Paired label field', value: label_field } if label_field.present?

      rows
    end

    def semantic_subcheck_constraints(field_name, suffix)
      semantic = Rules.semantic_rules_for(field_name)
      return [] if semantic.blank?

      rows = []
      ontology_cfg = Rules.ontology_field(field_name)

      case suffix
      when 'allowed_terms', 'existence'
        rows << { label: 'Requirement', value: 'Each term must resolve in the ontology database' }
        append_allowed_exact_rows(rows, semantic)
        append_prefix_rows(rows, ontology_cfg)
      when 'banned_terms', 'forbidden'
        append_banned_rows(rows, semantic)
      when 'descendants'
        append_root_rows(rows, semantic)
      when 'lineage'
        if @message.match?(/must not be under/i)
          append_banned_rows(rows, semantic)
        else
          append_root_rows(rows, semantic)
        end
      when 'sorted_multi', 'ordering'
        rows << { label: 'Requirement', value: 'Values must be unique and sorted lexically, joined with " || "' }
      when 'special_values', 'special_label_pair'
        append_special_value_rows(rows, semantic)
      when 'label_pair'
        label_field = Rules.label_pairs[field_name]
        rows << { label: 'Paired label field', value: label_field } if label_field.present?
        rows << { label: 'Requirement', value: 'Each label must match the canonical name of its ontology term ID' }
      end

      append_organism_specific_semantic_context(rows, field_name)

      rows
    end

    def append_root_rows(rows, semantic)
      roots = Array(semantic[:any_roots]).map(&:to_s)
      rows << { label: 'Must descend from', value: roots.join(', ') } if roots.any?
    end

    def append_banned_rows(rows, semantic)
      branches = Array(semantic[:forbidden_branches]).map(&:to_s)
      rows << { label: 'Banned branches', value: branches.join(', ') } if branches.any?

      exact = Array(semantic[:forbidden_exact]).map(&:to_s)
      rows << { label: 'Banned terms', value: exact.join(', ') } if exact.any?
    end

    def append_allowed_exact_rows(rows, semantic)
      allowed_exact = semantic[:allowed_exact]
      if allowed_exact.is_a?(Hash)
        rows << { label: 'Allowed terms', value: allowed_exact.keys.join(', ') }
      elsif allowed_exact.is_a?(Array) && allowed_exact.any?
        rows << { label: 'Allowed terms', value: allowed_exact.join(', ') }
      end
    end

    def append_special_value_rows(rows, semantic)
      special = Array(semantic[:allowed_special_values]).map(&:to_s)
      rows << { label: 'Allowed special values', value: special.join(', ') } if special.any?
    end

    def append_prefix_rows(rows, ontology_cfg)
      return if ontology_cfg.blank?

      prefixes = Array(ontology_cfg[:prefixes]).map(&:to_s)
      rows << { label: 'Allowed prefixes', value: prefixes.join(', ') } if prefixes.any?
    end

    def append_metadata_other_constraints(rows)
      rules = Rules.metadata_rules

      case @field
      when 'metadata.other.reserved_prefix'
        rows << { label: 'Forbidden name prefix', value: rules[:forbidden_name_prefix] }
        layers = %w[obs var].map { |layer| Rules.path_prefix(@format, layer.to_sym) }.join(', ')
        rows << { label: 'Checked layers', value: layers }
      when 'metadata.other.unique_names.obs'
        rows << { label: 'Layer', value: Rules.path_prefix(@format, :obs) }
        rows << { label: 'Requirement', value: 'Metadata field names must be unique' }
      when 'metadata.other.unique_names.var'
        rows << { label: 'Layer', value: Rules.path_prefix(@format, :var) }
        rows << { label: 'Requirement', value: 'Metadata field names must be unique' }
      when 'metadata.other.deprecated'
        deprecated = rules[:deprecated_names].map do |entry|
          "#{Rules.path_prefix(@format, entry[:layer].to_sym)}/#{entry[:name]} (deprecated in #{entry[:deprecated_in]})"
        end
        rows << { label: 'Deprecated reserved names', value: deprecated.join('; ') }
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
        rows << { label: 'Spatial metadata root', value: spatial_root }
        rows << { label: 'Sub-checks', value: 'structure, obs, assets' }
      when 'extension.spatial.structure', 'extension.spatial.library'
        rows << { label: 'Spatial metadata root', value: spatial_root }
        rows << { label: 'Library sections', value: Array(rules.dig(:library, :allowed_keys)).join(', ') }
        rows << { label: 'Required when Visium is_single', value: Array(rules.dig(:library, :required_when_visium_is_single)).join(', ') }
      when 'extension.spatial.images.hires', 'extension.spatial.images.fullres', 'extension.spatial.assets'
        append_spatial_image_constraints(rows, image_rules, hires_dims, spatial_category)
        append_spatial_obsm_constraints(rows, rules, obsm_key) if spatial_category == 'extension.spatial.assets'
      when 'extension.spatial.obsm'
        rows << { label: 'Spatial embedding path', value: obsm_key }
        append_spatial_obsm_constraints(rows, rules, obsm_key)
        rows << { label: 'Required when is_single', value: rules.dig(:obsm_spatial, :required_when_is_single) ? 'yes' : 'no' }
      when 'extension.spatial.obs'
        rows << { label: 'Required columns', value: 'array_row, array_col, in_tissue' }
        rows << { label: 'Condition', value: 'Visium assay with spatial.is_single=true' }
      end
    end

    def append_spatial_image_constraints(rows, image_rules, hires_dims, spatial_category)
      rows << { label: 'Image dtype', value: image_rules[:dtype].to_s } if image_rules[:dtype].present?
      rows << { label: 'Image dimensions', value: "#{image_rules[:ndim]}D array" } if image_rules[:ndim].present?
      rows << { label: 'Channel sizes', value: Array(image_rules[:channel_sizes]).join(' or ') } if image_rules[:channel_sizes].present?
      return unless spatial_category.include?('hires') || spatial_category == 'extension.spatial.assets'

      default_dim = hires_dims[:default]
      cytassist_dim = hires_dims.dig(:by_assay, 'EFO:0022860')
      rows << { label: 'Hires max dimension', value: "#{default_dim} px (CytAssist 11mm EFO:0022860: #{cytassist_dim} px)" }
    end

    def append_spatial_obsm_constraints(rows, rules, obsm_key)
      rows << { label: 'Spatial embedding path', value: obsm_key }
      rows << { label: 'Minimum embedding columns', value: rules.dig(:obsm_spatial, :min_columns).to_s }
      rows << { label: 'Embedding dtype kinds', value: Array(rules.dig(:obsm_spatial, :dtype_kinds)).join(', ') }
    end

    def spatial_detail_category(category_id)
      return @field if @field.start_with?('extension.spatial.') && @field != 'extension.spatial'

      category_id
    end

    def append_organism_specific_semantic_context(rows, field_name)
      case field_name
      when 'development_stage_ontology_term_id'
        append_organism_dev_stage_semantic_context(rows)
      when 'cell_type_ontology_term_id'
        append_organism_cell_type_semantic_context(rows)
      when 'tissue_ontology_term_id'
        append_organism_tissue_semantic_context(rows)
      when 'self_reported_ethnicity_ontology_term_id'
        append_organism_ethnicity_semantic_context(rows)
      when 'disease_ontology_term_id'
        rows << {
          label: 'Organism-specific rules',
          value: 'Not applicable — disease_ontology_term_id uses the same MONDO and PATO:0000461 requirements for all organisms'
        }
      end
    end

    def append_organism_dev_stage_semantic_context(rows)
      organism = organism_from_field_values
      mapping = Rules.organism_dev_stage_mapping
      term_id = organism[:term_id]

      if term_id.blank?
        rows << {
          label: 'Organism-specific prefix rules',
          value: 'Not applicable — organism_ontology_term_id is not set in this file'
        }
        return
      end

      expected_prefix = mapping[term_id]
      organism_display = organism_display_name(organism)

      if expected_prefix.blank?
        rows << {
          label: 'Organism-specific prefix rules',
          value: "Not applicable — #{organism_display} has no mapped development stage prefix in scFAIR #{Rules.schema_version}"
        }
        return
      end

      rows << {
        label: 'Organism-specific prefix rules',
        value: 'Applicable — validated under "Organism-specific constraints"'
      }
      rows << { label: 'File organism', value: organism_display }
      rows << {
        label: 'Required development stage prefix',
        value: "#{expected_prefix}:* (special values unknown and na are also allowed)"
      }
      rows << {
        label: 'Interaction with semantic rules',
        value: 'Prefix requirements apply in addition to the semantic constraints above; both must pass for real ontology terms'
      }

      prefix_status = organism_dev_stage_prefix_status(expected_prefix)
      rows << prefix_status if prefix_status
    end

    def append_organism_cell_type_semantic_context(rows)
      organism = organism_from_field_values
      term_id = organism[:term_id]

      if term_id.blank?
        rows << {
          label: 'Organism-specific prefix rules',
          value: 'Not applicable — organism_ontology_term_id is not set in this file'
        }
        return
      end

      allowed_prefixes = Rules.organism_cell_type_prefixes_for(term_id)
      organism_display = organism_display_name(organism)
      mapped = Rules.organism_cell_type_mapping.key?(term_id)

      rows << {
        label: 'Organism-specific prefix rules',
        value: 'Applicable — validated under "Organism-specific constraints"'
      }
      rows << { label: 'File organism', value: organism_display }
      rows << {
        label: 'Allowed cell type prefixes',
        value: "#{allowed_prefixes.map { |prefix| "#{prefix}:*" }.join(' or ')} (special values unknown and na are also allowed)"
      }
      unless mapped
        rows << {
          label: 'Schema note',
          value: 'For this organism, scFAIR expects CL terms or taxon-neutral descendants of CL:0000000'
        }
      end
      rows << {
        label: 'Interaction with semantic rules',
        value: 'Prefix requirements apply in addition to descendant, banned-term, and other semantic constraints above'
      }

      prefix_status = organism_cell_type_prefix_status(allowed_prefixes)
      rows << prefix_status if prefix_status
    end

    def append_organism_tissue_semantic_context(rows)
      organism = organism_from_field_values
      term_id = organism[:term_id]
      tissue_type = first_obs_value('tissue_type')

      if term_id.blank?
        rows << { label: 'Organism-specific prefix rules', value: 'Not applicable — organism_ontology_term_id is not set in this file' }
        return
      end

      organism_display = organism_display_name(organism)
      if tissue_type == 'cell line'
        rows << { label: 'Organism-specific prefix rules', value: 'Applicable — cell line tissue must use Cellosaurus CVCL_* terms' }
        rows << { label: 'File organism', value: organism_display }
        rows << { label: 'Required tissue format', value: 'CVCL_* (Cellosaurus)' }
        return
      end

      allowed_prefixes = tissue_type == 'primary cell culture' ? Rules.organism_cell_type_prefixes_for(term_id) : Rules.organism_tissue_prefixes_for(term_id)
      rows << { label: 'Organism-specific prefix rules', value: 'Applicable — validated under "Organism-specific constraints"' }
      rows << { label: 'File organism', value: organism_display }
      rows << {
        label: 'Allowed tissue prefixes',
        value: "#{allowed_prefixes.map { |prefix| "#{prefix}:*" }.join(' or ')}#{tissue_type == 'primary cell culture' ? ' (primary cell culture follows cell type rules)' : ''}"
      }
      prefix_status = organism_tissue_prefix_status(allowed_prefixes, tissue_type)
      rows << prefix_status if prefix_status
    end

    def append_organism_ethnicity_semantic_context(rows)
      organism = organism_from_field_values
      term_id = organism[:term_id]

      if term_id.blank?
        rows << { label: 'Organism-specific rules', value: 'Not applicable — organism_ontology_term_id is not set in this file' }
        return
      end

      organism_display = organism_display_name(organism)
      if term_id == Rules.organism_ethnicity_human
        rows << { label: 'Organism-specific rules', value: 'Applicable — Homo sapiens ethnicity constraints' }
        rows << { label: 'File organism', value: organism_display }
        rows << { label: 'Requirement', value: 'Must not be "na"; use HANCESTRO/AfPO terms, "unknown", or "multiethnic"' }
      else
        rows << { label: 'Organism-specific rules', value: 'Applicable — non-human ethnicity must be "na"' }
        rows << { label: 'File organism', value: organism_display }
        rows << { label: 'Requirement', value: 'self_reported_ethnicity_ontology_term_id must be "na"' }
      end
    end

    def append_organism_specific_check_constraints(rows, rule)
      case rule
      when 'development_stage'
        mapping = Rules.organism_dev_stage_mapping
        rows << { label: 'Organism to stage prefix', value: mapping.map { |org, prefix| "#{org} -> #{prefix}" }.join('; ') }
        rows << { label: 'Special values', value: 'unknown, na' }
      when 'cell_type'
        rows << { label: 'Default prefixes', value: Rules.organism_cell_type_default_prefixes.join(', ') }
        mapped = Rules.organism_cell_type_mapping.map { |org, prefixes| "#{org} -> #{prefixes.join('/')}" }.join('; ')
        rows << { label: 'Model organism prefixes', value: mapped } if mapped.present?
        rows << { label: 'Special values', value: 'unknown, na' }
      when 'tissue'
        rows << { label: 'Default prefixes', value: Rules.organism_tissue_default_prefixes.join(', ') }
        mapped = Rules.organism_tissue_mapping.map { |org, prefixes| "#{org} -> #{prefixes.join('/')}" }.join('; ')
        rows << { label: 'Model organism prefixes', value: mapped } if mapped.present?
        rows << { label: 'Cell line tissue', value: 'Must use Cellosaurus CVCL_* terms' }
        rows << { label: 'Primary cell culture', value: 'Follows cell_type_ontology_term_id prefix rules' }
      when 'ethnicity'
        rows << { label: 'Human organism', value: Rules.organism_ethnicity_human }
        rows << { label: 'Human allowed prefixes', value: Rules.organism_ethnicity_prefixes.join(', ') }
        rows << { label: 'Human special values', value: Rules.organism_ethnicity_special_values.join(', ') }
        rows << { label: 'Non-human requirement', value: 'self_reported_ethnicity_ontology_term_id must be "na"' }
      when 'sex'
        rows << { label: 'Organism', value: Rules.organism_celegans_sex_organism }
        rows << { label: 'Allowed sex terms', value: Rules.organism_celegans_sex_terms.join(', ') }
        rows << { label: 'Special values', value: 'unknown, na' }
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

      if invalid.any?
        {
          label: 'Organism-specific prefix status',
          value: "Not satisfied — unexpected terms: #{invalid.uniq.first(5).join(', ')}"
        }
      else
        {
          label: 'Organism-specific prefix status',
          value: 'Satisfied by current development_stage_ontology_term_id values'
        }
      end
    end

    def organism_cell_type_prefix_status(allowed_prefixes)
      cell_key = Rules.field_path(@format, :obs, 'cell_type_ontology_term_id')
      cell_values = split_field_values(@field_values[cell_key])
      return nil if cell_values.empty?

      invalid = cell_values.reject do |value|
        %w[unknown na].include?(value) || allowed_prefixes.any? { |prefix| value.start_with?("#{prefix}:") }
      end

      if invalid.any?
        {
          label: 'Organism-specific prefix status',
          value: "Not satisfied — unexpected terms: #{invalid.uniq.first(5).join(', ')}"
        }
      else
        {
          label: 'Organism-specific prefix status',
          value: 'Satisfied by current cell_type_ontology_term_id values'
        }
      end
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

      if invalid.any?
        { label: 'Organism-specific prefix status', value: "Not satisfied — unexpected terms: #{invalid.uniq.first(5).join(', ')}" }
      else
        { label: 'Organism-specific prefix status', value: 'Satisfied by current tissue_ontology_term_id values' }
      end
    end

    def first_obs_value(field_name)
      Array(@field_values[Rules.field_path(@format, :obs, field_name)]).first.to_s.strip.presence
    end

    def split_field_values(raw)
      Array(raw).flat_map { |value| value.to_s.split(' || ') }.map(&:strip).reject(&:blank?)
    end

    def presence_check?
      @message.match?(PRESENCE_CHECK)
    end

    def ontology_format_check?
      @message.match?(ONTOLOGY_FORMAT_CHECK)
    end

    def format_check_constraints(field_name)
      ontology_cfg = Rules.ontology_field(field_name)
      prefixes = Array(ontology_cfg[:prefixes]).map(&:to_s)
      rows = []

      if prefixes.include?('CVCL')
        rows << {
          label: 'Requirement',
          value: 'Terms must use OBO-style PREFIX:ID (e.g. CL:0000540), or Cellosaurus CVCL_* identifiers (e.g. CVCL_1P02)'
        }
        rows << {
          label: 'Cellosaurus format',
          value: 'CVCL_* with underscore separator (not PREFIX:ID)'
        }
      else
        rows << { label: 'Requirement', value: 'Terms must use OBO-style PREFIX:ID format (e.g. CL:0000540)' }
      end

      append_prefix_rows(rows, ontology_cfg)
      if ontology_cfg.present?
        special = Array(ontology_cfg[:special_values]).map(&:to_s)
        rows << { label: 'Special values', value: special.join(', ') } if special.any?
      end
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

    def required_var_field?(field_name)
      Rules.required_var_fields.include?(field_name)
    end

    def var_metadata_field_name(field)
      return nil unless field.match?(/\A(var\/|\/row_attrs\/)/)

      name = field.split('/').last.to_s
      required_var_field?(name) ? name : nil
    end

    def var_field_summary(field_name)
      summaries = {
        'feature_is_filtered' => 'Per-gene filter flag indicating whether the feature was filtered out of the matrix.',
        'feature_biotype' => 'Gene biotype: distinguishes annotated genes from ERCC spike-in controls.',
        'feature_length' => 'Gene length in base pairs as a positive integer.',
        'feature_name' => 'Gene symbol or spike-in control name (non-empty string).',
        'feature_reference' => 'NCBITaxon identifier for the reference genome or spike-in mix used for this feature.',
        'feature_type' => 'Feature type label such as protein_coding or synthetic (non-empty string).',
        'feature_chromosome' => 'Chromosome name for the feature, or na for spike-ins (non-empty string).'
      }
      summaries[field_name] || "Required variable (gene) metadata field per scFAIR #{Rules.schema_version}."
    end

    def append_var_field_constraints(rows, field_name)
      case field_name
      when 'feature_is_filtered'
        rows << { label: 'Allowed values', value: 'true, false, True, False' }
      when 'feature_biotype'
        rows << { label: 'Allowed values', value: Rules.enum_field_values('feature_biotype').join(', ') }
      when 'feature_length'
        rows << { label: 'Requirement', value: 'Positive integer (uint)' }
      when 'feature_reference'
        rows << { label: 'Allowed values', value: Rules.feature_reference_taxa.keys.join(', ') }
      when 'feature_name', 'feature_type', 'feature_chromosome'
        rows << { label: 'Requirement', value: 'Non-empty string per gene or feature' }
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
