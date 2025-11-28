class Organism < ApplicationRecord
  has_many :projects
  belongs_to :ensembl_subdomain, optional: true
  
  validates :name, presence: true
  
  def display_name
    short_name.presence || name
  end
end
