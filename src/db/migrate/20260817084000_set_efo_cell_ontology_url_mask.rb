# frozen_string_literal: true

class SetEfoCellOntologyUrlMask < ActiveRecord::Migration[7.2]
  EFO_TAG = "EFO"
  EFO_URL_MASK = "http://www.ebi.ac.uk/efo/{ID_WITH_UNDERSCORE}"

  def up
    efo = CellOntology.find_by(tag: EFO_TAG)
    return unless efo
    return if efo.url_mask.to_s.strip.present?

    efo.update!(url_mask: EFO_URL_MASK)
  end

  def down
    efo = CellOntology.find_by(tag: EFO_TAG)
    return unless efo
    return unless efo.url_mask == EFO_URL_MASK

    efo.update!(url_mask: "")
  end
end
