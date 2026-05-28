class ComplianceFileChecksController < ApplicationController
  skip_before_action :authenticate_user!, raise: false
  MAX_UPLOAD_SIZE = 50.gigabytes
  ALLOWED_EXTENSIONS = %w[.loom .h5ad].freeze

  def index
    @available_schemas = [{ id: 'scfair_7_1_0', label: 'scFAIR 7.1.0' }]
    @default_schema_id = 'scfair_7_1_0'
  end

  def create
    schema_id = params[:schema_id].presence || 'scfair_7_1_0'
    source = params[:source].to_s
    source = 'upload' if source.blank?

    task_id = SecureRandom.uuid
    tmp_path = if source == 'url'
                 download_remote_file!(task_id)
               else
                 store_uploaded_file!(task_id)
               end

    initial = {
      status: 'queued',
      task_id: task_id,
      progress: 45,
      message: 'Validation queued'
    }
    IsolatedComplianceStatusStore.write(task_id, initial)
    IsolatedComplianceValidationJob.perform_later(task_id, tmp_path, schema_id, File.basename(tmp_path))

    render json: {
      task_id: task_id,
      status: 'queued',
      filename: File.basename(tmp_path),
      schema_id: schema_id
    }
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

  def store_uploaded_file!(task_id)
    uploaded = params[:data_file]
    raise ArgumentError, 'No file provided' unless uploaded.respond_to?(:original_filename)

    ext = File.extname(uploaded.original_filename.to_s).downcase
    raise ArgumentError, 'File must be .loom or .h5ad' unless ALLOWED_EXTENSIONS.include?(ext)

    size = uploaded.size.to_i
    raise ArgumentError, "Invalid file size (max #{MAX_UPLOAD_SIZE / 1.gigabyte}GB)" if size <= 0 || size > MAX_UPLOAD_SIZE

    path = File.join(temp_dir, "#{task_id}#{ext}")
    File.open(path, 'wb') { |f| f.write(uploaded.read) }
    path
  end

  def download_remote_file!(task_id)
    url = params[:data_url].to_s.strip
    raise ArgumentError, 'No URL provided' if url.blank?

    uri = URI.parse(url)
    raise ArgumentError, 'Only HTTP/HTTPS URLs are supported' unless uri.is_a?(URI::HTTP)

    ext = File.extname(uri.path.to_s).downcase
    raise ArgumentError, 'URL must end with .loom or .h5ad' unless ALLOWED_EXTENSIONS.include?(ext)

    path = File.join(temp_dir, "#{task_id}#{ext}")
    total = 0
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      http.request(request) do |response|
        raise ArgumentError, "Download failed (HTTP #{response.code})" unless response.code.to_i.between?(200, 299)

        File.open(path, 'wb') do |f|
          response.read_body do |chunk|
            total += chunk.bytesize
            raise ArgumentError, 'Remote file is too large' if total > MAX_UPLOAD_SIZE
            f.write(chunk)
          end
        end
      end
    end
    path
  rescue URI::InvalidURIError
    raise ArgumentError, 'Invalid URL'
  end
end

