class ComplianceFileChecksController < ApplicationController
  skip_before_action :authenticate_user!, raise: false

  IN_PROGRESS_FU_STATUSES = %w[downloading validating].freeze

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

  # GET /compliance/checks?source_url=... and/or ?filename=...
  # GET /api/compliance/checks?source_url=...[&recheck=1]
  # API: URL-only lookup. Returns stored results when present; with recheck=1 or when
  # no results exist yet, queues download+validation and returns 202 until complete.
  def lookup
    if api_compliance_lookup?
      api_lookup
    else
      public_lookup
    end
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

    payload = enqueue_url_validation!(url: url, schema_id: schema_id)
    render json: payload
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

  private

  def api_compliance_lookup?
    request.path.start_with?('/api/')
  end

  def public_lookup
    source_url = params[:source_url].to_s.strip.presence
    filename = params[:filename].to_s.strip.presence
    if source_url.blank? && filename.blank?
      render json: { error: 'Provide source_url and/or filename' }, status: :unprocessable_entity
      return
    end

    check = StandaloneComplianceCheck.latest_matching(
      source_url: source_url,
      filename: filename
    ).first

    unless check
      render json: { error: 'No matching compliance check found' }, status: :not_found
      return
    end

    render_check_lookup_payload(check)
  end

  def api_lookup
    source_url = params[:source_url].to_s.strip.presence
    if source_url.blank?
      render json: { error: 'Provide source_url (API lookup is URL-only)' }, status: :unprocessable_entity
      return
    end

    recheck = ActiveModel::Type::Boolean.new.cast(params[:recheck])
    unless recheck
      check = StandaloneComplianceCheck.latest_matching(source_url: source_url).first
      if check
        render_check_lookup_payload(check)
        return
      end

      in_progress = find_in_progress_compliance_fu(source_url)
      if in_progress
        render_api_validation_accepted(in_progress)
        return
      end
    end

    schema_id = params[:schema_id].presence || Scfair::Rules::DEFAULT_SCHEMA_ID
    payload = enqueue_url_validation!(url: source_url, schema_id: schema_id)
    render json: api_validation_accepted_payload(payload.merge(source_url: source_url)),
           status: :accepted
  rescue URI::InvalidURIError
    render json: { error: 'Invalid URL' }, status: :unprocessable_entity
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue StandardError => e
    render json: { error: "Unable to queue validation: #{e.message}" }, status: :internal_server_error
  end

  def render_check_lookup_payload(check)
    payload = {
      id: check.id,
      task_id: check.task_id,
      filename: check.filename,
      source_url: check.source_url,
      schema_id: check.schema_id,
      format: check.format,
      passed: check.passed,
      status: check.status,
      checked_at: check.checked_at,
      admin_run: check.admin_run,
      result: check.result_json
    }

    if ActiveModel::Type::Boolean.new.cast(params[:download])
      send_data payload.to_json,
                filename: "scfair_compliance_check_#{check.id}.json",
                type: 'application/json; charset=utf-8',
                disposition: 'attachment'
    else
      render json: payload
    end
  end

  def find_in_progress_compliance_fu(source_url)
    upload_type_id = UploadType.id_for('compliance_file_check')
    return nil if upload_type_id.blank?

    Fu.where(url: source_url, upload_type: upload_type_id)
      .where(status: IN_PROGRESS_FU_STATUSES)
      .where.not(compliance_task_id: [nil, ''])
      .order(id: :desc)
      .first
  end

  def render_api_validation_accepted(fu)
    task_id = fu.compliance_task_id
    status_payload = IsolatedComplianceStatusStore.read(task_id).presence || {
      status: fu.status,
      task_id: task_id,
      fu_id: fu.id
    }
    render json: api_validation_accepted_payload(
      status_payload.merge(
        task_id: task_id,
        status: status_payload[:status] || status_payload['status'] || fu.status,
        schema_id: fu.compliance_schema_id,
        fu_id: fu.id,
        source_url: fu.url
      )
    ), status: :accepted
  end

  def api_validation_accepted_payload(payload)
    task_id = payload[:task_id] || payload['task_id']
    {
      task_id: task_id,
      status: payload[:status] || payload['status'],
      schema_id: payload[:schema_id] || payload['schema_id'],
      fu_id: payload[:fu_id] || payload['fu_id'],
      source_url: payload[:source_url] || payload['source_url'],
      status_url: "/compliance/file-check/#{task_id}/status",
      message: 'Validation in progress; poll status_url or this endpoint until results are available'
    }.compact
  end

  def enqueue_url_validation!(url:, schema_id:)
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

    {
      task_id: task_id,
      status: 'downloading',
      schema_id: schema_id,
      fu_id: fu.id
    }
  end
end
