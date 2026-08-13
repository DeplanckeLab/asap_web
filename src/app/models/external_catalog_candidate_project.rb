# frozen_string_literal: true

class ExternalCatalogCandidateProject < ApplicationRecord
  LINK_KINDS = %w[import content_match provider_match manual].freeze

  belongs_to :external_catalog_candidate, inverse_of: :external_catalog_candidate_projects
  belongs_to :project, inverse_of: :external_catalog_candidate_projects

  validates :link_kind, presence: true, inclusion: { in: LINK_KINDS }
  validates :project_id, uniqueness: { scope: :external_catalog_candidate_id }

  scope :for_kind, ->(kind) { where(link_kind: kind) if kind.present? }
end
