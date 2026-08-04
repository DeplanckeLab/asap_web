# frozen_string_literal: true

require 'open3'
require 'json'

class DockerImage < ApplicationRecord
  has_many :docker_builds, dependent: :restrict_with_exception

  # Resolve the content-addressable image digest (sha256:...) for a local docker image ref.
  # Prefers RepoDigests (registry manifest digest); uses image Id when RepoDigests is empty.
  def self.fetch_digest_from_docker!(image_ref)
    ref = image_ref.to_s.strip
    raise ArgumentError, 'Docker image ref is required' if ref.blank?

    inspect_json = inspect_json!(ref)
    repo_digests = Array(inspect_json['RepoDigests'])
    repo = ref.split('@', 2).first.split(':', 2).first

    matched = repo_digests.find { |d| d.to_s.start_with?("#{repo}@") } || repo_digests.first
    if matched && (m = matched.to_s.match(/@(sha256:[a-f0-9]+)\z/i))
      return m[1].downcase
    end

    image_id = inspect_json['Id'].to_s
    return image_id.downcase if image_id.match?(/\Asha256:[a-f0-9]+\z/i)

    raise "No sha256 digest found for docker image #{ref.inspect} (RepoDigests=#{repo_digests.inspect}, Id=#{image_id.inspect})"
  end

  def self.inspect_json!(image_ref)
    cmd = [
      'docker', 'image', 'inspect',
      '--format', '{{json .}}',
      image_ref.to_s
    ]
    stdout, stderr, status = Open3.capture3(*cmd)
    unless status.success?
      raise "docker image inspect failed for #{image_ref}: #{stderr.presence || stdout}"
    end

    JSON.parse(stdout)
  rescue JSON::ParserError => e
    raise "docker image inspect returned invalid JSON for #{image_ref}: #{e.message}"
  end
end
