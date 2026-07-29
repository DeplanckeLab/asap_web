# frozen_string_literal: true

class ProjectOrigin < ApplicationRecord
  UPLOAD = 'upload'
  CLONE = 'clone'
  INTEGRATION = 'integration'
  SCFAIR_VALIDATION = 'scfair_validation'

  NAMES = [UPLOAD, CLONE, INTEGRATION, SCFAIR_VALIDATION].freeze

  has_many :projects, dependent: :restrict_with_exception

  validates :name, presence: true, uniqueness: { case_sensitive: true }, inclusion: { in: NAMES }

  def self.id_for(name)
    find_by(name: name)&.id
  end

  def self.name_for(id)
    return if id.blank?

    find_by(id: id)&.name
  end

  def display_label
    label.presence || name.to_s.tr('_', ' ').capitalize
  end
end
