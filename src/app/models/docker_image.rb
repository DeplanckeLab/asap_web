# frozen_string_literal: true

require 'open3'
require 'json'

class DockerImage < ApplicationRecord
  has_many :docker_builds, dependent: :restrict_with_exception

  MAJOR_TAG_RE = /\Av\d+\z/
  PATCH_TAG_RE = /\Av\d+\.\d+\z/

  # Dev and prod share one docker daemon and one Docker Hub repo, so a moving major tag
  # (fabdavid/asap_run:v8) cannot mean different builds per instance. Each database pins
  # the patch build its instance runs in docker_images.runtime_tag (e.g. v8.7 on the v8
  # row). build_asap_run.sh sets it on dev; reference_data:steps_std_methods:sync_from_dev
  # copies the DockerImage row to prod, which is the promotion. The catalog keeps the
  # major tag (tag = v8); only the ref handed to `docker run` / `docker pull` becomes vX.Y.
  validates :runtime_tag, format: { with: PATCH_TAG_RE, message: 'must look like v8.7' }, allow_blank: true
  validate :runtime_tag_matches_major

  # v8.7 -> v8, v8 -> v8, anything else -> unchanged.
  def self.major_tag_of(tag)
    t = tag.to_s
    t.match?(PATCH_TAG_RE) ? t.split('.', 2).first : t
  end

  # Image ref to actually run for a catalog name:tag. Major tags with a runtime_tag pin
  # resolve to name:vX.Y; unpinned majors, explicit patch tags and unknown images pass through.
  def self.runtime_ref(name, tag)
    return "#{name}:#{tag}" unless tag.to_s.match?(MAJOR_TAG_RE)

    image = find_by(name: name.to_s, tag: tag.to_s)
    image ? image.runtime_ref : "#{name}:#{tag}"
  end

  # Same, for an env_json docker_images entry ({"name" => ..., "tag" => ...}).
  def self.runtime_ref_for(cfg)
    runtime_ref(cfg['name'] || cfg[:name], cfg['tag'] || cfg[:tag])
  end

  def runtime_ref
    "#{name}:#{runtime_tag.presence || tag}"
  end

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

  private

  def runtime_tag_matches_major
    return if runtime_tag.blank? || !runtime_tag.match?(PATCH_TAG_RE)
    return if self.class.major_tag_of(runtime_tag) == tag

    errors.add(:runtime_tag, "#{runtime_tag} does not belong to major tag #{tag}")
  end
end
