# frozen_string_literal: true

require 'open3'
require 'json'
require 'securerandom'
require 'shellwords'
require 'fileutils'

# Extracts minimal metadata JSON from H5AD or Loom files using the Python parser.
# Extraction only — no compliance checks (see src/config/scfair/minimal_extract_spec.json).
class ScfairMinimalExtractService
  class ExtractionError < StandardError; end

  ASAP_RUN_CONTAINER = ENV.fetch('ASAP_RUN_CONTAINER').freeze
  # Canonical parser lives in the Rails app; synced into repo_root so asap_run can read it.
  APP_PARSER_SCRIPT = Rails.root.join('lib/scfair/scfair_loom_h5ad_extract_parser.py').freeze

  def initialize(file_path:, logger: Rails.logger)
    @file_path = file_path
    @logger = logger
  end

  def extract
    container_path = resolve_container_path(@file_path)
    raise ExtractionError, "File not found: #{@file_path}" unless File.exist?(container_path)

    sync_parser_script!
    output_path = File.join(repo_root, 'tmp', "extract_#{SecureRandom.hex(8)}.json")
    ensure_output_dir!(output_path)

    cmd = [
      'docker', 'exec', '-i', ASAP_RUN_CONTAINER,
      'python3', parser_script, container_path, '--output', output_path
    ]

    stdout, stderr, status = Open3.capture3(*cmd)
    unless status.success?
      raise ExtractionError, stderr.presence || stdout.presence || 'Python extract parser failed'
    end

    unless File.exist?(output_path)
      raise ExtractionError, 'Extract parser did not produce output JSON'
    end

    JSON.parse(File.read(output_path))
  rescue JSON::ParserError => e
    raise ExtractionError, "Invalid extract JSON: #{e.message}"
  ensure
    FileUtils.rm_f(output_path) if defined?(output_path) && output_path.present?
  end

  private

  # Shared host path visible to both the website container and asap_run.
  # Prefer SCFAIR_EXTRACT_REPO_ROOT; otherwise DATA_DIR (prod: /data/asap, test: /data/asap2_test).
  def repo_root
    root = ENV['SCFAIR_EXTRACT_REPO_ROOT'].presence ||
           ENV['DATA_DIR'].to_s.chomp('/').presence ||
           ENV['USER_DATA_DIR'].to_s.sub(%r{/users/?\z}, '').presence
    raise ExtractionError, 'Set SCFAIR_EXTRACT_REPO_ROOT or DATA_DIR for extract output' if root.blank?

    root
  end

  def parser_script
    File.join(repo_root, 'scripts/scfair_loom_h5ad_extract_parser.py')
  end

  def sync_parser_script!
    raise ExtractionError, "Extract parser missing: #{APP_PARSER_SCRIPT}" unless File.exist?(APP_PARSER_SCRIPT)

    dest_dir = File.dirname(parser_script)
    FileUtils.mkdir_p(dest_dir) unless File.directory?(dest_dir)
    FileUtils.cp(APP_PARSER_SCRIPT, parser_script)
  end

  def resolve_container_path(path)
    abs = File.expand_path(path)
    return abs if abs.start_with?(repo_root)

    workspace = ENV['WORKSPACE_ROOT'].to_s.chomp('/')
    if workspace.present? && abs.start_with?("#{workspace}/")
      return abs.sub(workspace, repo_root)
    end

    # Legacy remaps for instances that still pass /srv/... paths into extract.
    {
      '/srv/asap2_test' => '/data/asap2_test',
      '/srv/asap' => '/data/asap'
    }.each do |from, to|
      return abs.sub(from, to) if abs.start_with?("#{from}/")
    end

    abs
  end

  def ensure_output_dir!(output_path)
    dir = File.dirname(output_path)
    FileUtils.mkdir_p(dir) unless File.directory?(dir)
  end
end
