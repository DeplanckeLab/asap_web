# frozen_string_literal: true

namespace :docker_builds do
  desc "Ensure DockerImage exists, refresh its digest from the local docker image, " \
       "and register a DockerBuild row. " \
       "IMAGE_REF=fabdavid/asap_run:v8.3 (patch ref: digest read from it, catalog row is the " \
       "major v8) or IMAGE_REF=fabdavid/asap_run:v8 (major ref). " \
       "Optional PATCH_TAG=v8.3 forces the DockerBuild.tag (defaults to the patch tag of IMAGE_REF). " \
       "A new digest for an existing PATCH_TAG overwrites that row's fingerprint in place " \
       "(row kept) when ALLOW_REPLACE=1. Without ALLOW_REPLACE, guest/other-user usage raises; " \
       "build_asap_run.sh reports per-user run counts (guest included) then can confirm bypass. " \
       "PIN=1 also sets docker_images.runtime_tag to the patch tag, so this instance runs it " \
       "(sync_from_dev later copies the pin to production)."
  task register: :environment do
    image_ref = ENV["IMAGE_REF"].to_s.strip
    if image_ref.empty?
      name = ENV["IMAGE_NAME"].presence || ENV["NAME"].presence || "fabdavid/asap_run"
      tag = ENV["TAG"].to_s.strip
      if tag.empty?
        puts "Usage:"
        puts "  bin/rake docker_builds:register IMAGE_REF=fabdavid/asap_run:v8.3"
        puts "  bin/rake docker_builds:register IMAGE_REF=fabdavid/asap_run:v8.3 PIN=1"
        puts "  bin/rake docker_builds:register IMAGE_REF=fabdavid/asap_run:v8"
        puts "  bin/rake docker_builds:register IMAGE_NAME=fabdavid/asap_run TAG=v8"
        exit 1
      end
      image_ref = "#{name}:#{tag}"
    end

    name, ref_tag = image_ref.split(":", 2)
    if name.blank? || ref_tag.blank?
      raise ArgumentError, "IMAGE_REF must be name:tag (got #{image_ref.inspect})"
    end

    # Catalog row is always the major tag (v8); the digest comes from IMAGE_REF itself.
    tag = DockerImage.major_tag_of(ref_tag)
    catalog_ref = "#{name}:#{tag}"
    patch_tag = ENV["PATCH_TAG"].to_s.strip.presence
    patch_tag ||= ref_tag if ref_tag.match?(DockerImage::PATCH_TAG_RE)

    docker_image = DockerImage.find_or_initialize_by(name: name, tag: tag)
    if docker_image.new_record?
      docker_image.full_name = catalog_ref
      if tag.match?(/\Av\d+\z/)
        docker_image.version = tag.delete_prefix("v").to_i
      end
      docker_image.save!
      puts "Created DockerImage id=#{docker_image.id} #{catalog_ref}"
    end

    digest = DockerImage.fetch_digest_from_docker!(image_ref)
    attrs = {}
    pin = ENV["PIN"].to_s == "1"
    # Catalog digest = what this instance runs: refresh it for a major ref or a pinned patch.
    attrs[:digest] = digest if docker_image.digest != digest && (pin || patch_tag.nil? || ref_tag == tag)
    attrs[:full_name] = catalog_ref if docker_image.full_name != catalog_ref
    if pin
      raise ArgumentError, "PIN=1 needs a patch tag (IMAGE_REF=name:vX.Y or PATCH_TAG=vX.Y)" if patch_tag.blank?

      attrs[:runtime_tag] = patch_tag if docker_image.runtime_tag != patch_tag
    end
    if attrs.any?
      docker_image.update!(attrs)
      puts "Updated DockerImage id=#{docker_image.id} #{attrs.keys.join(', ')}"
    else
      puts "DockerImage id=#{docker_image.id} already up to date (digest=#{digest})"
    end

    build =
      if patch_tag
        DockerBuild.register_for_patch_tag!(
          docker_image: docker_image,
          patch_tag: patch_tag,
          digest: digest,
          allow_replace: ENV['ALLOW_REPLACE'].to_s == '1'
        )
      else
        DockerBuild.find_or_create_for_image_ref!(image_ref)
      end

    puts "DockerBuild id=#{build.id} tag=#{build.tag} digest=#{build.digest} full_name=#{build.full_name}"
    puts "DockerImage #{catalog_ref} runtime_tag=#{docker_image.reload.runtime_tag.inspect} " \
         "(this instance runs #{docker_image.runtime_ref})"
  end
end
