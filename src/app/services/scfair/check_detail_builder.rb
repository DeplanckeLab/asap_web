# frozen_string_literal: true

module Scfair
  class CheckDetailBuilder
    CROSS_FIELD_RULES = {
      'cross-field.CF-1a-ethnicity-non-human' => {
        title: 'CF-1a: Non-human ethnicity',
        summary: 'For non-human organisms, self_reported_ethnicity_ontology_term_id must be "na".'
      },
      'cross-field.CF-1b-ethnicity-human' => {
        title: 'CF-1b: Human ethnicity',
        summary: 'For Homo sapiens, self_reported_ethnicity_ontology_term_id must not be "na" (use HANCESTRO terms, "unknown", or "multiethnic").'
      },
      'cross-field.CF-2-assay-suspension' => {
        title: 'CF-2: Assay and suspension_type',
        summary: 'suspension_type must be consistent with assay_ontology_term_id according to the schema assay map.'
      },
      'cross-field.CF-3a-cell-line-ethnicity' => {
        title: 'CF-3a: Cell line ethnicity',
        summary: 'When tissue_type is "cell line", self_reported_ethnicity_ontology_term_id must be "na".'
      },
      'cross-field.CF-3b-cell-line-sex' => {
        title: 'CF-3b: Cell line sex',
        summary: 'When tissue_type is "cell line", sex_ontology_term_id must be "na".'
      },
      'cross-field.CF-3c-cell-line-development-stage' => {
        title: 'CF-3c: Cell line development stage',
        summary: 'When tissue_type is "cell line", development_stage_ontology_term_id must be "unknown".'
      },
      'cross-field.CF-3d-cell-line-donor-id' => {
        title: 'CF-3d: Cell line donor_id',
        summary: 'When tissue_type is "cell line", donor_id must be "na".'
      },
      'cross-field.CF-3e-cell-line-suspension' => {
        title: 'CF-3e: Cell line suspension_type',
        summary: 'When tissue_type is "cell line", suspension_type must be "na".'
      },
      'cross-field.CF-3f-cell-line-tissue-id' => {
        title: 'CF-3f: Cell line tissue identifier',
        summary: 'When tissue_type is "cell line", tissue_ontology_term_id should be a Cellosaurus term (CVCL_*).'
      },
      'cross-field.CF-4-donor-id' => {
        title: 'CF-4: donor_id consistency',
        summary: 'donor_id must not be "na" unless tissue_type is "cell line".'
      },
      'cross-field.CF-5-organoid-tissue' => {
        title: 'CF-5: Organoid tissue constraint',
        summary: 'When tissue_type is "organoid", tissue_ontology_term_id must not be embryo (UBERON:0000922).'
      },
      'cross-field.CF-6-spatial-assay-uniformity' => {
        title: 'CF-6: Spatial assay uniformity',
        summary: 'Spatial assay datasets (Visium, Slide-seq) must use a single assay value across all cells.'
      },
      'cross-field.CF-7-celegans-sex' => {
        title: 'CF-7: C. elegans sex constraint',
        summary: 'For C. elegans (NCBITaxon:6239), sex must be male (PATO:0000384), hermaphrodite (PATO:0001340), unknown, or na.'
      },
      'cross-field.CF-8-spatial-primary-data' => {
        title: 'CF-8: Spatial is_primary_data',
        summary: 'When spatial.is_single is false, is_primary_data must be false.'
      },
      'cross-field.CF-9-cell-line-cell-type' => {
        title: 'CF-9: Cell line cell type',
        summary: 'When tissue_type is "cell line", cell_type_ontology_term_id should be "na" or "unknown".'
      },
      'cross-field.CF-12-visium-in-tissue' => {
        title: 'CF-12: Visium in_tissue spots',
        summary: 'Visium spots with in_tissue=0 must use cell_type_ontology_term_id=unknown.'
      },
      'cross-field.constraints' => {
        title: 'Cross-field schema constraints',
        summary: 'Combined cross-field rules linking metadata fields (assay, tissue_type, organism, spatial flags, etc.).'
      }
    }.freeze

    CATEGORY_SUMMARIES = {
      'obs.required_presence' => 'Required per-cell observation metadata fields defined by scFAIR 7.1.0.',
      'uns.required_presence' => 'Required dataset-level metadata fields in uns/attrs.',
      'schema.version' => 'The file schema_version must be compatible with the reference schema version.',
      'ontology.format' => 'Ontology term identifiers must use valid OBO-style PREFIX:ID format and allowed prefixes.',
      'cross-field.constraints' => 'Metadata fields must satisfy cross-field consistency rules.',
      'ontology.database_resolution' => 'Ontology terms must resolve to known entries in the ASAP ontology database.',
      'ontology.organism_dev_stage' => 'development_stage_ontology_term_id must use the ontology prefix expected for the organism.',
      'ontology.semantics' => 'Ontology terms must satisfy semantic constraints (roots, forbidden branches, allowed values).',
      'loom.paths' => 'Required Loom HDF5 paths for observation and dataset metadata.',
      'loom.mapping_manifest' => 'The anndata_mapping manifest documents Loom to AnnData path mapping.',
      'h5ad.structure' => 'AnnData object structure (obs, var, layers) integrity checks.',
      'h5ad.embeddings' => 'Optional embedding matrices in obsm/varm/obsp/varp.',
      'h5ad.matrix_encoding' => 'Expression matrix encoding and finite numeric values.',
      'extension.spatial' => 'Spatial transcriptomics extension metadata under uns/spatial.',
      'extension.perturb' => 'Genetic perturbation extension metadata.',
      'extension.atac' => 'ATAC-seq extension metadata.',
      'extension.analysis_json' => 'analysis_json extension metadata.'
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

    def self.call(field:, message:, format:, category_id: nil)
      new(field: field, message: message, format: format, category_id: category_id).call
    end

    def self.enrich_item(item, format:, category_id: nil)
      field = (item[:field] || item['field']).to_s
      message = (item[:message] || item['message']).to_s
      detail = call(field: field, message: message, format: format, category_id: category_id)
      item.merge(detail: detail)
    end

    def initialize(field:, message:, format:, category_id: nil)
      @field = field.to_s
      @message = message.to_s
      @format = format.to_s
      @category_id = category_id.to_s.presence
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
        constraints: build_constraints(field_name, category_id),
        schema_url: Rules.schema_hash[:source_url],
        schema_version: Rules.schema_version
      }

      cross_field = CROSS_FIELD_RULES[@field]
      if cross_field
        detail[:title] = cross_field[:title]
        detail[:summary] = cross_field[:summary]
      end

      cf11 = @field.match(/\Across-field\.CF-11-(.+)\z/)
      if cf11
        id_field = cf11[1]
        label_field = Rules.label_pairs[id_field]
        detail[:title] = 'CF-11: Label and ontology ID consistency'
        detail[:summary] = "When #{id_field} is a special value (na or unknown), the paired label field #{label_field} must match."
      end

      detail
    end

    private

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

      if enum_field?(field_name)
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

      if category_id == 'ontology.organism_dev_stage'
        mapping = Rules.organism_dev_stage_mapping
        rows << {
          label: 'Organism to development stage prefix',
          value: mapping.map { |org, prefix| "#{org} -> #{prefix}" }.join('; ')
        }
      end

      if category_id == 'cross-field.constraints' && field_name == 'suspension_type'
        rows << { label: 'Assay map entries', value: "#{Rules.assay_suspension_type_map.size} assay terms defined in schema" }
      end

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

    def enum_field?(field_name)
      Rules.enum_field_values(field_name).present?
    end

    def ontology_term_field?(field_name)
      field_name.end_with?('_ontology_term_id') || field_name == 'organism'
    end
  end
end
