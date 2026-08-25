require 'json'
require 'net/http'
require 'uri'
require 'yaml'

class HomeController < ApplicationController
  skip_before_action :authenticate_user!, raise: false
  before_action :authenticate_user!, only: [:rate, :rate_submit]

  def unauthorized
    render 'shared/unauthorized', status: :forbidden
  end

  def welcome
    @welcome_news_items = NewsItem.for_welcome.ordered.limit(5)
  end

  def atlases
  end

  def atlas_projects
    @atlas = params[:atlas].to_s.downcase
    @atlas_title = atlas_title(@atlas)
    return head :not_found if @atlas_title.blank?

    @query = params[:q].to_s.strip
    @atlas_terms = atlas_terms(@atlas)

    if @atlas == 'hca'
      load_hca_atlas_catalog_groups!
    else
      load_keyword_atlas_project_groups!
    end
  end

  def api_documentation
  end

  def sitemap
  end

  def llms
    base = ENV.fetch('SERVER_URL').chomp('/')
    render plain: <<~LLMS, content_type: 'text/plain; charset=utf-8'
      # ASAP

      > ASAP (Automated Single-cell Analysis Pipeline) is a collaborative web platform for analyzing and visualizing single-cell RNA-seq and related omics data. Developed at EPFL and listed among SIB resources.

      ASAP guides users through a modular analysis pipeline on large single-cell datasets: import and parsing, filtering, normalization, clustering, differential expression, doublet calling, and interactive UMAP/t-SNE visualization. Public projects and JSON exports are available via the REST API.

      ## Getting started

      - [Welcome](#{base}/): Platform home and project browser
      - [Guided tours](#{base}/guided-tours): Interactive walkthroughs of the application
      - [FAQ](#{base}/home/faq): Frequently asked questions

      ## Documentation

      - [File formats](#{base}/home/file_format): Supported upload and export formats
      - [API documentation](#{base}/api-doc): Interactive OpenAPI reference for JSON endpoints
      - [OpenAPI spec](#{base}/api/openapi.yaml): Machine-readable API specification
      - [News](#{base}/news_items): Platform announcements and updates
      - [Releases](#{base}/versions): ASAP version history and release notes
      - [Project types](#{base}/project_types): Available pipeline types and configurations
      - [Cell metadata schema](#{base}/ontology_term_types): Cell metadata fields used for annotations
      - [Cross-references](#{base}/home/cross_references): External identifier types (GEO, ArrayExpress, BioProject, SRA)

      ## Data and atlases

      - [Public projects](#{base}/projects): Browse and clone shared analysis projects
      - [Atlases](#{base}/atlases): Fly Cell Atlas and Human Cell Atlas entry points
      - [scFAIR compliance](#{base}/compliance): Validate projects and files against scFAIR schema rules
      - [File compliance check](#{base}/compliance/file-check): Standalone H5AD/Loom compliance check

      ## Citation

      - [Citing ASAP](#{base}/home/citing): Primary publications (Bioinformatics 2017; NAR 2020) and DOIs

      ## Optional

      - [Contact](#{base}/home/contact): Reach the ASAP team
      - [Sitemap](#{base}/sitemap.xml): Full list of public URLs
      - [GitHub discussions](https://github.com/DeplanckeLab/ASAP/discussions): Community Q&A
      - [GitHub issues](https://github.com/DeplanckeLab/asap_web/issues): Bug reports and feature requests
    LLMS
  end

  def robots
    if EnvHelpers.instance_kind == 'production'
      base = ENV.fetch('SERVER_URL').chomp('/')
      render plain: <<~ROBOTS, content_type: 'text/plain'
        User-agent: *
        Allow: /
        Disallow: /annots/*/download

        Sitemap: #{base}/sitemap.xml
      ROBOTS
      return
    end

    render plain: <<~ROBOTS, content_type: 'text/plain'
      User-agent: *
      Disallow: /
    ROBOTS
  end

  def openapi_spec
    spec_path = Rails.root.join('public', 'swagger', 'openapi.yaml')
    spec = YAML.safe_load_file(spec_path, aliases: true)
    spec['servers'] = [{ 'url' => ENV.fetch('OPENAPI_SERVER_URL') }]

    render plain: spec.to_yaml, content_type: 'application/yaml'
  end

  def contact
  end

  def orcid_authentication
    authenticate_user!

    client_id = orcid_client_id
    if client_id.blank?
      redirect_to edit_user_registration_path, alert: "ORCID is not configured yet. Missing ORCID client ID."
      return
    end

    redirect_uri = orcid_redirect_uri
    query = URI.encode_www_form(
      client_id: client_id,
      response_type: 'code',
      scope: '/authenticate',
      redirect_uri: redirect_uri
    )

    redirect_to "https://orcid.org/oauth/authorize?#{query}", allow_other_host: true
  end

  def associate_orcid
    authenticate_user!

    code = params[:code].to_s
    if code.blank?
      redirect_to edit_user_registration_path, alert: "ORCID association failed: missing authorization code."
      return
    end

    client_id = orcid_client_id
    client_secret = orcid_client_secret
    if client_id.blank? || client_secret.blank?
      redirect_to edit_user_registration_path, alert: "ORCID is not configured yet. Missing ORCID client credentials."
      return
    end

    redirect_uri = orcid_redirect_uri
    token_uri = URI.parse('https://orcid.org/oauth/token')
    response = Net::HTTP.post_form(
      token_uri,
      {
        client_id: client_id,
        client_secret: client_secret,
        grant_type: 'authorization_code',
        redirect_uri: redirect_uri,
        code: code
      }
    )

    payload = JSON.parse(response.body)
    orcid_key = payload['orcid'].to_s
    orcid_name = payload['name'].to_s

    if !response.is_a?(Net::HTTPSuccess) || orcid_key.blank?
      Rails.logger.error("[ORCID] Association failed: status=#{response.code} body=#{response.body}")
      redirect_to edit_user_registration_path, alert: "ORCID association failed."
      return
    end

    orcid_user = OrcidUser.find_or_initialize_by(key: orcid_key)
    orcid_user.name = orcid_name if orcid_name.present?
    orcid_user.save!

    current_user.update!(orcid_user_id: orcid_user.id)
    redirect_to edit_user_registration_path, notice: "ORCID associated: #{orcid_user.name.presence || 'Unknown'} [#{orcid_user.key}]"
  rescue JSON::ParserError => e
    Rails.logger.error("[ORCID] Invalid token response: #{e.message}")
    redirect_to edit_user_registration_path, alert: "ORCID association failed."
  rescue StandardError => e
    Rails.logger.error("[ORCID] Unexpected error: #{e.class} - #{e.message}")
    redirect_to edit_user_registration_path, alert: "ORCID association failed."
  end

  def contact_submit
    subject = params[:subject].to_s.strip
    body = params[:body].to_s.strip
    sender_email = if current_user
                     current_user.email
                   else
                     params[:email].to_s.strip
                   end

    if subject.blank? || body.blank?
      flash.now[:alert] = "Please fill in both the subject and the message."
      render :contact, status: :unprocessable_entity
      return
    end

    if sender_email.blank? || !sender_email.match?(URI::MailTo::EMAIL_REGEXP)
      flash.now[:alert] = "Please provide a valid email address."
      render :contact, status: :unprocessable_entity
      return
    end

    attachments_data = []
    if params[:attachments].present?
      Array(params[:attachments]).each do |file|
        next unless file.respond_to?(:read)
        attachments_data << {
          filename: file.original_filename,
          content_type: file.content_type,
          content: file.read
        }
      end
    end

    begin
      ContactMailer.contact_email(
        sender_email: sender_email,
        subject: subject,
        body: body,
        attachments_data: attachments_data
      ).deliver_now

      flash[:notice] = "Your message has been sent. Thank you for your feedback!"
    rescue KeyError, ArgumentError => e
      Rails.logger.error("[ContactForm] Invalid mail configuration: #{e.class} - #{e.message}")
      flash[:alert] = "Contact form is temporarily unavailable. Please email us directly at bioinfo.epfl@gmail.com."
    rescue => e
      Rails.logger.error("[ContactForm] Failed to send email: #{e.class} - #{e.message}")
      flash[:alert] = "Failed to send your message. Please try again later or email us directly."
    end
    redirect_to contact_home_index_path
  end


  def file_format
    @h_formats = FileFormat.all.index_by(&:name)
    # This uses ActiveRecord's index_by method which is more efficient
    # than manually mapping and creating a hash
  end

  def cross_references
    @featured_identifier_names = [
      "GEO Series",
      "ArrayExpress Experiment",
      "BioProject",
      "SRA Study"
    ]
    @identifier_types_by_name = IdentifierType
                                  .where(name: @featured_identifier_names)
                                  .index_by(&:name)
  end

  def cross_references_admin
    @identifier_types = IdentifierType.order(Arel.sql("LOWER(name) ASC"))
  end

  def tutorial
    
    @h_tutos = {
      'getting_started' => "Tutorial 1 : Getting started - Welcome to ASAP!",
      'full_pipeline' => "Tutorial 2 : Full pipeline on a project imported from the Human Cell Atlas",
      'cell_ranger' => "Tutorial 3 : How to import data from 10x [from CellRanger output]",
      'loom' => "Tutorial 4 : How to work with Loom files created by ASAP",
      'out_of_ram' => "Tutorial 5 : How to best select methods for avoiding out-of-RAM errors",
      'fca' => "Tutorial 6: How to use the visualization tools for interacting with the UMAP/t-SNE plots. An example using the Fly Cell Atlas"
      #,                                                                                                                                                                                                                        
      #      'importing_data' => "Importing data",                                                                                                                                                                              
      #      'project_details' => "Editing project details",                                                                                                                                                                    
      #      'public_projects' => "How to make your project public"                                                                                                                                                             
    }
    @h_icons = {
      'full_pipeline' => ['hca_logo.jpg', 'https://www.humancellatlas.org/'],
      'fca' => ['fca_logo.png', 'https://flycellatlas.org']
    }
    if params[:t]
      render "tutorial"
    else
      render "tutorial_list"
    end

  end

  def guided_tours
    @guided_tours = GuidedTour
      .visible
      .ordered
      .includes(:guided_tour_steps)
  end

  def rate
    @rating = current_user.ratings.order(created_at: :desc).first
  end

  def rate_submit
    stars = params[:stars].to_i
    review = params[:review].to_s.strip

    if stars < 1 || stars > 5
      flash[:alert] = "Please select a rating between 1 and 5 stars."
      redirect_to rate_home_index_path
      return
    end

    rating = current_user.ratings.build(
      stars: stars,
      review: review.presence,
      display_publicly: params[:display_publicly] == '1',
      use_for_funding: params[:use_for_funding] == '1'
    )

    if rating.save
      flash[:notice] = "Thank you for rating ASAP!"
    else
      flash[:alert] = "Something went wrong. Please try again."
    end
    redirect_to rate_home_index_path
  end

  def faq
  end

  def citing
  end

  private

  def orcid_client_id
    Rails.application.credentials.dig(:orcid, :client_id).to_s.presence ||
      ENV['ORCID_CLIENT_ID'].to_s.presence
  end

  def orcid_client_secret
    Rails.application.credentials.dig(:orcid, :client_secret).to_s.presence ||
      ENV['ORCID_CLIENT_SECRET'].to_s.presence
  end

  def orcid_redirect_uri
    Rails.application.credentials.dig(:orcid, :redirect_uri).to_s.presence ||
      ENV['ORCID_REDIRECT_URI'].to_s.presence ||
      associate_orcid_url
  end

  def atlas_title(atlas_key)
    case atlas_key
    when 'fca'
      'Fly Cell Atlas'
    when 'hca'
      'Human Cell Atlas'
    end
  end

  def atlas_terms(atlas_key)
    case atlas_key
    when 'fca'
      ['fca', 'fly cell atlas', 'flycellatlas']
    when 'hca'
      ['hca', 'human cell atlas', 'humancellatlas']
    else
      []
    end
  end

  def load_keyword_atlas_project_groups!
    base_scope = Project
      .where(being_deleted: false)
      .where(public: true)
      .where(cloned_project_id: nil)
      .left_joins(:project_collection)

    atlas_filter_sql = searchable_project_fields_sql
    atlas_conditions = @atlas_terms.map { "#{atlas_filter_sql} LIKE ?" }.join(' OR ')
    atlas_values = @atlas_terms.map { |term| "%#{ActiveRecord::Base.sanitize_sql_like(term.downcase)}%" }
    base_scope = base_scope.where([atlas_conditions, *atlas_values])

    if @query.present?
      query_value = "%#{ActiveRecord::Base.sanitize_sql_like(@query.downcase)}%"
      base_scope = base_scope.where("#{atlas_filter_sql} LIKE ?", query_value)
    end

    @projects = base_scope
      .includes(:project_type, :organism, :archive_status, :user, :project_collection)
      .order(Arel.sql('public_id ASC NULLS LAST'), Arel.sql("LOWER(COALESCE(projects.name, '')) ASC"), id: :asc)
      .limit(200)
      .to_a

    @atlas_uses_catalog_collections = false
    @project_collection_groups = group_atlas_projects_by_collection(@projects)
  end

  # HCA: unique ASAP projects under each external_catalog_collection, with linked catalog entries.
  def load_hca_atlas_catalog_groups!
    @atlas_uses_catalog_collections = true
    collections = ExternalCatalogCollection.for_source('hca').ordered_by_title.includes(:external_catalog_candidates)
    groups = []
    projects_seen = []

    collections.each do |collection|
      candidates = collection.external_catalog_candidates.select { |c| !c.obsolete? }
      next if candidates.empty?

      project_to_entries = hca_projects_with_entries_for_candidates(candidates)
      next if project_to_entries.empty?

      rows = project_to_entries.map do |project, entries|
        {
          project: project,
          catalog_entries: entries
        }
      end

      if @query.present?
        q = @query.downcase
        rows = rows.select do |row|
          project = row[:project]
          haystack = [
            project.name, project.key, project.description,
            collection.title, collection.description,
            *row[:catalog_entries].map { |e| [e.title, e.external_id, e.filename] }
          ].flatten.compact.map { |v| v.to_s.downcase }.join(' ')
          haystack.include?(q)
        end
      end
      next if rows.empty?

      rows.sort_by! do |row|
        p = row[:project]
        [p.public_id || 1_000_000_000, p.name.to_s.downcase, p.id]
      end

      projects_seen.concat(rows.map { |r| r[:project] })
      groups << {
        collection: collection,
        title: collection.display_title,
        description: collection.description.to_s.presence,
        project_rows: rows,
        projects: rows.map { |r| r[:project] }
      }
    end

    @project_collection_groups = groups.first(100)
    @projects = projects_seen.uniq(&:id)
  end

  def hca_projects_with_entries_for_candidates(candidates)
    result = Hash.new { |h, k| h[k] = [] }
    provider = Provider.find_by(tag: 'HCA')

    candidates.each do |candidate|
      projects = []
      if candidate.import_project_id.present? && candidate.import_project && !candidate.import_project.being_deleted
        projects << candidate.import_project if candidate.import_project.public?
      end
      if provider
        pp = ProviderProject.find_by(provider_id: provider.id, key: candidate.external_id.to_s)
        if pp
          projects.concat(pp.projects.where(public: true, being_deleted: [false, nil]).to_a)
        end
      end
      projects.uniq(&:id).each do |project|
        result[project] << candidate unless result[project].any? { |c| c.id == candidate.id }
      end
    end
    result
  end

  def searchable_project_fields_sql
    "LOWER(" \
      "COALESCE(projects.name, '') || ' ' || " \
      "COALESCE(projects.key, '') || ' ' || " \
      "COALESCE(projects.description, '') || ' ' || " \
      "COALESCE(project_collections.title, '') || ' ' || " \
      "COALESCE(project_collections.description, '')" \
    ")"
  end

  def group_atlas_projects_by_collection(projects)
    grouped = projects.group_by(&:project_collection_id)
    collections_by_id = projects.filter_map(&:project_collection).uniq(&:id).index_by(&:id)

    collection_sections =
      collections_by_id.values
        .sort_by { |c| [c.display_title.to_s.downcase, c.id] }
        .map do |collection|
          {
            collection: collection,
            title: collection.display_title,
            description: collection.description.to_s.presence,
            projects: grouped[collection.id] || [],
            project_rows: (grouped[collection.id] || []).map { |p| { project: p, catalog_entries: [] } }
          }
        end

    ungrouped = grouped[nil] || []
    if ungrouped.any?
      collection_sections << {
        collection: nil,
        title: 'Ungrouped',
        description: 'Public projects that are not assigned to a collection.',
        projects: ungrouped,
        project_rows: ungrouped.map { |p| { project: p, catalog_entries: [] } }
      }
    end
    collection_sections
  end
end
