require 'json'
require 'net/http'
require 'uri'

class HomeController < ApplicationController
  skip_before_action :authenticate_user!, raise: false
  before_action :authenticate_user!, only: [:contact, :contact_submit, :rate, :rate_submit]

  def unauthorized
    render 'shared/unauthorized'
  end

  def welcome
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

    if subject.blank? || body.blank?
      flash[:alert] = "Please fill in both the subject and the message."
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
        sender_email: current_user.email,
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
end
