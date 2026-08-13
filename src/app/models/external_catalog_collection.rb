# frozen_string_literal: true

class ExternalCatalogCollection < ApplicationRecord
  SOURCES = ExternalCatalogCandidate::SOURCES

  has_many :external_catalog_candidates,
           dependent: :nullify,
           inverse_of: :external_catalog_collection

  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :external_key, presence: true, uniqueness: { scope: :source }
  validates :title, presence: true

  scope :for_source, ->(source) { where(source: source) if source.present? }
  scope :ordered_by_title, -> { order(Arel.sql("LOWER(COALESCE(title, '')) ASC"), id: :asc) }

  def self.placeholder_title_for(source, external_key)
    "#{source} collection #{external_key}"
  end

  # Upsert catalog-backed umbrella by (source, external_key).
  # Refreshes title/description when still placeholder / blank; does not overwrite
  # customized local values.
  def self.upsert_from_catalog!(source:, external_key:, title:, description: nil, source_page_url: nil)
    source = source.to_s.strip
    external_key = external_key.to_s.strip.presence
    raise ArgumentError, 'source required' if source.blank?
    raise ArgumentError, 'external_key required' if external_key.blank?

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

  def display_title
    title.to_s.presence || "Collection ##{id}"
  end

  def placeholder_title?
    title.to_s == self.class.placeholder_title_for(source, external_key)
  end

  # Unique live ASAP projects linked via candidates in this collection.
  def linked_asap_projects
    candidate_ids = external_catalog_candidates.current.pluck(:id, :provider_tag, :external_id, :import_project_id)
    return Project.none if candidate_ids.empty?

    project_ids = []
    import_ids = candidate_ids.filter_map { |(_id, _tag, _key, import_id)| import_id }
    project_ids.concat(import_ids)

    by_provider = candidate_ids.group_by { |_id, tag, _key, _import| tag }
    by_provider.each do |tag, rows|
      next if tag.blank?

      provider = Provider.find_by(tag: tag)
      next unless provider

      keys = rows.map { |_id, _tag, key, _import| key.to_s }.uniq
      next if keys.empty?

      linked = Project.joins(:provider_projects)
                      .where(provider_projects: { provider_id: provider.id, key: keys })
                      .where(being_deleted: [false, nil])
                      .pluck(:id)
      project_ids.concat(linked)
    end

    Project.where(id: project_ids.uniq, being_deleted: [false, nil])
  end
end
