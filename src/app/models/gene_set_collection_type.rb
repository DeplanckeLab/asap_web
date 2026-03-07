class GeneSetCollectionType < ApplicationRecord
  has_many :gene_set_collections, dependent: :restrict_with_exception

  validates :key, presence: true, uniqueness: true
  validates :label, presence: true
  validates :icon, presence: true
  validates :icon_color, presence: true
end
