# frozen_string_literal: true

class ExternalCatalogCandidate < ApplicationRecord
  SOURCES = %w[cellxgene bgee hca geo].freeze
  IMPORT_STATUSES = %w[idle importing failed].freeze

  belongs_to :import_project, class_name: 'Project', optional: true
  belongs_to :import_user, class_name: 'User', optional: true

  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :external_id, presence: true
  validates :provider_tag, presence: true
  validates :import_status, inclusion: { in: IMPORT_STATUSES }
  validates :external_id, uniqueness: { scope: :source }

  scope :for_source, ->(source) { where(source: source) if source.present? }
  scope :for_project_type, ->(tag) { where(project_type_tag: tag) if tag.present? }
  scope :search_q, lambda { |q|
    next all if q.blank?

    pattern = "%#{sanitize_sql_like(q.to_s.strip)}%"
    where('title ILIKE ? OR external_id ILIKE ? OR filename ILIKE ?', pattern, pattern, pattern)
  }

  def provider
    @provider ||= Provider.find_by(tag: provider_tag)
  end

  def provider_project
    return nil unless provider

    ProviderProject.find_by(provider_id: provider.id, key: external_id.to_s)
  end

  def asap_projects
    pp = provider_project
    return Project.none unless pp

    pp.projects.where(being_deleted: [false, nil])
  end

  def already_in_asap?
    asap_projects.exists?
  end

  def importing?
    import_status.to_s == 'importing'
  end

  def failed?
    import_status.to_s == 'failed'
  end

  def can_create_project?
    !already_in_asap? && !importing?
  end

  def dois
    parse_json_array(dois_json)
  end

  def pmids
    parse_json_array(pmids_json)
  end

  def identifiers
    parse_json_array(identifiers_json)
  end

  def parsed_attrs
    return {} if attrs_json.blank?

    JSON.parse(attrs_json)
  rescue JSON::ParserError
    {}
  end

  def to_entry
    ExternalCatalog::Entry.new(
      source: source,
      external_id: external_id,
      title: title,
      url: url,
      tax_id: tax_id,
      organism_label: organism_label,
      filesize: filesize.to_i,
      project_type_tag: project_type_tag.presence || 'sc',
      format_kind: format_kind.presence&.to_sym,
      filename: filename,
      dois: dois,
      pmids: pmids,
      identifiers: identifiers,
      source_page_url: source_page_url
    )
  end

  def self.upsert_from_entry!(entry)
    raise ArgumentError, 'entry required' unless entry

    record = find_or_initialize_by(source: entry.source.to_s, external_id: entry.external_id.to_s)
    record.assign_attributes(
      provider_tag: entry.provider_tag,
      title: entry.title.to_s.presence || entry.external_id.to_s,
      organism_label: entry.organism_label,
      tax_id: entry.tax_id,
      project_type_tag: entry.project_type_tag.presence || 'sc',
      format_kind: entry.format_kind.to_s.presence,
      filename: entry.filename,
      filesize: entry.filesize.to_i,
      url: entry.url,
      source_page_url: entry.source_page_url,
      dois_json: entry.normalized_dois.to_json,
      pmids_json: entry.normalized_pmids.to_json,
      identifiers_json: entry.normalized_identifiers.to_json,
      last_seen_at: Time.current
    )
    record.import_status = 'idle' if record.import_status.blank?
    record.save!
    record
  end

  private

  def parse_json_array(raw)
    return [] if raw.blank?

    value = JSON.parse(raw)
    value.is_a?(Array) ? value : []
  rescue JSON::ParserError
    []
  end
end
