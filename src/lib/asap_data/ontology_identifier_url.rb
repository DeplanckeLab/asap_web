# frozen_string_literal: true

module AsapData
  # Build an external ontology URL for a CURIE-style identifier using
  # cell_ontologies.url_mask in the app DB (stable across asap_data_vX).
  #
  # Prefix is the part before the first colon (e.g. GO:0000002 -> GO),
  # matched case-insensitively to cell_ontologies.tag.
  module OntologyIdentifierUrl
    module_function

    def prefix_for(identifier)
      id = identifier.to_s.strip
      return nil if id.blank?
      return nil unless id.include?(":")

      id.split(":", 2).first.presence
    end

    def url_for(identifier, ontology_by_tag: nil)
      id = identifier.to_s.strip
      prefix = prefix_for(id)
      return nil if prefix.blank?

      ontology = if ontology_by_tag
        ontology_by_tag[prefix.downcase]
      else
        CellOntology
          .where("LOWER(tag) = ?", prefix.downcase)
          .where("COALESCE(url_mask, '') <> ''")
          .where(obsolete: false)
          .order(:id)
          .first
      end
      return nil unless ontology

      apply_mask(ontology.url_mask, id)
    end

    def ontology_by_tag_index
      CellOntology
        .where("COALESCE(url_mask, '') <> ''")
        .where(obsolete: false)
        .order(:id)
        .each_with_object({}) do |ontology, index|
          tag = ontology.tag.to_s.strip.downcase
          next if tag.blank?
          index[tag] ||= ontology
        end
    end

    def apply_mask(mask, identifier)
      template = mask.to_s.strip
      return nil if template.blank?

      id = identifier.to_s.strip
      underscored = id.tr(":", "_")
      url = template.dup
      url.gsub!(/\{ID_WITH_UNDERSCORE\}/, underscored)
      url.gsub!(/#\{id\}/i, id)
      url.gsub!(/\{ID\}/, id)
      url.presence
    end
  end
end
