# frozen_string_literal: true

require 'fileutils'

module ExternalCatalog
  # Tracks catalog import pipeline outcomes per ASAP project.
  # Stored as a TSV under DATA_DIR for downstream collection-level publication logic.
  class ImportSuccessRegistry
    PipelineStatus = Struct.new(
      :import_full_success,
      :parsed,
      :scfair_loom_valid,
      :visualization_checkpoint,
      :h5ad_export,
      :scfair_h5ad_valid,
      keyword_init: true
    ) do
      def self.empty
        new(
          import_full_success: false,
          parsed: false,
          scfair_loom_valid: false,
          visualization_checkpoint: false,
          h5ad_export: false,
          scfair_h5ad_valid: false
        )
      end

      def self.from_hash(hash)
        attrs = normalize_hash(hash || {})
        new(
          import_full_success: attrs[:import_full_success] == 1,
          parsed: attrs[:parsed] == 1,
          scfair_loom_valid: attrs[:scfair_loom_valid] == 1,
          visualization_checkpoint: attrs[:visualization_checkpoint] == 1,
          h5ad_export: attrs[:h5ad_export] == 1,
          scfair_h5ad_valid: attrs[:scfair_h5ad_valid] == 1
        )
      end

      def self.normalize_hash(hash)
        src = hash || {}
        normalized = {
          parsed: flag(src[:parsed] || src['parsed']),
          scfair_loom_valid: flag(src[:scfair_loom_valid] || src['scfair_loom_valid']),
          visualization_checkpoint: flag(src[:visualization_checkpoint] || src['visualization_checkpoint']),
          h5ad_export: flag(src[:h5ad_export] || src['h5ad_export']),
          scfair_h5ad_valid: flag(src[:scfair_h5ad_valid] || src['scfair_h5ad_valid'])
        }
        full = src.key?(:import_full_success) || src.key?('import_full_success')
        normalized[:import_full_success] =
          if full
            flag(src[:import_full_success] || src['import_full_success'])
          else
            normalized.values.all? { |v| v == 1 } ? 1 : 0
          end
        normalized
      end

      def self.flag(value)
        case value
        when true, 1 then 1
        when false, 0, nil then 0
        else
          %w[1 true yes on].include?(value.to_s.strip.downcase) ? 1 : 0
        end
      end

      def merge(attrs)
        base = to_h.except(:import_full_success)
        self.class.from_hash(base.merge(attrs.transform_keys(&:to_sym)))
      end

      def to_h
        {
          import_full_success: self.class.flag(import_full_success),
          parsed: self.class.flag(parsed),
          scfair_loom_valid: self.class.flag(scfair_loom_valid),
          visualization_checkpoint: self.class.flag(visualization_checkpoint),
          h5ad_export: self.class.flag(h5ad_export),
          scfair_h5ad_valid: self.class.flag(scfair_h5ad_valid)
        }
      end

      def full_success?
        to_h[:import_full_success] == 1
      end
    end

    COLUMNS = %w[
      project_key
      import_full_success
      parsed
      scfair_loom_valid
      visualization_checkpoint
      h5ad_export
      scfair_h5ad_valid
    ].freeze

    class << self
      def default_path
        File.join(ENV.fetch('DATA_DIR', Rails.root.join('storage').to_s), 'external_catalog_import_success.tsv')
      end

      def empty_status
        PipelineStatus.empty
      end

      def record!(project_key:, status:, path: default_path)
        key = project_key.to_s.strip
        raise ArgumentError, 'project_key required' if key.blank?

        row = status.is_a?(PipelineStatus) ? status : PipelineStatus.from_hash(status)
        upsert_row!(path, key, row)
        row
      end

      def record_import_attempt!(project:, importer: nil, status: nil, path: default_path)
        return unless project&.key.present?

        row =
          if status
            status.is_a?(PipelineStatus) ? status : PipelineStatus.from_hash(status)
          elsif importer&.last_pipeline_status
            importer.last_pipeline_status
          else
            evaluate(project)
          end
        record!(project_key: project.key, status: row, path: path)
      end

      def evaluate(project, validate_h5ad: validate_h5ad_on_evaluate?)
        return PipelineStatus.empty unless project
        return PipelineStatus.empty if project.being_deleted

        parsed = parsed?(project)
        scfair_loom = scfair_loom_valid?(project)
        visualization_checkpoint = visualization_checkpoint?(project)
        h5ad_export = h5ad_export_ready?(project)
        scfair_h5ad =
          if validate_h5ad && h5ad_export
            scfair_h5ad_valid?(project)
          else
            false
          end

        PipelineStatus.from_hash(
          parsed: parsed,
          scfair_loom_valid: scfair_loom,
          visualization_checkpoint: visualization_checkpoint,
          h5ad_export: h5ad_export,
          scfair_h5ad_valid: scfair_h5ad
        )
      end

      def full_pipeline_success?(project)
        evaluate(project).full_success?
      end

      def read_all(path: default_path)
        return {} unless File.exist?(path)

        rows = {}
        lines = File.readlines(path, chomp: true)
        header = lines.first.to_s.split("\t")
        value_indexes = COLUMNS[1..].index_with { |col| header.index(col) }

        lines.drop(1).each do |line|
          next if line.blank?

          parts = line.split("\t")
          key = parts[0].to_s.strip
          next if key.blank?

          attrs = { import_full_success: 0 }
          value_indexes.each do |col, idx|
            attrs[col.to_sym] = PipelineStatus.flag(idx ? parts[idx] : 0)
          end
          rows[key] = PipelineStatus.from_hash(attrs)
        end
        rows
      end

      def success?(project_key, path: default_path)
        read_all(path: path).fetch(project_key.to_s, PipelineStatus.empty).full_success?
      end

      private

      def validate_h5ad_on_evaluate?
        %w[1 true yes on].include?(ENV.fetch('VALIDATE_H5AD', '0').to_s.strip.downcase)
      end

      def upsert_row!(path, project_key, status)
        FileUtils.mkdir_p(File.dirname(path))
        rows = read_all(path: path)
        rows[project_key] = status
        write_all!(path, rows)
      end

      def write_all!(path, rows)
        FileUtils.mkdir_p(File.dirname(path))
        body = +"#{COLUMNS.join("\t")}\n"
        rows.sort_by { |k, _| k }.each do |key, status|
          values = status.to_h.values_at(
            :import_full_success,
            :parsed,
            :scfair_loom_valid,
            :visualization_checkpoint,
            :h5ad_export,
            :scfair_h5ad_valid
          )
          body << ([key] + values).join("\t") << "\n"
        end

        File.open(path, File::RDWR | File::CREAT, 0o644) do |file|
          file.flock(File::LOCK_EX)
          file.rewind
          file.write(body)
          file.flush
          file.truncate(body.bytesize)
        end
      end

      def parsed?(project)
        run = latest_successful_parsing_run(project)
        return false unless run

        parsed_matrix_present?(project)
      rescue StandardError
        false
      end

      def latest_successful_parsing_run(project)
        success_id = Status.find_by(name: 'success')&.id
        return nil unless success_id

        asap_docker_image = Basic.get_asap_docker(project.version)
        return nil unless asap_docker_image

        parsing_step_ids = Step.where(
          docker_image_id: asap_docker_image.id,
          version_id: project.version_id,
          name: 'parsing'
        ).pluck(:id)
        return nil if parsing_step_ids.empty?

        Run.where(project_id: project.id, step_id: parsing_step_ids, status_id: success_id)
           .order(id: :desc)
           .first
      rescue StandardError
        nil
      end

      def scfair_loom_valid?(project)
        vr = project.cxg_validation_result
        return false if vr.blank?

        vr['valid'] == true || vr[:valid] == true
      end

      def visualization_checkpoint?(project)
        project.checkpoints.visualization.where(is_landing_page: true).exists?
      rescue StandardError
        false
      end

      def h5ad_export_ready?(project)
        loom_rel = loom_rel_for_project(project)
        return false if loom_rel.blank?

        status = Basic.h5ad_export_status(
          project,
          loom_rel,
          run: Basic.latest_h5ad_export_run(project, loom_rel)
        )
        status == 'ready'
      rescue StandardError
        false
      end

      def scfair_h5ad_valid?(project)
        loom_rel = loom_rel_for_project(project)
        return false if loom_rel.blank?

        h5ad_abs = Basic.project_user_dir(project) + Basic.h5ad_rel_path_for_loom(loom_rel)
        return false unless h5ad_abs.exist? && h5ad_abs.size.positive?

        result = ScfairH5adValidatorService.new(h5ad_abs.to_s).validate
        result.valid? && Array(result.errors).empty?
      rescue StandardError
        false
      end

      def parsed_matrix_present?(project)
        dir = Basic.project_user_dir(project)
        return false unless dir.exist?

        loom = dir + 'parsing/output.loom'
        return true if loom.exist? && loom.size.positive?

        Dir.glob(dir.join('parsing/*.loom').to_s).any? { |f| File.size(f).positive? }
      rescue StandardError
        false
      end

      def loom_rel_for_project(project)
        dir = Basic.project_user_dir(project)
        canonical = dir + 'parsing/output.loom'
        return 'parsing/output.loom' if canonical.exist?

        glob = Dir.glob(dir.join('parsing/*.loom').to_s).sort
        return nil if glob.empty?

        Pathname.new(glob.first).relative_path_from(dir).to_s
      rescue StandardError
        nil
      end
    end
  end
end
