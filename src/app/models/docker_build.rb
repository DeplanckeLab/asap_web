# frozen_string_literal: true

# One immutable image build (RepoDigest), usually a patch tag like v8.1 under a major
# docker_images row (v8). Runs reference this for exact provenance.
class DockerBuild < ApplicationRecord
  belongs_to :docker_image
  has_many :runs, dependent: :nullify

  validates :tag, presence: true
  validates :digest, presence: true, uniqueness: true
  validates :digest, format: { with: /\Asha256:[a-f0-9]{64}\z/i }

  # Resolve/create the build for the image ref that will actually run (e.g. fabdavid/asap_run:v8).
  # Digest is the live RepoDigest; tag prefers a local vX.Y patch tag when present.
  def self.find_or_create_for_image_ref!(image_ref)
    ref = image_ref.to_s.strip
    raise ArgumentError, 'Docker image ref is required' if ref.blank?

    digest = DockerImage.fetch_digest_from_docker!(ref)
    existing = find_by(digest: digest)
    return existing if existing

    name, major_tag = ref.split(':', 2)
    raise ArgumentError, "Docker image ref must be name:tag (got #{ref.inspect})" if name.blank? || major_tag.blank?

    docker_image = DockerImage.find_by(name: name, tag: major_tag)
    raise "DockerImage not found for #{ref.inspect}" unless docker_image

    patch_tag = patch_tag_from_local_image!(ref) || major_tag
    create!(docker_image: docker_image, tag: patch_tag, digest: digest)
  rescue ActiveRecord::RecordNotUnique
    find_by!(digest: digest)
  end

  def full_name
    "#{docker_image.name}:#{tag}"
  end

  # Hub URL uses the major catalog tag (v8), not the patch tag (v8.1).
  def dockerhub_layers_url
    major_ref = "#{docker_image.name}:#{docker_image.tag}"
    Basic.dockerhub_layers_url(major_ref, digest: digest)
  end

  # Prefer the highest local vX.Y tag on this image; else a plain vX; else nil.
  def self.patch_tag_from_local_image!(image_ref)
    inspect_json = DockerImage.inspect_json!(image_ref)
    tags = Array(inspect_json['RepoTags']).filter_map do |full|
      full.to_s.split(':', 2).last.presence
    end.uniq

    patch_tags = tags.select { |t| t.match?(/\Av\d+\.\d+\z/) }
    if patch_tags.any?
      return patch_tags.max_by { |t| Gem::Version.new(t.delete_prefix('v')) }
    end

    tags.find { |t| t.match?(/\Av\d+\z/) }
  end
  private_class_method :patch_tag_from_local_image!
end
