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
  REPO_ROOT = ENV.fetch('SCFAIR_EXTRACT_REPO_ROOT', '/data/asap2_test').freeze
  PARSER_SCRIPT = File.join(REPO_ROOT, 'scripts/scfair_loom_h5ad_extract_parser.py').freeze

  def initialize(file_path:, logger: Rails.logger)
    @file_path = file_path
    @logger = logger
  end

  def extract
    container_path = resolve_container_path(@file_path)
    raise ExtractionError, "File not found: #{@file_path}" unless File.exist?(container_path)

    output_path = File.join(REPO_ROOT, 'tmp', "extract_#{SecureRandom.hex(8)}.json")
    ensure_output_dir!(output_path)

    cmd = [
      'docker', 'exec', '-i', ASAP_RUN_CONTAINER,
      'python3', PARSER_SCRIPT, container_path, '--output', output_path
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

  def resolve_container_path(path)
    abs = File.expand_path(path)
    return abs if abs.start_with?(REPO_ROOT)

    if abs.start_with?('/srv/asap2_test/')
      return abs.sub('/srv/asap2_test', REPO_ROOT)
    end

    abs
  end

  def ensure_output_dir!(output_path)
    dir = File.dirname(output_path)
    FileUtils.mkdir_p(dir) unless File.directory?(dir)
  end
end
