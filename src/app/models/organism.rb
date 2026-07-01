class Organism < ApplicationRecord
  has_many :projects
  belongs_to :ensembl_subdomain, optional: true
  
  validates :name, presence: true
  
  def display_name
    short_name.presence || name
  end

  def self.selector_label(name, short_name = nil)
    org_name = name.to_s.strip
    return org_name if short_name.blank?

    short = short_name.to_s.strip
    return org_name if short == org_name
    return short if short.start_with?(org_name)

    "#{org_name} (#{short})"
  end
end
