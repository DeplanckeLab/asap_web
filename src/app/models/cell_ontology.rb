class CellOntology < ApplicationRecord
  has_and_belongs_to_many :organisms
  has_many :cell_ontology_terms, dependent: :restrict_with_exception

  def tax_id_list
    @tax_id_list ||= tax_ids.to_s.split(",").map { |value| value.strip }.reject(&:blank?).map(&:to_i)
  end

  def applies_to_all_organisms?
    tax_id_list.empty?
  end

  def website_url
    url.presence
  end

  def file_download_url
    file_url.presence
  end
end


