class Run < ApplicationRecord
  before_destroy :prevent_deletion_if_locked_from_publication

  belongs_to :project
  belongs_to :step
  belongs_to :status, optional: true
  belongs_to :std_method, optional: true
  belongs_to :req, optional: true
  belongs_to :user, optional: true
  belongs_to :job, optional: true
  belongs_to :docker_build, optional: true

  has_many :annots, dependent: :destroy
  has_many :fos, dependent: :destroy
  has_many :checkpoints, dependent: :nullify
  has_one :active_run, dependent: :destroy

  scope :dimension_reduction, -> { joins(:step).where(steps: { name: Step::EMBEDDING_STEP_NAMES }) }
  scope :clustering, -> { joins(:step).where(steps: { name: 'clustering' }) }

  def embedding_run?
    step&.embedding_step?
  end

  def clustering_run?
    step&.name == 'clustering'
  end

  # Reset queue-wait clock fields when the same Run row is reused for a new attempt
  # (re-run, re-parse, project reset). Call before setting status to waiting/submitted.
  def reset_wait_timing!
    update!(
      submitted_at: Time.current,
      waiting_duration: nil,
      start_time: nil
    )
  end

  # Push a synchronous run-level status change over ActionCable.
  #
  # This is the single source of truth for UI-facing run transitions: it
  # builds the same step-level payload as ProjectBroadcastJob (so the left
  # panel icon and the page header stay in sync via h_nber_analyses /
  # project_run_totals) and adds run-specific fields so the client can
  # update the run row in the right panel without a follow-up HTTP fetch.
  #
  # Call this from the places that actually mutate a run's status (job
  # submission, SLURM running transition, finish_run, failure paths).
  def broadcast_status_change
    return unless project_id && step_id

    project.reload
    step_record = step || Step.find_by(id: step_id)
    return unless step_record

    base = ProjectBroadcastJob.build_payload(project, step_id)

    status_record = Status.find_by(id: status_id)
    base.merge!(
      event: 'run_status_changed',
      run_status: {
        run_id: id,
        step_id: step_id,
        status_id: status_id,
        status_name: status_record&.name ? status_record.name.humanize : 'Unknown',
        start_time: start_time&.iso8601,
        submitted_at: submitted_at&.iso8601,
        waiting_duration: waiting_duration ? waiting_duration.to_i : nil,
        duration: duration ? duration.to_i : nil,
        slurm_job_id: slurm_job_id
      }
    )

    ActionCable.server.broadcast("project_#{project_id}", base)
  rescue StandardError => e
    Rails.logger.warn("[Run#broadcast_status_change] run_id=#{id}: #{e.class} - #{e.message}")
  end

  # Categorical metadata Annot#id for a FindMarkers run (from attrs_json groups_dataset / groups_filename).
  def marker_metadata_annot_id
    return nil unless step&.name == 'markers'

    h = Basic.safe_parse_json(attrs_json, {})
    gfn = h['groups_filename'] || h[:groups_filename]
    name = h['groups_dataset'] || h[:groups_dataset]
    return nil if gfn.blank? || name.blank?

    pd = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
    full = Pathname.new(gfn.to_s)
    rel = full.relative_path_from(pd).to_s
    Annot.find_by(project_id: project_id, name: name.to_s, filepath: rel)&.id
  rescue ArgumentError
    nil
  end

  # runs.max_ram storage units:
  # - Before 2025-12-17 Basic.finish_run wrote GNU time %M directly (kilobytes).
  # - Since then it stores megabytes (KB/1024). Slurm monitor also stores MB.
  # Values that would be >= 1 TiB if read as MB are still unconverted KB writes.
  MAX_RAM_STORED_AS_MB_FROM = Time.utc(2025, 12, 17)
  MAX_PLAUSIBLE_RAM_MB = 1024 * 1024

  def max_ram_mb
    return nil if max_ram.nil?

    value = max_ram.to_f
    return value / 1024.0 if value >= MAX_PLAUSIBLE_RAM_MB
    return value / 1024.0 if created_at.present? && created_at < MAX_RAM_STORED_AS_MB_FROM

    value
  end

  def max_ram_gb
    mb = max_ram_mb
    return nil if mb.nil?

    (mb / 1024.0).round(4)
  end

  private

    def prevent_deletion_if_locked_from_publication
      return unless project&.locked_from_publication?(self)

      errors.add(:base, 'This run was created before publication and cannot be deleted.')
      throw(:abort)
    end
end
