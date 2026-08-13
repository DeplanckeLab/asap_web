# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'concurrent'

# Full-file SHA-256 helpers for uploaded input files.
# Chunked uploads keep a running digest in process memory (Digest objects cannot be
# Marshal'd). If that state is missing (other worker / restart), we rebuild from
# the bytes already on disk.
class InputFileSha256
  DIGESTS = Concurrent::Map.new

  class << self
    def hexdigest_file(path)
      return nil if path.blank?
      pathname = Pathname.new(path.to_s)
      return nil unless pathname.file?

      Digest::SHA256.file(pathname).hexdigest
    end

    def clear_state!(fu_or_upload_dir)
      key = digest_key(fu_or_upload_dir)
      DIGESTS.delete(key) if key
    end

    # After a chunk has been written to +file_path+, update the running digest.
    # Returns the digest object (caller finalizes on last chunk).
    def update_after_chunk!(upload_dir:, chunk_index:, chunk_data:, file_path:, fu_id: nil)
      key = digest_key(fu_id || upload_dir)
      chunk_bytes = chunk_data.is_a?(String) ? chunk_data : chunk_data.to_s
      file_path = Pathname.new(file_path.to_s)

      digest =
        if chunk_index.to_i.zero?
          DIGESTS.delete(key)
          d = Digest::SHA256.new
          d.update(chunk_bytes)
          d
        elsif (existing = DIGESTS[key])
          existing.update(chunk_bytes)
          existing
        else
          # State lost (other worker / process restart): rebuild from disk.
          Digest::SHA256.file(file_path)
        end

      DIGESTS[key] = digest
      digest
    end

    def finalize_for_fu!(fu, digest: nil)
      raise ArgumentError, 'fu is required' unless fu

      sha =
        if digest
          digest.hexdigest
        else
          path = fu.file_path
          hexdigest_file(path)
        end
      return nil if sha.blank?

      fu.update!(content_sha256: sha)
      clear_state!(fu.id)
      sha
    end

    def ensure_for_fu!(fu)
      return fu.content_sha256 if fu&.content_sha256.present?

      finalize_for_fu!(fu)
    end

    def ensure_for_project!(project)
      return project.input_content_sha256 if project.input_content_sha256.present?

      sha = nil
      if project.fu_id.present?
        fu = Fu.find_by(id: project.fu_id)
        sha = ensure_for_fu!(fu) if fu
      end

      if sha.blank?
        path = project_input_path(project)
        sha = hexdigest_file(path)
      end
      return nil if sha.blank?

      project.update_column(:input_content_sha256, sha)
      if project.fu_id.present?
        Fu.where(id: project.fu_id, content_sha256: [nil, '']).update_all(content_sha256: sha)
      end
      sha
    end

    def project_input_path(project)
      return nil unless project

      if project.input_filename.present? && project.data_dir
        candidate = Pathname.new(project.data_dir.to_s).join(project.input_filename.to_s)
        return candidate if candidate.exist?
      end

      fu = Fu.resolve_for_project(project)
      return nil unless fu

      fu.file_path(project: project)
    end

    def matching_public_projects(sha, limit: 20)
      return Project.none if sha.blank?

      Project.where(public: true, being_deleted: false, input_content_sha256: sha)
             .order(:public_id)
             .limit(limit)
    end

    def public_project_warning(sha)
      projects = matching_public_projects(sha).to_a
      return nil if projects.empty?

      labels = projects.map do |project|
        key = project.public_key.presence || "ASAP#{project.public_id}"
        name = project.display_name.to_s.strip
        name.present? ? "#{key} (#{name})" : key
      end
      "This file was already used to create public project(s): #{labels.join(', ')}. " \
        "Creating another project from it is allowed, but cloning an existing public project is faster than re-parsing."
    end

    private

    def digest_key(fu_or_upload_dir)
      case fu_or_upload_dir
      when Integer, String
        "fu:#{fu_or_upload_dir}"
      when Fu
        "fu:#{fu_or_upload_dir.id}"
      else
        "dir:#{fu_or_upload_dir}"
      end
    end
  end
end
