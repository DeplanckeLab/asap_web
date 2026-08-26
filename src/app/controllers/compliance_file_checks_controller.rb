class ComplianceFileChecksController < ApplicationController
  skip_before_action :authenticate_user!, raise: false

  def rules_snippet
    path = params[:path].to_s.strip
    result = Scfair::RulesSnippetExtractor.call(path, schema_id: params[:schema_id])
    if result[:error]
      render json: result, status: :not_found
    else
      render json: result
    end
  end

  def rules_yaml
    render json: Scfair::RulesYamlDocument.call(schema_id: params[:schema_id])
  end

  def index
    @available_schemas = Scfair::CheckCatalog.available_schemas
    @default_schema_id = Scfair::Rules::DEFAULT_SCHEMA_ID
  end

  def create
    schema_id = params[:schema_id].presence || Scfair::Rules::DEFAULT_SCHEMA_ID
    source = params[:source].to_s
    raise ArgumentError, 'Browser uploads use chunked upload via /fus/upload_chunk' if source.blank? || source == 'upload'

    url = params[:data_url].to_s.strip
    raise ArgumentError, 'No URL provided' if url.blank?

    uri = URI.parse(url)
    raise ArgumentError, 'Only HTTP/HTTPS URLs are supported' unless uri.is_a?(URI::HTTP)

    task_id = SecureRandom.uuid
    original_filename = File.basename(uri.path).presence || 'remote_file'
    upload_type_id = UploadType.id_for('compliance_file_check')
    raise ArgumentError, 'compliance_file_check upload type is missing' if upload_type_id.blank?

    fu = Fu.create!(
      upload_file_name: 'pending.download',
      upload_file_size: 0,
      name: original_filename,
      status: 'downloading',
      upload_type: upload_type_id,
      user_id: current_user&.id,
      project_key: current_user ? nil : session[:sandbox],
      url: uri.to_s,
      compliance_schema_id: schema_id,
      compliance_task_id: task_id,
      admin_run: admin?,
      creator_ip: request_creator_ip
    )

    initial = {
      status: 'downloading',
      task_id: task_id,
      progress: 0,
      transfer_progress: 0,
      message: 'Downloading file...',
      fu_id: fu.id
    }
    IsolatedComplianceStatusStore.write(task_id, initial)
    IsolatedComplianceUrlDownloadJob.perform_later(fu.id)

    render json: {
      task_id: task_id,
      status: 'downloading',
      schema_id: schema_id,
      fu_id: fu.id
    }
  rescue URI::InvalidURIError
    render json: { error: 'Invalid URL' }, status: :unprocessable_entity
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
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
