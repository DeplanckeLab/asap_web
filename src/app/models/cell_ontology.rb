class CellOntology < ApplicationRecord
  has_and_belongs_to_many :organisms
  has_many :cell_ontology_terms, dependent: :restrict_with_exception

  # tax_ids: comma-separated NCBI taxonomy nodes (a species or any higher clade, e.g. 7147 Diptera).
  # The ontology applies to an organism that is one of those nodes or a descendant of one
  # (scFAIR Appendix B: clade-specific ontologies MUST NOT be used outside their clade).
  # Blank tax_ids = taxon-neutral ontology, applicable to every organism.
  def tax_id_list
    @tax_id_list ||= tax_ids.to_s.split(",").map { |value| value.strip }.reject(&:blank?).map(&:to_i)
  end

  def applies_to_all_organisms?
    tax_id_list.empty?
  end

  # How closely this ontology targets the organism:
  #   0..n                = number of ranks between the organism and the closest listed clade (0 = exact taxon)
  #   Float::INFINITY     = taxon-neutral ontology
  #   nil                 = not applicable to this organism (or tax_id blank and ontology is taxon-specific)
  def taxon_distance(tax_id, lineage: NcbiTaxonomyLineageResolver.shared)
    return Float::INFINITY if applies_to_all_organisms?

    lineage.distance_to_nearest(tax_id, tax_id_list)
  end

  def applies_to_tax_id?(tax_id, lineage: NcbiTaxonomyLineageResolver.shared)
    !taxon_distance(tax_id, lineage: lineage).nil?
  end

  def website_url
    url.presence
  end

  def file_download_url
    file_url.presence
  end
end
