class Status < ApplicationRecord
  has_many :projects
  
  validates :name, presence: true
  
  def display_name
    name
  end
end
