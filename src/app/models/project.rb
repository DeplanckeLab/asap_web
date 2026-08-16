require "shellwords"

class Project < ApplicationRecord
  include Elasticsearch::Model
  include Elasticsearch::Model::Callbacks
  before_save :sanitize_non_raw_text_parsing_attrs!

  validates :key, presence: true, uniqueness: { case_sensitive: true }
  # Remove fus rows first (raw delete). Upload rows must not block project delete if
  # association-dependent cleanup is skipped or the running app is an older image.
  before_destroy :purge_fus_for_project_destroy!, prepend: true
  # Drop the on-disk project tree after the DB row is gone. Done in after_commit so a
  # large rm_rf does not hold the destroy transaction open (UI destroy previously left
  # USER_DATA_DIR/<user>/<key>/ behind as orphan project directories).
  after_commit :remove_project_filesystem_after_destroy!, on: :destroy
  # Terminal runs are archived via Run#before_destroy when dependent: :destroy runs.

  # Associations
  belongs_to :user, optional: true
  belongs_to :organism, optional: true
  belongs_to :status, optional: true
  belongs_to :step, optional: true
  belongs_to :project_type, optional: true
  belongs_to :project_cell_set, optional: true
  belongs_to :version, optional: true
  belongs_to :archive_status, optional: true
  belongs_to :project_origin
  belongs_to :project_collection, optional: true, inverse_of: :projects
  belongs_to :cloned_project, class_name: 'Project', foreign_key: 'cloned_project_id', optional: true
  belongs_to :root_project, class_name: 'Project', foreign_key: 'root_project_id', optional: true, inverse_of: :lineage_clone_projects
  has_many :lineage_clone_projects, class_name: 'Project', foreign_key: 'root_project_id', dependent: :nullify, inverse_of: :root_project
  before_validation :ensure_default_project_origin
  # Default association omits heavy JSON (headers_json). Use Annot.find / headers_json_value when needed.
  has_many :annots, -> { light }, dependent: :destroy
  has_many :annots_light, -> { light }, class_name: 'Annot', foreign_key: :project_id, inverse_of: :project
  has_many :annot_cell_sets, inverse_of: :project
  has_many :ot_projects, dependent: :destroy
  has_many :ott_projects, dependent: :destroy
  has_many :compliance_mappings, dependent: :destroy
  has_many :compliance_validations, dependent: :destroy
  has_many :reqs, dependent: :destroy
  has_many :runs, dependent: :destroy
  has_many :project_steps, dependent: :destroy
  has_many :project_view_logs, dependent: :delete_all
  has_many :shares, dependent: :destroy
  has_many :checkpoints, dependent: :destroy
  has_many :projects_provider_projects, dependent: :delete_all
  has_many :provider_projects, through: :projects_provider_projects
  has_many :articles_projects, dependent: :delete_all
  has_many :articles, through: :articles_projects
  has_many :exp_entries_projects, dependent: :delete_all
  has_many :exp_entries, through: :exp_entries_projects
  # Catalog import pointer: keep candidate row, clear link when project is deleted.
  has_many :external_catalog_candidates,
           class_name: 'ExternalCatalogCandidate',
           foreign_key: :import_project_id,
           dependent: :nullify,
           inverse_of: :import_project
  has_many :external_catalog_candidate_projects, dependent: :delete_all, inverse_of: :project
  has_many :matched_external_catalog_candidates,
           through: :external_catalog_candidate_projects,
           source: :external_catalog_candidate
  has_many :fus

  # Project-local Fu storage (fus/<fu_id>/ under this project's directory).
  def fu_storage_dir
    return nil unless fu_id

    fu = Fu.find_by(id: fu_id)
    return fu.upload_dir_for_project(self) if fu

    upload_root = data_dir + 'fus' + fu_id.to_s
    upload_root if upload_root.directory?
  end

  def find_fu_for_upload
    Fu.resolve_for_project(self)
  end

  def data_dir
    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
    Pathname.new(user_data_dir) + user_id.to_s + key
  end

  # Elasticsearch settings
  settings index: {
    number_of_shards: 1,
    analysis: {
      normalizer: {
        lowercase_normalizer: {
          type: 'custom',
          filter: ['lowercase']
        }
      }
    }
  } do
    mappings dynamic: 'false' do
      indexes :name, type: 'text', analyzer: 'english'
      indexes :key, type: 'text', analyzer: 'english'
      indexes :description, type: 'text', analyzer: 'english'
      indexes :technology, type: 'keyword', normalizer: 'lowercase_normalizer'
      indexes :project_type_name, type: 'keyword'
      indexes :tissue, type: 'keyword', normalizer: 'lowercase_normalizer'
      indexes :organism_name, type: 'keyword'
      indexes :status_name, type: 'keyword'
      indexes :public, type: 'boolean'
      indexes :being_deleted, type: 'boolean'
      indexes :created_at, type: 'date'
      indexes :updated_at, type: 'date'
      indexes :nber_cols, type: 'integer'
      indexes :nber_rows, type: 'integer'
      indexes :nber_views, type: 'integer'
      indexes :nber_cloned, type: 'integer'
      indexes :disk_size, type: 'long'
      indexes :user_id, type: 'integer'
      indexes :owner_email, type: 'text' do
        indexes :raw, type: 'keyword', normalizer: 'lowercase_normalizer'
      end
      indexes :shared_user_ids, type: 'integer'
    end
  end

  # Scopes for filtering
  scope :public_projects, -> { where(public: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_organism, ->(organism_id) { where(organism_id: organism_id) if organism_id.present? }
  scope :by_technology, ->(technology) { where("technology ILIKE ?", "%#{technology}%") if technology.present? }
  scope :by_tissue, ->(tissue) { where("tissue ILIKE ?", "%#{tissue}%") if tissue.present? }
  scope :by_status, ->(status_id) { where(status_id: status_id) if status_id.present? }
  scope :not_deleted, -> { where(being_deleted: false) }

  # Picks the project used by the "Getting started" guided tour and browse-page demo row highlight.
  # Priority: GUIDED_TOUR_DEMO_PROJECT_ID, GUIDED_TOUR_DEMO_PROJECT_KEY, public ASAP48 when present,
  # known FCA/haltère keys, any public project whose key or name suggests FCA + haltère,
  # first public with a 2D embedding annot, then first public / any project (same as legacy seeds).
  def self.guided_tour_demo_project
    id_s = ENV["GUIDED_TOUR_DEMO_PROJECT_ID"].to_s.strip
    if id_s.match?(/\A\d+\z/) && id_s.to_i.positive?
      found = find_by(id: id_s.to_i)
      return found if found
    end

    key_s = ENV["GUIDED_TOUR_DEMO_PROJECT_KEY"].to_s.strip
    if key_s.present?
      found = find_by(key: key_s)
      return found if found
    end

    asap48 = public_projects.find_by(public_id: 48)
    return asap48 if asap48

    %w[fca_haltere FCA_haltere fca-haltere FCA-haltere].each do |k|
      p = public_projects.find_by(key: k)
      return p if p
    end

    fca_haltere_scope = public_projects.where(
      <<~SQL.squish,
        (projects.key ILIKE :haltere_ascii OR projects.name ILIKE :haltere_ascii
         OR projects.key ILIKE :haltere_utf8 OR projects.name ILIKE :haltere_utf8)
        AND (projects.key ILIKE :fca OR projects.name ILIKE :fca)
      SQL
      haltere_ascii: "%haltere%",
      haltere_utf8: "%haltère%",
      fca: "%fca%"
    )
    hit = fca_haltere_scope.order(:id).first
    return hit if hit

    embedded = public_projects
      .where(id: Annot.where(nber_rows: 2).select(:project_id))
      .order(:id)
      .first
    return embedded if embedded

    public_projects.order(:id).first || order(:id).first
  end

  # Generate a project key that is unique across all projects (filesystem paths and URLs rely on this).
  def self.generate_unique_key
    loop do
      key = Array.new(6) { [*"0".."9", *"a".."z"].sample }.join
      return key unless exists?(key: key)
    end
  end

  # Canonical root of a clone lineage (+cloned_project_id+ chain). Used when creating a new clone.
  def self.root_project_id_for_clone_source(source)
    return nil unless source

    source.root_project_id.presence || source.id
  end

  # Elasticsearch search functionality
  def self.search(query, filters = {})
    # Build the search query
    search_definition = {
      query: {
        bool: {
          must: [],
          filter: []
        }
      },
      sort: [],
      size: 20,
      from: 0
    }

    unless filters[:skip_aggregations]
      search_definition[:aggs] = {
        organisms: { terms: { field: 'organism_name', size: 500 } },
        project_types: { terms: { field: 'project_type_name', size: 100 } },
        tissues: { terms: { field: 'tissue', size: 2000 } },
        statuses: { terms: { field: 'status_name', size: 50 } }
      }
    else
      search_definition[:_source] = false
    end

    # Add pagination
    if filters[:page].present?
      page = filters[:page].to_i
      search_definition[:from] = (page - 1) * search_definition[:size]
    end

    # Text search
    if query.present?
      normalized_query = query.to_s.strip
      if normalized_query.include?('@')
        search_definition[:query][:bool][:must] << {
          term: { 'owner_email.raw' => normalized_query.downcase }
        }
      else
        search_definition[:query][:bool][:must] << {
          multi_match: {
            query: normalized_query,
            fields: ['name^3', 'key^2', 'description', 'technology', 'owner_email^2'],
            type: 'best_fields',
            fuzziness: 'AUTO'
          }
        }
      end
    end

    # Filters
    if filters[:organism_id].present?
      begin
        organism = Organism.find(filters[:organism_id])
        search_definition[:query][:bool][:filter] << {
          term: { organism_name: organism.name }
        }
      rescue ActiveRecord::RecordNotFound
        Rails.logger.warn "Organism with ID #{filters[:organism_id]} not found"
      end
    end

    if filters[:project_type_id].present?
      begin
        project_type = ProjectType.find(filters[:project_type_id])
        search_definition[:query][:bool][:filter] << {
          term: { project_type_name: project_type.name }
        }
      rescue ActiveRecord::RecordNotFound
        Rails.logger.warn "Project type with ID #{filters[:project_type_id]} not found"
      end
    end

    if filters[:tissue].present?
      search_definition[:query][:bool][:filter] << {
        term: { tissue: filters[:tissue] }
      }
    end

    if filters[:status_id].present?
      begin
        status = Status.find(filters[:status_id])
        search_definition[:query][:bool][:filter] << {
          term: { status_name: status.name }
        }
      rescue ActiveRecord::RecordNotFound
        Rails.logger.warn "Status with ID #{filters[:status_id]} not found"
      end
    end

    if filters[:current_user_id].present?
      case filters[:visibility]
      when 'public'
        search_definition[:query][:bool][:filter] << {
          term: { public: true }
        }
      when 'private'
        search_definition[:query][:bool][:filter] << {
          term: { public: false }
        }
      end
    end

    # Always filter out deleted projects
    search_definition[:query][:bool][:filter] << {
      term: { being_deleted: false }
    }

    # User permission filtering
    # - Admin: can see all projects (no filter)
    # - Logged in user: can see public projects OR owned projects OR shared projects
    # - Not logged in: can see only public projects
    unless filters[:is_admin]
      if filters[:current_user_id].present?
        # User is logged in - can see public, owned, or shared projects
        search_definition[:query][:bool][:filter] << {
          bool: {
            should: [
              { term: { public: true } },
              { term: { user_id: filters[:current_user_id] } },
              { terms: { shared_user_ids: [filters[:current_user_id]] } }
            ],
            minimum_should_match: 1
          }
        }
      else
        # Not logged in - can only see public projects
        search_definition[:query][:bool][:filter] << {
          term: { public: true }
        }
      end
    end

    # Sorting
    case filters[:sort]
    when 'name'
      search_definition[:sort] << { name: { order: 'asc' } }
    when 'created_at'
      search_definition[:sort] << { created_at: { order: 'desc' } }
    when 'updated_at'
      search_definition[:sort] << { updated_at: { order: 'desc' } }
    when 'views'
      search_definition[:sort] << { nber_views: { order: 'desc' } }
    else
      search_definition[:sort] << { created_at: { order: 'desc' } }
    end

    # Execute search
    begin
      result = __elasticsearch__.search(search_definition)
      result
    rescue => e
      Rails.logger.error "Elasticsearch search failed: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      # Return empty result if Elasticsearch fails
      OpenStruct.new(
        records: [],
        response: { 'hits' => { 'total' => { 'value' => 0 } }, 'aggregations' => {} }
      )
    end
  end
  
  # Index data for Elasticsearch.
  # Technology and tissue are pulled from ComplianceMapping / ComplianceTermReplacement
  # records (the actively maintained resolved terms) rather than the legacy Project columns.
  def as_indexed_json(options = {})
    {
      name: respond_to?(:name) ? (name || '') : '',
      key: respond_to?(:key) ? (key || '') : '',
      description: respond_to?(:description) ? (description || '') : '',
      technology: compliance_term_names_for('technology'),
      project_type_name: project_type&.name || '',
      tissue: compliance_term_names_for('tissue'),
      organism_name: organism&.name || '',
      status_name: status&.name || '',
      public: respond_to?(:public) ? (public || false) : false,
      being_deleted: respond_to?(:being_deleted) ? (being_deleted || false) : false,
      created_at: respond_to?(:created_at) ? created_at : nil,
      updated_at: respond_to?(:updated_at) ? updated_at : nil,
      nber_cols: respond_to?(:nber_cols) ? (nber_cols || 0) : 0,
      nber_rows: respond_to?(:nber_rows) ? (nber_rows || 0) : 0,
      nber_views: respond_to?(:nber_views) ? (nber_views || 0) : 0,
      nber_cloned: respond_to?(:nber_cloned) ? (nber_cloned || 0) : 0,
      disk_size: respond_to?(:disk_size) ? (disk_size || 0) : 0,
      user_id: user_id,
      owner_email: user&.email || '',
      shared_user_ids: shares.pluck(:user_id).compact
    }
  end

  # Collect distinct term names for a given OntologyTermType name
  # (e.g. 'technology', 'tissue') by reading the Annot record whose name
  # matches the label_path (human-readable values, e.g. '/col_attrs/assay').
  # The Annot's list_cat_json contains the final distinct values in the loom.
  # Returns an array of strings suitable for Elasticsearch keyword fields.
  def compliance_term_names_for(ott_name)
    ott = OntologyTermType.find_by(name: ott_name)
    return [] unless ott

    path = ott.label_path.presence || ott.term_path
    return [] unless path

    annot = if annots.loaded?
      annots.select { |a| a.name == path && a.latest_version }
            .max_by { |a| a.version_nber || 0 }
    else
      annots.where(name: path, latest_version: true)
            .order(version_nber: :desc)
            .first
    end
    return [] unless annot&.list_cat_json.present?

    parsed = JSON.parse(annot.list_cat_json)
    Array(parsed)
      .flat_map { |v| v.to_s.split(' || ') }
      .map { |v| normalize_term(v.strip) }
      .reject(&:blank?)
      .uniq
  rescue JSON::ParserError
    []
  end

  # Normalize a term value for consistent indexing.
  # Replaces underscores with spaces so that legacy snake_case values
  # (e.g. "malpighian_tubule") align with compliance-fixed values
  # (e.g. "Malpighian tubule").
  # Discards purely numeric values (e.g. "0") that are data artifacts.
  def normalize_term(value)
    normalized = value.tr('_', ' ')
    return '' if normalized.match?(/\A\d+(\.\d+)?\z/)
    normalized
  end

  # Use the project key in all generated URLs (e.g. /projects/my_key instead of /projects/123).
  # The controller's set_project already resolves by key, numeric ID, or public_id.
  def to_param
    key.presence || id.to_s
  end

  # Instance methods
  
  def public_key
    return (self.public == true) ? ("ASAP" + self.public_id.to_s) : nil
  end

  def display_name
    name.presence || key.presence || "Project #{id}"
  end

  def version_for_catalog
    if version_id.present?
      version.presence || Version.find_by(id: version_id)
    else
      nil
    end
  end

  def asap_docker_image_for_catalog
    v = version_for_catalog
    v ? Basic.get_asap_docker(v) : nil
  end

  def catalog_steps
    v = version_for_catalog
    img = asap_docker_image_for_catalog
    return Step.none unless v && img

    Step.where(version_id: v.id, docker_image_id: img.id)
  end

  def catalog_std_methods(include_obsolete: false)
    v = version_for_catalog
    img = asap_docker_image_for_catalog
    return StdMethod.none unless v && img

    rel = StdMethod.where(version_id: v.id, docker_image_id: img.id)
    rel = rel.where(obsolete: false) unless include_obsolete
    rel
  end

  def broadcast(step_id)
    ProjectBroadcastJob.perform_later(id, step_id)
  end

  def storage_dir
    Pathname.new(ENV.fetch('USER_DATA_DIR')) + user_id.to_s + key
  end

  # Matches the idea in Basic.unarchive: directory must exist and have more than ~10KB of content.
  # An empty or placeholder directory is treated as missing so we still queue unarchive from S3.
  def filesystem_project_data_present?
    dir = storage_dir
    return false unless File.directory?(dir)

    du_line = `du -sk #{Shellwords.escape(dir.to_s)} 2>/dev/null`.strip
    kb = du_line.split(/\s+/, 2).first.to_i
    kb > 10
  end

  def filesystem_project_data_missing?
    !filesystem_project_data_present?
  end

  def archive_file_path
    Pathname.new("#{storage_dir}.tgz")
  end

  # True when missing local files likely mean data lives in S3/archive, not a brand-new project still being created.
  def archive_restore_expected?
    disk_size_archived.present? || (archive_file_path.exist? && archive_file_path.size.to_i.positive?)
  end

  def integration_in_progress?
    return false unless Basic.integration_project?(parsing_attrs_json)

    v = version
    return true unless v

    asap_docker_image = Basic.get_asap_docker(v)
    return true unless asap_docker_image

    parsing_step = Step.where(docker_image_id: asap_docker_image.id, version_id: version_id, name: 'parsing').first
    return true unless parsing_step

    project_step = ProjectStep.find_by(project_id: id, step_id: parsing_step.id)
    return true unless project_step

    [1, 2].include?(project_step.status_id)
  end

  def archived_on_s3?
    archive_status_id == 3
  end

  def being_archived?
    archive_status_id == 2
  end

  def being_unarchived?
    archive_status_id == 4
  end

  # Client-facing archive/unarchive state derived from the database and filesystem truth.
  # Used by the ProjectChannel initial snapshot and the unarchive_status polling
  # endpoint so pending overlays can recover when a one-shot ActionCable broadcast
  # is missed (e.g. the job finished before the browser subscribed).
  def unarchive_client_state
    case archive_status_id
    when 2
      'archiving'
    when 3
      'archived'
    when 4
      archive_file = archive_file_path
      archive_file.exist? && archive_file.size.to_i.positive? ? 'unpacking' : 'in_progress'
    else
      filesystem_project_data_present? ? 'completed' : 'archived'
    end
  end

  # UI: +archive_status_id+ is what jobs and Basic.unarchive use. Rows in +archive_statuses+ can have
  # mismatched +name+ / +icon_class+ after imports or legacy data; do not trust them for tooltips/icons.
  ARCHIVE_STATE_DISPLAY = {
    1 => { label: 'Unarchived', icon: 'fas fa-file' },
    2 => { label: 'Archiving', icon: 'fas fa-spinner fa-spin' },
    3 => { label: 'Archived', icon: 'fas fa-file-zipper' },
    4 => { label: 'Unarchiving', icon: 'fas fa-spinner fa-spin' }
  }.freeze
  ARCHIVE_METADATA_FIELDS = %w[archive_status_id disk_size_archive disk_size_archived].freeze

  def archive_status_label_for_display
    ARCHIVE_STATE_DISPLAY.dig(archive_status_id, :label) || archive_status&.display_name.presence || 'Unknown'
  end

  def archive_status_icon_class_for_display
    if ARCHIVE_STATE_DISPLAY.key?(archive_status_id)
      ARCHIVE_STATE_DISPLAY[archive_status_id][:icon]
    else
      archive_status&.icon_class
    end
  end

  # Canonical UI state for archive-related project availability.
  # Keeps true archive states separate from plain filesystem drift/missing data.
  def archive_availability_state
    return :archiving if archive_status_id == 2
    return :unarchiving if archive_status_id == 4
    return :archived if archive_status_id == 3
    return :archived if filesystem_project_data_missing? && archive_restore_expected?
    return :missing if filesystem_project_data_missing?

    :available
  end

  # Update archive bookkeeping fields without bumping updated_at.
  # This keeps "last updated" semantics tied to meaningful project content changes.
  def update_archive_metadata!(attrs)
    attrs = attrs.to_h.stringify_keys
    invalid_keys = attrs.keys - ARCHIVE_METADATA_FIELDS
    if invalid_keys.any?
      raise ArgumentError, "Unsupported archive metadata fields: #{invalid_keys.join(', ')}"
    end

    update_columns(attrs)
  end

  # When DB state does not match the local USER_DATA_DIR tree (e.g. DB from production but files from dev,
  # or the opposite), align archive_status with whether the project directory exists.
  # Does not run when archive_status_id is 2 (being archived) or 4 (being unarchived); those are handled
  # by archive/unarchive jobs and projects:rescue_archive_states.
  def reconcile_archive_status_with_filesystem!
    with_lock do
      reload
      return false if [2, 4].include?(archive_status_id)

      data_present = filesystem_project_data_present?
      effective_unarchived = archive_status_id.nil? || archive_status_id == 1

      if data_present && archived_on_s3?
        Rails.logger.info(
          "[Project#reconcile_archive_status_with_filesystem!] Project #{id} (#{key}): folder present but status was archived; setting unarchived"
        )
        update_archive_metadata!(archive_status_id: 1, disk_size_archived: nil)
        true
      elsif !data_present && effective_unarchived && archive_restore_expected?
        Rails.logger.info(
          "[Project#reconcile_archive_status_with_filesystem!] Project #{id} (#{key}): project data missing or empty but status was unarchived; setting archived"
        )
        update_archive_metadata!(archive_status_id: 3)
        true
      else
        false
      end
    end
  end

  def queue_unarchive_if_needed!
    with_lock do
      reload
      effective_unarchived = archive_status_id.nil? || archive_status_id == 1
      if effective_unarchived && disk_size_archived.present? && filesystem_project_data_missing?
        update_archive_metadata!(archive_status_id: 3)
      end

      if being_unarchived?
        stale_unarchive = updated_at.present? && updated_at < 15.minutes.ago
        return false unless stale_unarchive
        update_archive_metadata!(archive_status_id: 3)
      end

      return false unless archived_on_s3?

      update_archive_metadata!(archive_status_id: 4)
      ProjectUnarchiveJob.perform_later(id)
      true
    end
  end

  def integrate
    logger = Rails.logger
    v = self.version
    unless v
      logger.error("[Project#integrate] Project #{self.id} has no version")
      return
    end

    h_env = Basic.safe_parse_json(v.env_json, {})
    asap_docker_image = Basic.get_asap_docker(v)
    unless asap_docker_image
      logger.error("[Project#integrate] Could not find ASAP docker image for version #{v.id}")
      return
    end

    parsing_step = Step.where(docker_image_id: asap_docker_image.id, version_id: version_id, name: 'parsing').first
    unless parsing_step
      logger.error("[Project#integrate] Could not find parsing step for docker image #{asap_docker_image.id}")
      return
    end

    parsing_std_method = StdMethod.where(docker_image_id: asap_docker_image.id, version_id: version_id, name: 'integration').first

    project_step = ProjectStep.find_or_create_by(project_id: self.id, step_id: parsing_step.id)

    start_time = Time.now

    user_data_dir = ENV.fetch('USER_DATA_DIR')
    project_dir = Pathname.new(user_data_dir) + self.user_id.to_s + self.key
    tmp_dir = project_dir + 'parsing'
    FileUtils.mkdir_p(tmp_dir, mode: 0777) unless File.exist?(tmp_dir)
    begin
      FileUtils.chmod(0777, tmp_dir)
    rescue => e
      logger.warn("[Project#integrate] Could not set permissions on #{tmp_dir}: #{e.message}")
    end

    # Update project step and project status to waiting
    project_step.update(status_id: 1)
    self.update(status_id: 1)

    # Build command hash matching the format used by ProjectParsingJob
    asap_instance_name = ENV.fetch('ASAP_INSTANCE_NAME', 'asap_dev')
    h_env_docker_image = h_env['docker_images']['asap_run']
    image_name = h_env_docker_image['name'] + ":" + h_env_docker_image['tag']
    docker_build = DockerBuild.find_or_create_for_image_ref!(image_name)

    h_cmd = {
      'host_name' => 'localhost',
      'container_name' => asap_instance_name + "_temp_#{self.id}",
      'docker_call' => h_env_docker_image['call'].gsub(/\#image_name/, image_name),
      'program' => "rails integrate[#{self.key}]",
      'opts' => [],
      'args' => []
    }

    h_outputs = {
      output_matrix: { "parsing/output.loom" => { types: ["num_matrix"], dataset: "matrix", row_filter: nil, col_filter: nil } },
      output_json: { "parsing/output.json" => { types: ["json_file"] } }
    }

    h_run = {
      project_id: self.id,
      step_id: parsing_step.id,
      std_method_id: parsing_std_method&.id,
      status_id: 1,
      num: 1,
      user_id: self.user_id,
      command_json: h_cmd.to_json,
      docker_build_id: docker_build.id,
      attrs_json: self.parsing_attrs_json,
      output_json: h_outputs.to_json,
      submitted_at: start_time,
      async: true
    }

    run = Run.where(project_id: self.id, step_id: parsing_step.id).first
    if run
      run.update(h_run)
    else
      run = Run.create(h_run)
    end

    # Update container_name with actual run ID
    h_cmd['container_name'] = asap_instance_name + "_" + run.id.to_s
    run.update(command_json: h_cmd.to_json)

    # Update project step details
    h_project_step = Basic.get_project_step_details(self, parsing_step.id)
    project_step.update(h_project_step)

    # Execute run through SLURM
    logger.info("[Project#integrate] Executing Run##{run.id} through SLURM via exec_run")
    Basic.exec_run(logger, run)

    logger.info("[Project#integrate] Integration Run##{run.id} queued for execution")
  end
  
  def is_public?
    public?
  end

  def publication_lock_active?
    public? && public_at.present?
  end

  def locked_from_publication?(record_or_time)
    return false unless publication_lock_active?

    created_at_value = if record_or_time.respond_to?(:created_at)
      record_or_time.created_at
    else
      record_or_time
    end
    return false if created_at_value.blank?

    created_at_value < public_at
  end
  
  def cell_count
    respond_to?(:nber_cols) ? (nber_cols || 0) : 0
  end
  
  def gene_count
    respond_to?(:nber_rows) ? (nber_rows || 0) : 0
  end
  
  def view_count
    respond_to?(:nber_views) ? (nber_views || 0) : 0
  end
  
  def clone_count
    respond_to?(:nber_cloned) ? (nber_cloned || 0) : 0
  end
  
  def technology_display
    terms = compliance_term_names_for('technology')
    terms.any? ? terms.join(', ') : "Unknown"
  end

  def tissue_display
    terms = compliance_term_names_for('tissue')
    terms.any? ? terms.join(', ') : "Unknown"
  end
  
  def organism_display
    organism&.name || "Unknown"
  end
  
  def status_display
    status&.name || "Unknown"
  end
  
  def created_date
    created_at&.strftime("%B %d, %Y") || "Unknown"
  end
  
  def updated_date
    updated_at&.strftime("%B %d, %Y") || "Unknown"
  end
  
  def disk_size_mb
    return 0 unless disk_size
    (disk_size / 1024.0 / 1024.0).round(2)
  end
  
  def landing_page_data
    return {} unless landing_page_json.present?
    JSON.parse(landing_page_json) rescue {}
  end
  
  def parse_files(h_data = {})
    # Enqueue the parsing job using ActiveJob
    # The Run object (created by ProjectParsingJob) tracks execution status
    # No need for a separate Job object
    ProjectParsingJob.perform_later(id, h_data)
  end
  
  # Check if this is a single-cell transcriptomics project
  def single_cell?
    return false unless project_type.present?
    project_type.name&.downcase&.include?('single') || 
      project_type.tag&.downcase&.include?('single') ||
      project_type_id == 1  # ID 1 is Single-cell transcriptomics
  end

  # Check if the project passes all compliance schemas that gate publishing
  # Returns true if validation has been run and passed, or if no compliance is required
  def compliance_valid?
    return true unless compliance_requires_public?

    validation = cxg_validation_result
    return false unless validation.present?
    validation['valid'] == true || validation[:valid] == true
  end

  def compliance_requires_public?
    compliance_schemas.any?(&:requires_public?)
  end

  # Get the active ComplianceSchema records for this project's type.
  # Returns an array of ComplianceSchema AR objects.
  # Views that expect a hash can call .to_config_hash on each record.
  def compliance_schemas
    tag = project_type&.tag
    return ComplianceSchema.none if tag.blank?
    ComplianceSchema.active.for_project_type(tag)
  end

  # Get the CXG validation result
  # Checks multiple storage locations in order of preference
  def cxg_validation_result
    # Try project directory first (primary storage)
    if respond_to?(:key) && respond_to?(:user_id) && key.present? && user_id.present?
      project_validation_path = File.join(
        ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
        user_id.to_s,
        key,
        'cxg_validation_result.json'
      )
      
      if File.exist?(project_validation_path)
        begin
          return JSON.parse(File.read(project_validation_path))
        rescue JSON::ParserError => e
          Rails.logger.warn("[Project] Could not parse validation result: #{e.message}")
        end
      end
    end
    
    # Fall back to fu upload directories (global staging or project/fus/<fu_id>)
    Fu.where(project_id: id).find_each do |fu|
      validation_path = File.join(fu.upload_dir.to_s, 'cxg_validation_result.json')
      next unless File.exist?(validation_path)

      begin
        return JSON.parse(File.read(validation_path))
      rescue JSON::ParserError => e
        Rails.logger.warn("[Project] Could not parse validation result: #{e.message}")
      end
    end

    nil
  end

  # Check if the project can be made public
  # Returns [can_publish, reason] tuple
  def can_be_public?
    unless compliance_valid?
      validation = cxg_validation_result
      schema_name = validation&.dig('schema_name') || compliance_schemas.first&.name || 'compliance'
      if validation.nil?
        return [false, "#{schema_name} check has not been run. Please validate your project before making it public."]
      else
        error_count = validation['errors_count'] || validation['errors']&.count || 0
        return [false, "Project does not pass #{schema_name}. Validation found #{error_count} error(s). Please fix the errors and re-validate before making it public."]
      end
    end
    [true, nil]
  end

  def from_scfair_validation?
    project_origin&.name == ProjectOrigin::SCFAIR_VALIDATION
  end

  def from_integration?
    project_origin&.name == ProjectOrigin::INTEGRATION
  end

  def from_clone?
    project_origin&.name == ProjectOrigin::CLONE
  end

  def from_upload?
    project_origin&.name == ProjectOrigin::UPLOAD
  end

  def compliance_validation_run?
    return true if cxg_validation_result.present?
    ComplianceValidation.for_project(id).exists?
  end

  # Ensure ProjectStep records exist for all steps associated with this project's docker image
  # Called lazily when needed for display (show, step_results, refresh_steps_panel)
  # Only creates ProjectStep records for steps that match the project's project type
  def ensure_project_steps
    asap_docker_image = Basic.get_asap_docker(version)
    return unless asap_docker_image
    
    Step.where(docker_image_id: asap_docker_image.id, version_id: version_id).find_each do |step|
      # Filter by project type if project has a project type
      if project_type
        step_attrs = Basic.safe_parse_json(step.attrs_json, {})
        project_types = step_attrs['project_types']
        
        # If project_types is specified and not empty, check if it includes this project's type
        if project_types.present? && project_types.any?
          project_type_name = project_type.name
          project_type_tag = project_type.tag
          next unless project_types.include?(project_type_name) || (project_type_tag.present? && project_types.include?(project_type_tag))
        end
        # If project_types is empty or missing, include the step (backward compatibility)
      end
      
      project_step = ProjectStep.find_by(project_id: id, step_id: step.id)
      unless project_step
        ProjectStep.create(
          project_id: id,
          step_id: step.id,
          status_id: (step.name == 'parsing') ? 1 : nil
        )
      end
    end
  end

  private

  def ensure_default_project_origin
    return if project_origin_id.present?

    self.project_origin_id = ProjectOrigin.id_for(ProjectOrigin::UPLOAD)
  end

  def purge_fus_for_project_destroy!
    Fu.where(project_id: id).delete_all
  end

  def remove_project_filesystem_after_destroy!
    return if key.blank?

    root = Pathname.new(ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s).cleanpath
    project_dir = data_dir.cleanpath
    archive_file = Pathname.new("#{project_dir}.tgz")

    # Only delete a project-scoped path under USER_DATA_DIR (never the root itself).
    unless project_dir.to_s.start_with?("#{root}/") && project_dir.basename.to_s == key
      Rails.logger.error(
        "[Project#remove_project_filesystem_after_destroy!] refused unsafe path " \
        "project_id=#{id} key=#{key.inspect} path=#{project_dir}"
      )
      return
    end

    if File.exist?(project_dir.to_s)
      FileUtils.rm_rf(project_dir.to_s)
      Rails.logger.info(
        "[Project#remove_project_filesystem_after_destroy!] removed #{project_dir} " \
        "(project_id=#{id} key=#{key})"
      )
    end

    if File.exist?(archive_file.to_s)
      FileUtils.rm_f(archive_file.to_s)
      Rails.logger.info(
        "[Project#remove_project_filesystem_after_destroy!] removed #{archive_file} " \
        "(project_id=#{id} key=#{key})"
      )
    end
  rescue StandardError => e
    Rails.logger.error(
      "[Project#remove_project_filesystem_after_destroy!] project_id=#{id} key=#{key.inspect} " \
      "error=#{e.class}: #{e.message}"
    )
    raise
  end

  def sanitize_non_raw_text_parsing_attrs!
    return if parsing_attrs_json.blank?

    attrs =
      begin
        parsed = JSON.parse(parsing_attrs_json)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end
    return if attrs.empty?

    file_type = attrs['file_type'].to_s
    return if file_type.blank?

    format = FileFormat.find_by(name: file_type) || FileFormat.find_by(name: file_type.upcase)
    is_raw_text = (file_type == 'RAW_TEXT') || (format && format.child_format == 'RAW_TEXT')
    return if is_raw_text

    attrs.delete('delimiter')
    attrs.delete('gene_name_col')
    attrs.delete('has_header')
    self.parsing_attrs_json = attrs.to_json
  end
end
