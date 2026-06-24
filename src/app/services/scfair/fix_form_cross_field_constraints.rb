# frozen_string_literal: true

module Scfair
  # Builds cross-field constraint payloads for the compliance fix form from rules.yaml.
  class FixFormCrossFieldConstraints
    LOOM_PREFIX = '/col_attrs/'

    def self.build(project:, fixable_groups:)
      new(project: project, fixable_groups: fixable_groups).build
    end

    def initialize(project:, fixable_groups:)
      @project = project
      @fixable_groups = Array(fixable_groups)
      @groups_by_id = {}
      @group_id_by_obs_field = {}
      index_groups!
    end

    def build
      {
        'multi_value' => multi_value_config,
        'static' => static_constraints,
        'cell_line' => cell_line_config,
        'assay_suspension' => assay_suspension_config,
        'tissue_type_tissue' => tissue_type_tissue_config
      }
    end

    def multi_value_config
      cfg = Rules.multi_value_fields_config
      by_group_id = {}
      @fixable_groups.each do |fg|
        g = fg[:group]
        field = Rules.obs_field_name_from_path(g[:term_path])
        next if field.blank?
        next unless Rules.multi_value_field?(field)

        field_cfg = cfg[:fields][field] || {}
        by_group_id[g[:id].to_s] = {
          'obs_field' => field,
          'sorted' => Rules.multi_value_sorted_field?(field),
          'paired_label' => field_cfg[:paired_label].to_s.presence
        }.compact
      end

      {
        'delimiter' => Rules.multi_value_delimiter,
        'requirement' => format(cfg[:requirement], delimiter: Rules.multi_value_delimiter.strip),
        'by_group_id' => by_group_id
      }
    end

    private

    def index_groups!
      @fixable_groups.each do |fg|
        g = fg[:group]
        id = g[:id].to_s
        @groups_by_id[id] = g
        term_field = Rules.obs_field_name_from_path(g[:term_path])
        @group_id_by_obs_field[term_field] = id if term_field.present?
        next if g[:label_path].blank?

        label_field = Rules.obs_field_name_from_path(g[:label_path])
        @group_id_by_obs_field[label_field] = id if label_field.present?
      end
    end

    def static_constraints
      constraints = {}
      organism = @project.organism
      human_term = Rules.organism_ethnicity_human
      project_term = organism ? "NCBITaxon:#{organism.tax_id}" : nil
      return constraints if project_term == human_term

      group_id = resolve_group_id_for_obs_field('self_reported_ethnicity_ontology_term_id') || 'self_reported_ethnicity'
      paths = group_paths(group_id)
      organism_label = organism ? "Organism is #{organism.name} (not Homo sapiens)" : 'Organism is not Homo sapiens'
      ethnicity_rule = Rules.organism_specific_display_constraint(:non_human_ethnicity)

      constraints[group_id] = {
        'forced_term_value' => 'na',
        'forced_label_value' => 'na',
        'reason' => "#{organism_label} -- #{ethnicity_rule}",
        'dependent_on' => 'organism',
        'term_path' => paths[:term_path],
        'label_path' => paths[:label_path]
      }.compact
      constraints
    end

    def cell_line_config
      trigger = Rules.tissue_type_cell_line_value
      forced_fields = Rules.cell_line_forced_fields.map { |entry| build_forced_field(entry) }

      cf2f = Rules.cross_field_rule_by_key('CF-2f')
      tissue_group_id = resolve_group_id_for_obs_field('tissue_ontology_term_id') || 'tissue'
      tissue_note = {
        'group_id' => tissue_group_id,
        'message' => "Note: tissue_type is \"#{trigger}\".",
        'detail' => cf2f&.dig(:messages, 'skip_detail').presence || cf2f&.dig(:summary).to_s
      }

      affected_group_ids = (forced_fields.map { |f| f['group_id'] } + [tissue_group_id]).uniq

      {
        'trigger_value' => trigger,
        'reason' => cell_line_reason(trigger),
        'forced_fields' => forced_fields,
        'tissue_note' => tissue_note,
        'affected_group_ids' => affected_group_ids
      }
    end

    def build_forced_field(entry)
      field = entry[:field].to_s
      group_id = resolve_group_id_for_obs_field(field) || field.sub(/_ontology_term_id\z/, '')
      paths = group_paths(group_id)
      term_path = paths[:term_path].presence || "#{LOOM_PREFIX}#{field}"

      result = {
        'group_id' => group_id,
        'term_path' => term_path,
        'term_value' => entry[:value].to_s
      }

      label_field = entry[:label_field].to_s.presence
      if label_field
        result['label_path'] = paths[:label_path].presence || "#{LOOM_PREFIX}#{label_field}"
        result['label_value'] = entry[:label_value].to_s if entry[:label_value].present?
      end

      result
    end

    def cell_line_reason(trigger)
      template = Rules.cross_field_rule_by_key('CF-2a')&.dig(:violation, :template).to_s
      if (match = template.match(/\A(tissue_type is "[^"]+") --/))
        "#{match[1]}."
      else
        "tissue_type is \"#{trigger}\"."
      end
    end

    def assay_suspension_config
      group_id = resolve_group_id_for_obs_field('suspension_type') || 'suspension_type'
      paths = group_paths(group_id)
      fix_form = Rules.fix_form_cross_field_messages

      {
        'map' => Rules.assay_suspension_type_map,
        'ancestor_terms' => Rules.assay_ancestor_terms,
        'group_id' => group_id,
        'term_path' => paths[:term_path].presence || "#{LOOM_PREFIX}suspension_type",
        'lock_reason_template' => fix_form[:assay_suspension_lock_reason],
        'restrict_message_template' => fix_form[:assay_suspension_restrict_message],
        'restrict_detail_template' => fix_form[:assay_suspension_restrict_detail]
      }
    end

    def tissue_type_tissue_config
      org_cfg = Rules.organism_specific_validation_config
      group_id = resolve_group_id_for_obs_field('tissue_ontology_term_id') || 'tissue'
      organism_term = project_organism_term_id

      {
        'group_id' => group_id,
        'trigger_group_id' => resolve_group_id_for_obs_field('tissue_type') || 'tissue_type',
        'cell_line_value' => org_cfg[:cell_line_tissue_type],
        'primary_cell_culture_value' => org_cfg[:primary_cell_culture_tissue_type],
        'cell_line_prefixes' => [cellosaurus_ontology_tag],
        'tissue_prefixes' => organism_term ? Rules.organism_tissue_prefixes_for(organism_term) : Rules.organism_tissue_default_prefixes,
        'cell_type_prefixes' => organism_term ? Rules.organism_cell_type_prefixes_for(organism_term) : Rules.organism_cell_type_default_prefixes
      }
    end

    def project_organism_term_id
      organism = @project.organism
      organism ? "NCBITaxon:#{organism.tax_id}" : nil
    end

    def cellosaurus_ontology_tag
      Rules.ontology_prefixes('tissue_ontology_term_id').find { |prefix| prefix == 'CVCL' } || 'CVCL'
    end

    def resolve_group_id_for_obs_field(field_name)
      @group_id_by_obs_field[field_name.to_s]
    end

    def group_paths(group_id)
      g = @groups_by_id[group_id]
      return {} unless g

      {
        term_path: g[:term_path].to_s.presence,
        label_path: g[:label_path].to_s.presence
      }
    end
  end
end
