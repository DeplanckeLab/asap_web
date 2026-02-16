class OntologyTermType < ApplicationRecord
  DEFAULT_RANK_RANGE = (1..20).freeze

  # Scope for records that serve as compliance field groups.
  scope :compliance_field_groups, -> {
    where.not(field_group_id: [nil, '']).order(:display_order)
  }

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
    h = {
      id: field_group_id,
      label: label,
      description: description,
      type: field_type&.to_sym || :col_attr,
      term_path: term_path,
      label_path: label_path.presence,
      multi_value: multi_value || false
    }

    # Auto-fill configuration
    if auto_from_project.present?
      h[:auto_from_project] = (auto_from_project == 'title') ? :title : true
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

