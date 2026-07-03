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

    task_id = SecureRandom.uuid
    tmp_path = download_remote_file!(task_id)
    detected_format = ComplianceFileCheckQueueService.validate_downloaded_file!(tmp_path)
    final_path = rename_downloaded_file!(tmp_path, task_id, detected_format)

    initial = {
      status: 'queued',
      task_id: task_id,
      progress: 45,
      message: 'Validation queued'
    }
    IsolatedComplianceStatusStore.write(task_id, initial)
    IsolatedComplianceValidationJob.perform_later(task_id, final_path, schema_id, File.basename(final_path))

    render json: {
      task_id: task_id,
      status: 'queued',
      filename: File.basename(final_path),
      schema_id: schema_id
    }
  rescue ComplianceFileCheckQueueService::UnsupportedFormatError => e
    render json: unsupported_format_error_json(e.message), status: :unprocessable_entity
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

  def temp_dir
    shared_root = ENV['UPLOAD_DATA_DIR'].presence || ENV['USER_DATA_DIR'].presence || '/data/asap2/fus'
    dir = File.join(shared_root, 'isolated_compliance_uploads')
    FileUtils.mkdir_p(dir)
    dir
  end

  def unsupported_format_error_json(message)
    {
      error: message,
      error_code: ComplianceFileCheckQueueService::UNSUPPORTED_FORMAT_ERROR_CODE
    }
  end

  def download_remote_file!(task_id)
    url = params[:data_url].to_s.strip
    raise ArgumentError, 'No URL provided' if url.blank?

    uri = URI.parse(url)
    raise ArgumentError, 'Only HTTP/HTTPS URLs are supported' unless uri.is_a?(URI::HTTP)

    path = File.join(temp_dir, "#{task_id}.download")
    total = 0
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      http.request(request) do |response|
        raise ArgumentError, "Download failed (HTTP #{response.code})" unless response.code.to_i.between?(200, 299)

        File.open(path, 'wb') do |f|
          response.read_body do |chunk|
            total += chunk.bytesize
            max_size = ComplianceFileCheckQueueService::MAX_UPLOAD_SIZE
            raise ArgumentError, 'Remote file is too large' if total > max_size
            f.write(chunk)
          end
        end
      end
    end
    path
  rescue URI::InvalidURIError
    raise ArgumentError, 'Invalid URL'
  end

  def rename_downloaded_file!(path, task_id, detected_format)
    extension = detected_format == 'loom' ? '.loom' : '.h5ad'
    final_path = File.join(temp_dir, "#{task_id}#{extension}")
    FileUtils.mv(path, final_path)
    final_path
  end
end
