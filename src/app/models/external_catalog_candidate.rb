# frozen_string_literal: true

class ExternalCatalogCandidate < ApplicationRecord
  SOURCES = %w[cellxgene bgee hca geo].freeze
  IMPORT_STATUSES = %w[idle importing failed].freeze
  SERIES_IDENTIFIER_KINDS = %w[geo_series array_express bioproject ega_study].freeze
  COLLECTION_URL_RE = %r{/collections/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})}i

  belongs_to :import_project, class_name: 'Project', optional: true, inverse_of: :external_catalog_candidates
  belongs_to :import_user, class_name: 'User', optional: true

  before_validation :assign_series_fields

  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :external_id, presence: true
  validates :provider_tag, presence: true
  validates :import_status, inclusion: { in: IMPORT_STATUSES }
  validates :external_id, uniqueness: { scope: :source }

  scope :for_source, ->(source) { where(source: source) if source.present? }
  scope :for_project_type, ->(tag) { where(project_type_tag: tag) if tag.present? }
  scope :not_importing, -> { where.not(import_status: 'importing') }
  scope :importable, -> { current.where(import_status: %w[idle failed]) }
  # Obsolete = gone from upstream / curated out. Test rows (blank url) may be deleted instead.
  scope :current, -> { where(obsolete: false) }
  scope :obsolete_only, -> { where(obsolete: true) }
  scope :test_entry, -> { where("url IS NULL OR BTRIM(url) = ''") }
  scope :non_test_entry, -> { where.not("url IS NULL OR BTRIM(url) = ''") }
  scope :search_q, lambda { |q|
    next all if q.blank?

    pattern = "%#{sanitize_sql_like(q.to_s.strip)}%"
    where(
      'title ILIKE ? OR external_id ILIKE ? OR filename ILIKE ? OR series_key ILIKE ? OR collection_id ILIKE ?',
      pattern, pattern, pattern, pattern, pattern
    )
  }
  # Logical browse/import order: source, series (DOI/GEO/collection), organism, title.
  scope :ordered_for_catalog, lambda {
    order(
      Arel.sql('source ASC'),
      Arel.sql("COALESCE(series_key, '') ASC"),
      Arel.sql('tax_id ASC NULLS LAST'),
      Arel.sql("LOWER(COALESCE(title, '')) ASC"),
      id: :asc
    )
  }

  # Candidate ids that already have a live ASAP project via ProviderProject.
  def self.ids_already_in_asap
    joins(
      "INNER JOIN providers ON providers.tag = external_catalog_candidates.provider_tag
       INNER JOIN provider_projects ON provider_projects.provider_id = providers.id
         AND provider_projects.key = external_catalog_candidates.external_id
       INNER JOIN projects_provider_projects
         ON projects_provider_projects.provider_project_id = provider_projects.id
       INNER JOIN projects ON projects.id = projects_provider_projects.project_id"
    )
      .where('projects.being_deleted IS NULL OR projects.being_deleted = ?', false)
      .distinct
      .pluck(:id)
  end

  def self.not_yet_in_asap
    in_asap = ids_already_in_asap
    in_asap.empty? ? all : where.not(id: in_asap)
  end

  def self.collection_id_from_source_page_url(url)
    return nil if url.blank?

    match = url.to_s.match(COLLECTION_URL_RE)
    match && match[1].presence
  end

  # Stable series key for grouping related datasets.
  # Priority: DOI > GEO/ArrayExpress/BioProject/EGA accession > CELLxGENE collection.
  def self.build_series_key(source:, external_id:, dois:, identifiers:, collection_id:)
    doi = Array(dois).filter_map { |d| ExternalCatalog::ReferenceIds.normalize_doi(d) }.first
    return "doi:#{doi}" if doi.present?

    if source.to_s == 'geo'
      gse = external_id.to_s.strip
      gse = gse.upcase if gse.match?(/\AGSE\d+\z/i)
      return "geo_series:#{gse}" if gse.present?
    end

    Array(identifiers).each do |raw|
      kind, value =
        if raw.is_a?(Hash)
          [raw[:kind] || raw['kind'], raw[:value] || raw['value'] || raw[:id] || raw['id']]
        else
          [nil, raw]
        end
      ident = ExternalCatalog::ReferenceIds.identifier_hash(kind: kind, value: value)
      next unless ident
      next unless SERIES_IDENTIFIER_KINDS.include?(ident[:kind].to_s)

      return "#{ident[:kind]}:#{ident[:value].to_s.strip}"
    end

    cid = collection_id.to_s.strip.presence
    return "collection:#{cid}" if cid.present?

    nil
  end

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

  def has_attached_asap_projects?
    return true if already_in_asap?
    return false if import_project_id.blank?

    import_project.present? && !import_project.being_deleted
  end

  def importing?
    import_status.to_s == 'importing'
  end

  def failed?
    import_status.to_s == 'failed'
  end

  def can_create_project?
    !obsolete? && !already_in_asap? && !importing?
  end

  def test_entry?
    url.blank?
  end

  def can_mark_obsolete?
    !obsolete?
  end

  def mark_obsolete!
    raise ArgumentError, 'Candidate is already obsolete' unless can_mark_obsolete?

    update!(obsolete: true)
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
      source_page_url: source_page_url,
      collection_id: collection_id
    )
  end

  def self.upsert_from_entry!(entry)
    raise ArgumentError, 'entry required' unless entry

    record = find_or_initialize_by(source: entry.source.to_s, external_id: entry.external_id.to_s)
    collection_id =
      entry.collection_id.to_s.presence ||
      collection_id_from_source_page_url(entry.source_page_url)
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
      collection_id: collection_id,
      dois_json: entry.normalized_dois.to_json,
      pmids_json: entry.normalized_pmids.to_json,
      identifiers_json: entry.normalized_identifiers.to_json,
      last_seen_at: Time.current,
      obsolete: false
    )
    record.import_status = 'idle' if record.import_status.blank?
    record.save!
    record
  end

  private

  def assign_series_fields
    self.collection_id = collection_id.presence ||
                         self.class.collection_id_from_source_page_url(source_page_url)
    self.series_key = self.class.build_series_key(
      source: source,
      external_id: external_id,
      dois: dois,
      identifiers: identifiers,
      collection_id: collection_id
    )
  end

  def parse_json_array(raw)
    return [] if raw.blank?

    value = JSON.parse(raw)
    value.is_a?(Array) ? value : []
  rescue JSON::ParserError
    []
  end
end
