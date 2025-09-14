class Organism < ApplicationRecord
  has_many :projects
  
  validates :name, presence: true
  
  def display_name
    short_name.presence || name
  end
end
