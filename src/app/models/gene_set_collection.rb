class GeneSetCollection < ApplicationRecord
  belongs_to :project
  belongs_to :user, optional: true

  validates :project_id, presence: true
  validates :name, presence: true
  validates :file_key, presence: true, uniqueness: true
  validates :source_kind, presence: true
end
