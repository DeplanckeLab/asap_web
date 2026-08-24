# frozen_string_literal: true

require 'env_helpers'

# One immutable image build (RepoDigest), usually a patch tag like v8.1 under a major
# docker_images row (v8). Runs reference this for exact provenance.
# Replacing a patch tag overwrites that row's digest (fingerprint) in place; the row is
# not deleted. That requires ALLOW_REPLACE=1 after the build script reports per-user usage
# (guest counted as a user) and the operator confirms.
class DockerBuild < ApplicationRecord
  belongs_to :docker_image
  has_many :runs, dependent: :nullify

  validates :tag, presence: true
  validates :digest, presence: true, uniqueness: true
  validates :digest, format: { with: /\Asha256:[a-f0-9]{64}\z/i }

  GUEST_USAGE_LABEL = 'guest'

  # Operators who may consciously overwrite a patch-tag fingerprint.
  # Admin emails also come from ADMIN_EMAILS.
  OPERATOR_EMAILS = %w[
    vincent.gardeux@epfl.ch
    fabrice.david@epfl.ch
  ].freeze

  def self.operator_emails
    (OPERATOR_EMAILS + EnvHelpers.email_list('ADMIN_EMAILS'))
      .map { |email| email.to_s.strip.downcase }
      .reject(&:empty?)
      .uniq
  end

  # runs / del_runs / active_runs may point at this build for provenance.
  def reference_count
    runs.count +
      DelRun.where(docker_build_id: id).count +
      ActiveRun.where(docker_build_id: id).count
  end

  # Provenance row counts keyed by user email, with sandbox / anonymous as GUEST_USAGE_LABEL.
  def usage_by_user
    counts = Hash.new(0)
    each_provenance_row do |_kind, row|
      counts[usage_label_for(row)] += 1
    end
    counts
  end

  # Reasons this build has non-operator usage (guest or other users).
  # Empty => only unused or operator/admin usage. Replace still needs confirmation;
  # non-empty can be bypassed after the build script reports usage and ALLOW_REPLACE=1.
  def replace_blockers
    blockers = []
    each_provenance_row do |kind, row|
      project = Project.find_by(id: row.project_id)
      if project&.sandbox?
        blockers << "guest sandbox project_id=#{project.id} (#{kind} id=#{row.try(:id) || row.run_id})"
        next
      end

      if row.user_id.nil?
        blockers << "guest (no user) on #{kind} id=#{row.try(:id) || row.run_id}"
        next
      end

      email = User.find_by(id: row.user_id)&.email.to_s.strip.downcase
      next if self.class.operator_emails.include?(email)

      label = email.presence || "user_id=#{row.user_id}"
      blockers << "#{label} on #{kind} id=#{row.try(:id) || row.run_id}"
    end
    blockers.uniq
  end

  def replaceable?
    replace_blockers.empty?
  end

  # Remove a surplus same-tag row (duplicate), clearing provenance FKs first.
  def destroy_duplicate!
    Run.where(docker_build_id: id).update_all(docker_build_id: nil)
    DelRun.where(docker_build_id: id).update_all(docker_build_id: nil)
    ActiveRun.where(docker_build_id: id).update_all(docker_build_id: nil)
    destroy!
  end

  # Register a patch-tagged build (vX.Y).
  # If the tag already exists, overwrite that row's digest in place (row kept) when
  # ALLOW_REPLACE=1. Without it, guest / other-user usage raises; with it, bypass is allowed.
  def self.register_for_patch_tag!(docker_image:, patch_tag:, digest:, allow_replace: false)
    allow_replace = allow_replace || ENV['ALLOW_REPLACE'].to_s == '1'
    existing_by_digest = find_by(digest: digest)
    same_tag = where(tag: patch_tag).order(:id).to_a

    if existing_by_digest && same_tag.size == 1 && same_tag.first.id == existing_by_digest.id
      if existing_by_digest.docker_image_id != docker_image.id
        existing_by_digest.update!(docker_image: docker_image)
        puts "Updated DockerBuild id=#{existing_by_digest.id} docker_image"
      end
      return existing_by_digest
    end

    if same_tag.empty?
      if existing_by_digest
        existing_by_digest.update!(tag: patch_tag, docker_image: docker_image)
        puts "Updated DockerBuild id=#{existing_by_digest.id} tag=#{patch_tag}"
        return existing_by_digest
      end

      build = create!(docker_image: docker_image, tag: patch_tag, digest: digest)
      puts "Created DockerBuild id=#{build.id} tag=#{patch_tag}"
      return build
    end

    unless allow_replace
      ensure_replaceable!(same_tag, patch_tag)
      ids = same_tag.map(&:id).join(',')
      raise "Cannot replace DockerBuild tag=#{patch_tag} (ids=#{ids}): confirmation required. " \
            "Re-run via build_asap_run.sh and accept the replace prompt, or set ALLOW_REPLACE=1."
    end

    # Keep the oldest row (stable id); overwrite its fingerprint. Drop duplicate same-tag rows.
    keeper = same_tag.first
    extras = same_tag[1..]

    if existing_by_digest && existing_by_digest.id != keeper.id
      if extras.any? { |b| b.id == existing_by_digest.id }
        puts "Removing duplicate DockerBuild id=#{existing_by_digest.id} to free digest"
        existing_by_digest.destroy_duplicate!
        extras.reject! { |b| b.id == existing_by_digest.id }
      elsif existing_by_digest.tag == patch_tag
        puts "Removing duplicate DockerBuild id=#{existing_by_digest.id} to free digest"
        existing_by_digest.destroy_duplicate!
      else
        raise "Cannot replace DockerBuild tag=#{patch_tag}: digest #{digest} already belongs to " \
              "DockerBuild id=#{existing_by_digest.id} tag=#{existing_by_digest.tag}"
      end
    end

    extras.each do |build|
      puts "Removing duplicate DockerBuild id=#{build.id} tag=#{build.tag}"
      build.destroy_duplicate!
    end

    old_digest = keeper.digest
    if old_digest != digest || keeper.docker_image_id != docker_image.id
      keeper.update!(digest: digest, docker_image: docker_image)
      puts "Updated DockerBuild id=#{keeper.id} tag=#{patch_tag} fingerprint " \
           "#{old_digest} -> #{digest}"
    end
    keeper
  end

  def self.ensure_replaceable!(builds, patch_tag)
    blocked = builds.reject(&:replaceable?)
    return if blocked.empty?

    details = blocked.map do |b|
      usage = b.usage_by_user.sort_by { |user, _n| user }.map { |user, n| "#{user}=#{n}" }.join(', ')
      "id=#{b.id} usage=[#{usage}] blockers=#{b.replace_blockers.join(', ')}"
    end.join('; ')
    raise "Cannot replace DockerBuild tag=#{patch_tag}: used by guest or non-operator users " \
          "(#{details}). Re-run via build_asap_run.sh, review the per-user run counts, and " \
          "confirm replace (ALLOW_REPLACE=1), or use a new patch version."
  end
  private_class_method :ensure_replaceable!

  def each_provenance_row
    runs.find_each { |row| yield 'run', row }
    DelRun.where(docker_build_id: id).find_each { |row| yield 'del_run', row }
    ActiveRun.where(docker_build_id: id).find_each { |row| yield 'active_run', row }
  end
  private :each_provenance_row

  def usage_label_for(row)
    project = Project.find_by(id: row.project_id)
    return GUEST_USAGE_LABEL if project&.sandbox?
    return GUEST_USAGE_LABEL if row.user_id.nil?

    email = User.find_by(id: row.user_id)&.email.to_s.strip.downcase
    email.presence || GUEST_USAGE_LABEL
  end
  private :usage_label_for

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
