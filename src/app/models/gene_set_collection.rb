class GeneSetCollection < ApplicationRecord
  belongs_to :project
  belongs_to :user, optional: true
  belongs_to :gene_set_collection_type

  validates :project_id, presence: true
  validates :name, presence: true
  validates :file_key, presence: true, uniqueness: true
  validates :source_kind, presence: true
  validates :gene_set_collection_type_id, presence: true
end
