require 'open-uri'
require 'uri'

class FuDownloadFromUrlJob < ApplicationJob
  queue_as :default

  # import_progress_candidate_id: optional ExternalCatalogCandidate id for catalog-import overlay.
  def perform(fu_id, url, organism_id: nil, version_id: nil, import_progress_candidate_id: nil)
    @import_progress_candidate_id = import_progress_candidate_id
    fu = Fu.find_by(id: fu_id)
    return unless fu

    upload_dir = fu.upload_dir
    FileUtils.mkdir_p(upload_dir)
    upload_file_path = upload_dir.join(fu.upload_file_name)

    report_import_progress!(step: 'downloading')

    copied_internally = false
    begin
      result = LocalAsapGetFileCopyService.copy_if_get_file_url!(
        fu: fu,
        url: url,
        dest_path: upload_file_path
      )
      copied_internally = (result == :copied)
    rescue StandardError => e
      if self.class.local_get_file_url?(url)
        Rails.logger.error("[FuDownloadFromUrlJob] Local get_file copy failed for Fu##{fu_id}: #{e.class} - #{e.message}")
        fu&.update(status: 'download_failed')
        broadcast(fu.id, status: 'failed', error: e.message) if fu
        return
      end
      raise e
    end

    unless copied_internally
      UrlDownloadService.new(
        fu: fu,
        url: url,
        dest_path: upload_file_path,
        progress_callback: import_download_progress_callback
      ).call
    end

    downloaded_size = File.size(upload_file_path)
    raise "Downloaded file is missing or empty" unless File.exist?(upload_file_path) && downloaded_size > 0

    content_sha256 = InputFileSha256.hexdigest_file(upload_file_path)

    if dna_accessibility_upload?(fu)
      finalize_dna_accessibility!(fu, content_sha256: content_sha256, downloaded_size: downloaded_size)
      return
    end

    if version_id.blank?
      raise ArgumentError,
            'version_id is required for URL download preparsing (select a release on the upload form)'
    end

    options = {}
    options[:organism_id] = organism_id if organism_id.present?
    options[:version_id] = version_id

    fu.update!(
      upload_file_size: downloaded_size,
      content_sha256: content_sha256,
      status: 'preparsing',
      preparsing_version_id: version_id
    )
    InputFileSha256.clear_state!(fu.id)
    report_import_progress!(step: 'preparsing')
    broadcast(fu.id, status: 'started')

    result = FuPreparsingService.new(fu, options).call
    fu.update!(status: 'preparsed')

    broadcast(
      fu.id,
      status: 'completed',
      summary: result[:summary],
      warnings: result[:warnings],
      raw_output: result[:raw_output],
      prediction_debug: result[:summary][:prediction_debug]
    )
  rescue URI::InvalidURIError, OpenURI::HTTPError, UrlDownloadService::Error => e
    Rails.logger.error("[FuDownloadFromUrlJob] Download failed for Fu##{fu_id}: #{e.class} - #{e.message}")
    fu&.update(status: 'download_failed')
    broadcast(fu.id, status: 'failed', error: e.message) if fu
  rescue StandardError => e
    Rails.logger.error("[FuDownloadFromUrlJob] Job failed for Fu##{fu_id}: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
    if fu && dna_accessibility_upload?(fu)
      fu.update(status: 'download_failed')
    else
      fu&.update(status: 'preparsing_failed')
    end
    broadcast(fu.id, status: 'failed', error: e.message) if fu
  end

  def self.local_get_file_url?(url)
    u = URI.parse(url.to_s)
    u.path.to_s.match?(LocalAsapGetFileCopyService::GET_FILE_PATH_RE)
  rescue URI::InvalidURIError
    false
  end

  private

  def dna_accessibility_upload?(fu)
    DnaAccessibilityFinalizeService.dna_accessibility_upload_type?(UploadType.name_for(fu.upload_type))
  end

  def finalize_dna_accessibility!(fu, content_sha256:, downloaded_size:)
    project = fu.project
    raise DnaAccessibilityFinalizeService::Error, 'Project is required for DNA accessibility upload' unless project

    source = fu.file_path
    raise DnaAccessibilityFinalizeService::Error, 'Downloaded file not found' unless source && File.exist?(source)

    upload_type_name = UploadType.name_for(fu.upload_type)
    name = fu.name.to_s
    ext = DnaAccessibilityFinalizeService.extension_for(name)
    config = DnaAccessibilityFinalizeService.asset_config_for(upload_type_name)
    unless config && config[:allowed_extensions].include?(ext)
      name = DnaAccessibilityFinalizeService.default_filename_for(upload_type_name)
      raise DnaAccessibilityFinalizeService::Error, 'Unknown DNA accessibility upload type' if name.blank?
    end

    fu.update!(
      name: name,
      upload_file_size: downloaded_size,
      content_sha256: content_sha256,
      status: 'uploaded'
    )
    InputFileSha256.clear_state!(fu.id)

    result = DnaAccessibilityFinalizeService.new(
      fu: fu,
      project: project,
      upload_type_name: upload_type_name
    ).call
    broadcast(
      fu.id,
      status: 'completed',
      stage: 'dna_accessibility',
      saved_path: result[:path],
      saved_filename: result[:filename],
      saved_size: result[:size]
    )
  end

  def broadcast(fu_id, payload)
    ActionCable.server.broadcast("fu_#{fu_id}", { stage: 'preparsing', fu_id: fu_id }.merge(payload))
  end

  def import_download_progress_callback
    candidate_id = @import_progress_candidate_id
    return nil if candidate_id.blank?

    lambda do |downloaded, total|
      ExternalCatalog::ImportProgress.report_download(
        candidate_id,
        downloaded: downloaded,
        total: total
      )
    end
  end

  def report_import_progress!(step:)
    return if @import_progress_candidate_id.blank?

    ExternalCatalog::ImportProgress.report(@import_progress_candidate_id, step: step)
  end
end
