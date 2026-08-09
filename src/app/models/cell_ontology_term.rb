class CellOntologyTerm < ApplicationRecord
  belongs_to :cell_ontology

  scope :original, -> { where(original: true) }

  # Metadata label resolution (e.g. ASAP auto CLAs) must ignore obsolete terms and
  # terms whose parent ontology is obsolete (cell_ontologies.obsolete), so disabled
  # ontologies such as CARO do not compete with UBERON and similar.
  scope :with_active_cell_ontology, -> {
    where(obsolete: false)
      .joins(:cell_ontology)
      .where(cell_ontologies: { obsolete: false })
  }

  # Active original term for compliance and metadata resolution (excludes obsolete terms and ontologies).
  def self.active_original_by_identifier(identifier)
    with_active_cell_ontology.find_by(identifier: identifier.to_s, original: true)
  end

  # Prefer replaced_by, then the first consider entry from OBO content_json.
  def self.successor_identifier(identifier, max_hops: 5)
    current = identifier.to_s.strip
    return nil if current.blank?

    hops = 0
    while hops < max_hops
      term = original.find_by(identifier: current)
      break unless term&.obsolete?

      nxt = term.obo_successor_identifier
      break if nxt.blank? || nxt == current

      current = nxt
      hops += 1
    end

    hops.positive? ? current : nil
  end

  # Active original term for identifier, following obsolete replaced_by/consider when needed.
  def self.active_original_or_successor(identifier)
    id = identifier.to_s.strip
    return nil if id.blank?

    active = active_original_by_identifier(id)
    return active if active

    successor = successor_identifier(id)
    return nil if successor.blank?

    active_original_by_identifier(successor)
  end

  def obo_successor_identifier
    payload = parsed_content_json
    return nil unless payload.is_a?(Hash)

    replaced = Array(payload['replaced_by']).map(&:to_s).reject(&:blank?)
    return replaced.first if replaced.any?

    consider = Array(payload['consider']).map(&:to_s).reject(&:blank?)
    consider.first
  end

  def parsed_content_json
    raw = content_json
    return raw if raw.is_a?(Hash)
    return {} if raw.blank?

    JSON.parse(raw.to_s)
  rescue JSON::ParserError
    {}
  end
end


