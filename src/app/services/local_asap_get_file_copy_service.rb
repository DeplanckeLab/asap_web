# frozen_string_literal: true

require 'env_helpers'
require 'uri'

# When users paste an ASAP "get_file" link into "download from URL", the async job uses curl
# without session cookies, so HTTP would return HTML (login / unauthorized). This service
# detects those URLs and copies from USER_DATA_DIR after applying the same access rules as
# ProjectsController#get_file, using the Fu owner (and optional sandbox key on the Fu).
class LocalAsapGetFileCopyService
  GET_FILE_PATH_RE = %r{/projects/([^/]+)/get_file\z}i

  IMAGE_EXT = %w[png pdf jpeg jpg].freeze

  class << self
    # @return :copied file written to dest_path
    # @return :not_our_url use HTTP download instead
    # @raise on policy denial, missing file, or path escape
    def copy_if_get_file_url!(fu:, url:, dest_path:)
      uri = URI.parse(url.to_s)
      return :not_our_url unless %w[http https].include?(uri.scheme&.downcase)

      m = uri.path.to_s.match(GET_FILE_PATH_RE)
      return :not_our_url unless m

      return :not_our_url unless host_allowed?(uri.host)

      project = resolve_project(m[1])
      return :not_our_url unless project
      return :not_our_url unless project.user_id.present?

      unless ENV['USER_DATA_DIR'].present?
        raise 'Server configuration error: USER_DATA_DIR is not set'
      end

      q = Rack::Utils.parse_query(uri.query.to_s)
      run_id = q['run_id'].presence
      step_param = q['step'].presence
      filename_param = q['filename'].presence
      onum_param = q['onum'].presence

      project_dir = build_project_dir(project)
      resolved = resolve_filepath(
        project: project,
        project_dir: project_dir,
        run_id: run_id,
        step_name: step_param,
        filename: filename_param,
        onum: onum_param
      )

      unless resolved
        raise 'Invalid get_file URL: need filename or onum'
      end

      filepath = resolved[:filepath]
      filename = resolved[:filename]
      step_name = resolved[:step_name]
      run = resolved[:run]

      raise 'Resolved path is empty' if filepath.to_s.empty?

      ensure_path_inside_project!(filepath:, project_dir:)

      ext = filename.to_s.split('.').last
      json_allowed = (ext == 'json' && %w[parsing cell_filtering].include?(step_name))

      ctx = AccessContext.new(user: fu.user, sandbox_key: fu.project_key)
      unless ctx.get_file_authorized?(
        project: project,
        filename: filename,
        step_name: step_name,
        run: run,
        ext: ext,
        json_allowed: json_allowed
      )
        raise 'Not authorized to download this file'
      end

      unless File.exist?(filepath)
        if project.archived_on_s3? && filepath.to_s.match?(/\.(loom|h5ad)\z/i)
          rel = Pathname.new(filepath.to_s).expand_path.relative_path_from(
            Pathname.new(project_dir.to_s).expand_path
          ).to_s
          FileUtils.mkdir_p(File.dirname(dest_path))
          ProjectS3Archive.extract_member_to!(
            project,
            member_rel: rel,
            dest_path: dest_path
          )
          copied = File.size(dest_path)
          raise 'Extracted archive member is empty' unless copied.positive?

          return :copied
        end

        raise 'Source file does not exist'
      end

      if filepath.to_s.match?(/\.(loom|h5ad)\z/i)
        ensure_analysis_json!(project: project, project_dir: project_dir, filepath: filepath)
      end

      FileUtils.mkdir_p(File.dirname(dest_path))
      IO.copy_stream(filepath.to_s, dest_path.to_s)
      copied = File.size(dest_path)
      raise 'Copied file is empty' unless copied.positive?

      :copied
    end

    private

    def ensure_analysis_json!(project:, project_dir:, filepath:)
      abs = Pathname.new(filepath.to_s).expand_path
      root = Pathname.new(project_dir.to_s).expand_path
      rel = abs.relative_path_from(root).to_s
      loom_rel = rel.sub(/\.h5ad\z/i, '.loom')
      return unless loom_rel.end_with?('.loom')

      loom_abs = root + loom_rel
      return unless File.exist?(loom_abs)

      AnalysisJsonPersistService.call(project: project, loom_filepath: loom_rel)
      Basic.refresh_anndata_mapping_for_loom(Rails.logger, project, loom_rel)
    end

    def host_allowed?(host)
      return false if host.blank?

      raw = ENV.fetch('ASAP_INTERNAL_GET_FILE_HOSTS', '').to_s
      allowed = raw.split(',').map(&:strip).reject(&:empty?)
      return true if allowed.empty?

      allowed.any? { |h| h.casecmp?(host) }
    end

    def resolve_project(identifier)
      s = identifier.to_s
      project = nil
      if s.match?(/^\d+$/)
        project = Project.find_by(id: s.to_i)
      end
      project ||= Project.find_by(key: s)
      if project.nil?
        if s.match?(/^ASAP\d+$/i)
          numeric_part = s.match(/\d+$/).to_s.to_i
          project = Project.find_by(public_id: numeric_part)
        elsif s.match?(/^\d+$/)
          project = Project.find_by(public_id: s.to_i)
        end
      end
      project
    end

    def build_project_dir(project)
      user_data_dir = ENV['USER_DATA_DIR'].to_s.chomp('/')
      base_dir = if user_data_dir.end_with?('/users') || user_data_dir.end_with?('users')
                   Pathname.new(user_data_dir)
                 else
                   Pathname.new(user_data_dir) + 'users'
                 end
      base_dir + project.user_id.to_s + project.key
    end

    # Mirrors ProjectsController#get_file path construction.
    def resolve_filepath(project:, project_dir:, run_id:, step_name:, filename:, onum:)
      run = nil
      h_file_by_id = {}
      if run_id.present?
        run = Run.find_by(id: run_id)
        if run
          h_outputs = Basic.safe_parse_json(run.output_json, {})
          h_outputs.each_key do |k|
            h_outputs[k].each_key do |k2|
              t = k2.split(':')
              relative_path = t[0]
              full_path = project_dir + relative_path
              meta = h_outputs[k][k2]
              next unless meta.is_a?(Hash) && meta['onum']

              h_file_by_id[meta['onum'].to_i] = { filename: meta['filename'], filepath: full_path }
            end
          end
          step_name = run.step&.name
        end
      end

      if onum.present?
        entry = h_file_by_id[onum.to_i]
        return nil unless entry

        { filepath: entry[:filepath], filename: entry[:filename], step_name: step_name, run: run }
      elsif filename.present?
        user_data_dir = ENV['USER_DATA_DIR'].to_s.chomp('/')
        base_dir = if user_data_dir.end_with?('/users') || user_data_dir.end_with?('users')
                     Pathname.new(user_data_dir)
                   else
                     Pathname.new(user_data_dir) + 'users'
                   end
        tmp_dir = base_dir + project.user_id.to_s + project.key
        tmp_dir += step_name if step_name.present?
        tmp_dir += run_id.to_s if run_id.present? && run&.step&.multiple_runs
        fp = tmp_dir + filename
        { filepath: fp, filename: filename, step_name: step_name, run: run }
      end
    end

    def ensure_path_inside_project!(filepath:, project_dir:)
      src = Pathname.new(filepath.to_s).expand_path
      base = Pathname.new(project_dir.to_s).expand_path
      return if src.to_s.start_with?(base.to_s + File::SEPARATOR) || src == base

      raise 'Path escapes project directory'
    end
  end

  # Request-less stand-in for ProjectAuthorization checks used by get_file (no IP bypass).
  class AccessContext
    def initialize(user:, sandbox_key:)
      @user = user
      @sandbox_key = sandbox_key.to_s.presence
    end

    def get_file_authorized?(project:, filename:, step_name:, run:, ext:, json_allowed:)
      part1 = readable?(project) && (exportable?(project) || IMAGE_EXT.include?(ext))
      part2 = (step_name == 'visualization' && filename.to_s.match?(/trajectory/) && ext == 'json')
      part3 = (step_name.present? && run && exportable_item?(project, run))
      part4 = json_allowed
      part1 || part2 || part3 || part4
    end

    private

    def admin_user?
      return false unless @user.respond_to?(:email)

      email = @user.email.to_s.strip.downcase
      return false if email.empty?

      EnvHelpers.email_list('ADMIN_EMAILS')
        .map { |value| value.to_s.strip.downcase }
        .include?(email)
    end

    def readable?(project)
      return false unless project

      return true if admin_user?
      return true if project.sandbox? && @sandbox_key.present? && @sandbox_key == project.key
      return true if project.public?

      return true if @user && project.user_id == @user.id

      if @user
        share = project.shares.find_by(user_id: @user.id)
        return true if share&.view_perm?
      end

      false
    end

    def exportable?(project)
      return false unless project

      return true if admin_user?
      return true if project.sandbox? && @sandbox_key.present? && @sandbox_key == project.key
      return true if project.public?
      return true if @user && project.user_id == @user.id

      if @user
        share = project.shares.find_by(user_id: @user.id)
        return true if share&.export_perm?
      end

      false
    end

    def editable?(project)
      return false unless project

      return true if admin_user?
      return true if project.sandbox? && @sandbox_key.present? && @sandbox_key == project.key
      return true if @user && project.user_id == @user.id

      false
    end

    def exportable_item?(project, item)
      return false unless project && item

      return true if editable?(project) || exportable?(project)
      return true if @user && item.respond_to?(:user_id) && item.user_id == @user.id

      false
    end
  end
end
