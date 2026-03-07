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
end
