class OntologyTermType < ApplicationRecord
  DEFAULT_RANK_RANGE = (1..20).freeze

  # Palette aligned with sc-fair.org/explore category chips (CELLxGENE-inspired).
  # Used when color/icon columns are blank and as migration seed defaults.
  EXPLORE_STYLES = {
    'organism' => { color: '#7C3AED', icon: 'fa-dna' },
    'assay' => { color: '#D97706', icon: 'fa-flask' },
    'cell_type' => { color: '#2563EB', icon: 'fa-circle' },
    'development_stage' => { color: '#9333EA', icon: 'fa-seedling' },
    'disease' => { color: '#DB2777', icon: 'fa-virus' },
    'self_reported_ethnicity' => { color: '#059669', icon: 'fa-users' },
    'sex' => { color: '#EA580C', icon: 'fa-venus-mars' },
    'tissue' => { color: '#0D9488', icon: 'fa-lungs' },
    'experimental_condition' => { color: '#4F46E5', icon: 'fa-vial' },
    'tissue_type' => { color: '#0891B2', icon: 'fa-microscope' },
    'suspension_type' => { color: '#64748B', icon: 'fa-tint' },
    'donor_id' => { color: '#78716C', icon: 'fa-user' }
  }.freeze

  # Paired ontology annotation types (linked to fix_form.field_groups via field_group_id).
  # Other fix-form fields are defined in rules.yaml only.
  scope :compliance_field_groups, -> {
    where.not(field_group_id: [nil, '']).order(:display_order)
  }

  def self.explore_style_for(field_group_id)
    EXPLORE_STYLES[field_group_id.to_s] || { color: '#64748B', icon: 'fa-tag' }
  end

  def explore_color
    color.presence || self.class.explore_style_for(field_group_id.presence || name)[:color]
  end

  def explore_icon
    icon.presence || self.class.explore_style_for(field_group_id.presence || name)[:icon]
  end

  def cell_ontology_ids_list
    @cell_ontology_ids_list ||= parse_ids(cell_ontology_ids)
  end

  def lineage_term_ids_list
    @lineage_term_ids_list ||= parse_ids(in_lineage_term_ids)
  end

  def term_ids_list
    @term_ids_list ||= parse_ids(term_ids)
  end

  def free_text_entries
    @free_text_entries ||= begin
      value = free_text_json.to_s.strip
      if value.blank?
        []
      else
        JSON.parse(value)
      end
    rescue JSON::ParserError
      []
    end
  end

  # Derive ontology prefix tags from cell_ontology_ids.
  # Requires a pre-loaded hash of { co_id => tag } to avoid N+1 queries.
  def ontology_prefixes(co_id_to_tag = nil)
    ids = cell_ontology_ids_list
    return [] if ids.empty?
    co_id_to_tag ||= CellOntology.where(id: ids).pluck(:id, :tag).to_h
    ids.filter_map { |cid| co_id_to_tag[cid] }
  end

  # Parse term_valid_values_json into an array.
  def parsed_term_valid_values
    return nil if term_valid_values_json.blank?
    @parsed_term_valid_values ||= JSON.parse(term_valid_values_json)
  rescue JSON::ParserError
    nil
  end

  # Convert this record to the field group hash used by ComplianceController.
  # co_id_to_tag: pre-loaded { cell_ontology_id => tag } map for performance.
  def to_field_group(co_id_to_tag = nil)
    obs_field = Scfair::Rules.obs_field_name_from_path(term_path)
    h = {
      id: field_group_id,
      ontology_term_type_id: self.id,
      label: label,
      description: description,
      type: field_type&.to_sym || :col_attr,
      term_path: term_path,
      label_path: label_path.presence,
      multi_value: Scfair::Rules.multi_value_field?(obs_field)
    }

    # Auto-fill configuration
    if auto_from_project.present?
      h[:auto_from_project] = case auto_from_project.to_s
                              when 'title' then :title
                              when 'schema_version' then :schema_version
                              when 'schema_reference' then :schema_reference
                              else true
                              end
    end

    # Ontology prefixes (derived from cell_ontology_ids)
    prefixes = ontology_prefixes(co_id_to_tag)
    h[:term_ontology_prefixes] = prefixes if prefixes.any?

    # Format hint
    h[:term_format_hint] = term_format_hint if term_format_hint.present?

    # Valid values (for non-ontology fields like tissue_type, suspension_type)
    vals = parsed_term_valid_values
    h[:term_valid_values] = vals if vals.present?

    h
  end

  private

  def parse_ids(value)
    value.to_s.split(",").map(&:strip).reject(&:blank?).map(&:to_i)
  end
end

