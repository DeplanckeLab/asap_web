# frozen_string_literal: true

namespace :docker_builds do
  desc "Ensure DockerImage exists, refresh its digest from the local docker image, " \
       "and register a DockerBuild row. " \
       "IMAGE_REF=fabdavid/asap_run:v8 (major catalog tag). " \
       "Optional PATCH_TAG=v8.3 forces the DockerBuild.tag when set."
  task register: :environment do
    image_ref = ENV["IMAGE_REF"].to_s.strip
    if image_ref.empty?
      name = ENV["IMAGE_NAME"].presence || ENV["NAME"].presence || "fabdavid/asap_run"
      tag = ENV["TAG"].to_s.strip
      if tag.empty?
        puts "Usage:"
        puts "  bin/rake docker_builds:register IMAGE_REF=fabdavid/asap_run:v8"
        puts "  bin/rake docker_builds:register IMAGE_REF=fabdavid/asap_run:v8 PATCH_TAG=v8.3"
        puts "  bin/rake docker_builds:register IMAGE_NAME=fabdavid/asap_run TAG=v8"
        exit 1
      end
      image_ref = "#{name}:#{tag}"
    end

    name, tag = image_ref.split(":", 2)
    if name.blank? || tag.blank?
      raise ArgumentError, "IMAGE_REF must be name:tag (got #{image_ref.inspect})"
    end

    patch_tag = ENV["PATCH_TAG"].to_s.strip.presence

    docker_image = DockerImage.find_or_initialize_by(name: name, tag: tag)
    if docker_image.new_record?
      docker_image.full_name = image_ref
      if tag.match?(/\Av\d+\z/)
        docker_image.version = tag.delete_prefix("v").to_i
      end
      docker_image.save!
      puts "Created DockerImage id=#{docker_image.id} #{image_ref}"
    end

    digest = DockerImage.fetch_digest_from_docker!(image_ref)
    attrs = {}
    attrs[:digest] = digest if docker_image.digest != digest
    attrs[:full_name] = image_ref if docker_image.full_name != image_ref
    if attrs.any?
      docker_image.update!(attrs)
      puts "Updated DockerImage id=#{docker_image.id} #{attrs.keys.join(', ')}"
    else
      puts "DockerImage id=#{docker_image.id} already up to date (digest=#{digest})"
    end

    build =
      if patch_tag
        existing = DockerBuild.find_by(digest: digest)
        if existing
          if existing.tag != patch_tag || existing.docker_image_id != docker_image.id
            existing.update!(tag: patch_tag, docker_image: docker_image)
            puts "Updated DockerBuild id=#{existing.id} tag=#{patch_tag}"
          end
          existing
        else
          DockerBuild.create!(docker_image: docker_image, tag: patch_tag, digest: digest)
        end
      else
        DockerBuild.find_or_create_for_image_ref!(image_ref)
      end

    puts "DockerBuild id=#{build.id} tag=#{build.tag} digest=#{build.digest} full_name=#{build.full_name}"
  end
end
