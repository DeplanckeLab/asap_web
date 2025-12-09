class Project < ApplicationRecord
  include Elasticsearch::Model
  include Elasticsearch::Model::Callbacks

  # Associations
  belongs_to :user, optional: true
  belongs_to :organism, optional: true
  belongs_to :status, optional: true
  belongs_to :step, optional: true
  belongs_to :project_type, optional: true
  belongs_to :project_cell_set, optional: true
  belongs_to :version, optional: true
  belongs_to :archive_status, optional: true
  belongs_to :cloned_project, class_name: 'Project', foreign_key: 'cloned_project_id', optional: true
  has_many :annots, dependent: :destroy
  has_many :reqs, dependent: :destroy
  has_many :runs, dependent: :destroy
  has_many :project_steps, dependent: :destroy
  has_many :shares, dependent: :destroy
  has_many :projects_provider_projects, dependent: :destroy
  has_many :provider_projects, through: :projects_provider_projects
  has_many :articles_projects, dependent: :destroy
  has_many :articles, through: :articles_projects
  has_many :exp_entries_projects, dependent: :destroy
  has_many :exp_entries, through: :exp_entries_projects
  
  # Elasticsearch settings
  settings index: { number_of_shards: 1 } do
    mappings dynamic: 'false' do
      indexes :name, type: 'text', analyzer: 'english'
      indexes :key, type: 'text', analyzer: 'english'
      indexes :description, type: 'text', analyzer: 'english'
      indexes :technology, type: 'keyword'
      indexes :tissue, type: 'keyword'
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
      aggs: {
        organisms: { terms: { field: 'organism_name' } },
        technologies: { terms: { field: 'technology' } },
        tissues: { terms: { field: 'tissue' } },
        statuses: { terms: { field: 'status_name' } }
      },
      size: 20,
      from: 0
    }

    # Add pagination
    if filters[:page].present?
      page = filters[:page].to_i
      search_definition[:from] = (page - 1) * search_definition[:size]
    end

    # Text search
    if query.present?
      search_definition[:query][:bool][:must] << {
        multi_match: {
          query: query,
          fields: ['name^3', 'key^2', 'description', 'technology'],
          type: 'best_fields',
          fuzziness: 'AUTO'
        }
      }
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

    if filters[:technology].present?
      search_definition[:query][:bool][:filter] << {
        term: { technology: filters[:technology] }
      }
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

    if filters[:public_only] == 'true'
      search_definition[:query][:bool][:filter] << {
        term: { public: true }
      }
    end

    # Always filter out deleted projects
    search_definition[:query][:bool][:filter] << {
      term: { being_deleted: false }
    }

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

  # Index data for Elasticsearch
  def as_indexed_json(options = {})
    {
      name: respond_to?(:name) ? (name || '') : '',
      key: respond_to?(:key) ? (key || '') : '',
      description: respond_to?(:description) ? (description || '') : '',
      technology: respond_to?(:technology) ? (technology || '') : '',
      tissue: respond_to?(:tissue) ? (tissue || '') : '',
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
      disk_size: respond_to?(:disk_size) ? (disk_size || 0) : 0
    }
  end

  # Instance methods
  def display_name
    name.presence || key.presence || "Project #{id}"
  end

  def broadcast(step_id)
    ProjectBroadcastJob.perform_later(id, step_id)
  end
  
  def is_public?
    public?
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
    technology.presence || "Unknown"
  end
  
  def tissue_display
    tissue.presence || "Unknown"
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
    # Create a job record for tracking
    job = Basic.create_job(self, 1, self, :parsing_job_id, 1)
    
    # Enqueue the parsing job using ActiveJob
    parsing_job = ProjectParsingJob.perform_later(id, h_data)
    
    # Update job with the ActiveJob job_id if available
    if parsing_job.respond_to?(:job_id)
      job.update(delayed_job_id: parsing_job.job_id) if job
    end
    
    job
  end
end
