# frozen_string_literal: true

class ProjectCollection < ApplicationRecord
  SOURCES = %w[cellxgene manual geo hca bgee].freeze

  belongs_to :created_by_user, class_name: 'User', optional: true, foreign_key: :created_by_user_id
  has_many :projects, dependent: :nullify, inverse_of: :project_collection

  validates :title, presence: true
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :external_key, uniqueness: { scope: :source }, allow_nil: true

  scope :ordered_by_title, -> { order(Arel.sql("LOWER(COALESCE(title, '')) ASC"), id: :asc) }
  scope :created_by, ->(user) { where(created_by_user_id: user.id) if user }
  scope :manual, -> { where(source: 'manual') }

  def catalog_backed?
    source.to_s != 'manual' && external_key.present?
  end

  def owned_by?(user)
    user.present? && created_by_user_id.present? && created_by_user_id == user.id
  end

  def self.placeholder_title_for(source, external_key)
    "#{source} collection #{external_key}"
  end

  def placeholder_title?
    external_key.present? && title.to_s == self.class.placeholder_title_for(source, external_key)
  end

  # Upsert catalog-backed umbrella by (source, external_key).
  # Refreshes title/description when still placeholder / blank; does not overwrite
  # customized local values.
  def self.upsert_from_catalog!(source:, external_key:, title:, description: nil, source_page_url: nil)
    source = source.to_s.strip
    external_key = external_key.to_s.strip.presence
    raise ArgumentError, 'source required' if source.blank?
    raise ArgumentError, 'external_key required for catalog upsert' if external_key.blank?

    placeholder = placeholder_title_for(source, external_key)
    incoming_title = title.to_s.strip.presence
    record = find_or_initialize_by(source: source, external_key: external_key)
    if record.new_record?
      record.title = incoming_title || placeholder
      record.description = description.to_s.presence
      record.source_page_url = source_page_url.to_s.presence
    else
      if incoming_title.present? && (record.title.blank? || record.title == placeholder)
        record.title = incoming_title
      end
      if description.present? && record.description.blank?
        record.description = description.to_s
      end
      if record.source_page_url.blank? && source_page_url.present?
        record.source_page_url = source_page_url.to_s
      end
    end
    record.save!
    record
  end

  def self.create_manual!(title:, description: nil, created_by_user: nil)
    create!(
      source: 'manual',
      external_key: nil,
      title: title.to_s.strip,
      description: description.to_s.presence,
      created_by_user_id: created_by_user&.id
    )
  end

  def display_title
    title.to_s.presence || "Collection ##{id}"
  end
end
