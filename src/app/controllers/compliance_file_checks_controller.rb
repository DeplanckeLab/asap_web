# frozen_string_literal: true

class ComplianceFileChecksController < ApplicationController
  skip_before_action :authenticate_user!, raise: false

  MAX_UPLOAD_SIZE = 2.gigabytes
  ALLOWED_EXTENSIONS = %w[.loom .h5ad].freeze

  def index
    @available_schemas = Scfair::CheckCatalog.available_schemas
    @default_schema_id = @available_schemas.first[:id]
  end

  def create
    uploaded = params[:data_file]
    schema_id = params[:schema_id].to_s

    unless uploaded.respond_to?(:original_filename)
      render json: { error: 'No file provided' }, status: :unprocessable_entity
      return
    end

    ext = File.extname(uploaded.original_filename.to_s).downcase
    unless ALLOWED_EXTENSIONS.include?(ext)
      render json: { error: 'File must be .loom or .h5ad' }, status: :unprocessable_entity
      return
    end

    begin
      Scfair::CheckCatalog.schema!(schema_id)
    rescue ArgumentError => e
      render json: { error: e.message }, status: :unprocessable_entity
      return
    end

    size = uploaded.size.to_i
    if size <= 0 || size > MAX_UPLOAD_SIZE
      render json: { error: "Invalid file size (max #{MAX_UPLOAD_SIZE / 1.gigabyte}GB)" }, status: :unprocessable_entity
      return
    end

    task_id = SecureRandom.uuid
    shared_root = ENV['UPLOAD_DATA_DIR'].presence || ENV['USER_DATA_DIR'].presence || '/data/asap2/fus'
    tmp_dir = File.join(shared_root, 'isolated_compliance_uploads')
    FileUtils.mkdir_p(tmp_dir)
    safe_name = "#{task_id}#{ext}"
    tmp_path = File.join(tmp_dir, safe_name)

    File.open(tmp_path, 'wb') { |f| f.write(uploaded.read) }

    initial = {
      status: 'queued',
      task_id: task_id,
      progress: 0,
      message: 'Validation queued'
    }
    IsolatedComplianceStatusStore.write(task_id, initial)
    IsolatedComplianceValidationJob.perform_later(task_id, tmp_path, schema_id, uploaded.original_filename.to_s)

    render json: {
      task_id: task_id,
      status: 'queued',
      filename: uploaded.original_filename.to_s,
      schema_id: schema_id
    }
  rescue StandardError => e
    render json: { error: "Unable to queue validation: #{e.message}" }, status: :internal_server_error
  end

  def status
    task_id = params[:task_id].to_s
    payload = IsolatedComplianceStatusStore.read(task_id)
    if payload
      render json: payload
    else
      render json: { error: 'Task not found' }, status: :not_found
    end
  end
end

