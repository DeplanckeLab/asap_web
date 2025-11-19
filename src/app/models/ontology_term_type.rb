class OntologyTermType < ApplicationRecord
  DEFAULT_RANK_RANGE = (1..20).freeze

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

  private

  def parse_ids(value)
    value.to_s.split(",").map(&:strip).reject(&:blank?).map(&:to_i)
  end
end

