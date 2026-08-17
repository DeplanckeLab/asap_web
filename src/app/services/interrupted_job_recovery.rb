# frozen_string_literal: true

# Re-enqueue work that was in progress when the Solid Queue worker died.
# Queued jobs live in Postgres and survive a compose restart; claimed jobs are
# marked failed when the worker process is pruned. This reads durable status
# flags and puts those jobs back on the queue.
class InterruptedJobRecovery
  LOCK_KEY = 0x5A5A_5A5A
  CELL_SELECTION_STEP_NAME = 'cell_selection'

  def self.worker_process?
    return true if ENV['SOLID_QUEUE_RECOVERY'] == '1'

    program = File.basename($PROGRAM_NAME).to_s
    program == 'jobs' || ARGV.include?('solid_queue:start')
  end

  def self.call
    new.call
  end

  def call
    recover_slurm_waiting_runs
    recover_slurm_monitors
    recover_archives
    recover_unarchives
    recover_publications
    recover_fus
    recover_selection_imports
    recover_gene_set_imports
    recover_clones
    recover_project_validations
    recover_module_scores
  end

  private

  def recover_slurm_waiting_runs
    Run.where(status_id: [1, 6])
       .where('slurm_job_id IS NULL OR slurm_job_id = 0')
       .joins(:step)
       .where.not(steps: { name: CELL_SELECTION_STEP_NAME })
       .find_each do |run|
      enqueue(RunExecutionJob, run.id)
    end
  end

  def recover_slurm_monitors
    Run.where(status_id: [1, 2, 6]).find_each do |run|
      slurm_job_id = (run.slurm_job_id.presence || run.pid).to_s
      next if slurm_job_id.blank? || slurm_job_id == '0'
      next if run.step&.name == CELL_SELECTION_STEP_NAME

      enqueue(SlurmJobMonitorJob, run.id, slurm_job_id)
    end
  end

  def recover_archives
    Project.where(archive_status_id: 2).find_each do |project|
      enqueue(ArchiveProjectJob, project.id)
    end
  end

  def recover_unarchives
    Project.where(archive_status_id: 4).find_each do |project|
      enqueue(ProjectUnarchiveJob, project.id)
    end
  end

  def recover_publications
    Project.where(being_published: true).find_each do |project|
      enqueue(FinalizeProjectPublicationJob, project.id)
    end
  end

  def recover_fus
    Fu.where(status: 'downloading').find_each do |fu|
      next if fu.url.blank?

      if fu.compliance_schema_id.present? || fu.compliance_task_id.present?
        if fu.compliance_schema_id.blank? || fu.compliance_task_id.blank?
          Rails.logger.error("[InterruptedJobRecovery] Fu##{fu.id} compliance download missing schema_id or task_id; not re-queued")
          next
        end
        enqueue(IsolatedComplianceUrlDownloadJob, fu.id)
        next
      end

      organism_id = fu.project&.organism_id
      version_id = fu.preparsing_version_id || fu.project&.version_id
      enqueue(FuDownloadFromUrlJob, fu.id, fu.url, organism_id: organism_id, version_id: version_id)
    end

    Fu.where(status: 'preparsing').find_each do |fu|
      version_id = fu.preparsing_version_id || fu.project&.version_id
      if version_id.blank?
        Rails.logger.error("[InterruptedJobRecovery] Fu##{fu.id} preparsing has no version_id; not re-queued")
        next
      end

      options = { version_id: version_id }
      organism_id = fu.project&.organism_id
      options[:organism_id] = organism_id if organism_id.present?
      enqueue(FuPreparsingJob, fu.id, options)
    end

    Fu.where(status: 'validating').find_each do |fu|
      path = fu.file_path&.to_s
      if path.blank? || !File.exist?(path)
        Rails.logger.error("[InterruptedJobRecovery] Fu##{fu.id} validating but file is missing; not re-queued")
        next
      end

      schema_id = fu.compliance_schema_id
      if schema_id.blank?
        Rails.logger.error("[InterruptedJobRecovery] Fu##{fu.id} validating but no compliance_schema_id is stored; not re-queued")
        next
      end

      task_id = fu.compliance_task_id
      if task_id.blank?
        Rails.logger.error("[InterruptedJobRecovery] Fu##{fu.id} validating but no compliance_task_id is stored; not re-queued")
        next
      end

      enqueue(
        IsolatedComplianceValidationJob,
        task_id,
        path,
        schema_id,
        fu.name.presence || fu.upload_file_name,
        uniqueness: fu.id,
        fu_id: fu.id
      )
    end
  end

  def recover_selection_imports
    Run.joins(:step)
       .where(steps: { name: CELL_SELECTION_STEP_NAME })
       .where(status_id: [1, 2])
       .find_each do |run|
      enqueue(SelectionMetadataImportJob, run.id)
    end
  end

  def recover_gene_set_imports
    GeneSetCollection.where('staged_upload_path IS NOT NULL OR import_id IS NOT NULL').find_each do |collection|
      path = collection.staged_upload_path.presence || collection.expected_staged_upload_path
      next if path.blank?
      next if collection.staged_upload_path.blank? && collection.payload_written?

      if !File.exist?(path)
        if collection.staged_upload_path.present?
          Rails.logger.error("[InterruptedJobRecovery] GeneSetCollection##{collection.id} staged file missing; not re-queued")
        end
        next
      end
      if collection.import_loom_file.blank?
        Rails.logger.error("[InterruptedJobRecovery] GeneSetCollection##{collection.id} has no import_loom_file; not re-queued")
        next
      end

      import_id = collection.import_id
      if import_id.blank?
        Rails.logger.error("[InterruptedJobRecovery] GeneSetCollection##{collection.id} has no import_id; not re-queued")
        next
      end

      enqueue(
        GeneSetCollectionImportJob,
        collection.project_id,
        collection.id,
        path,
        import_id,
        collection.import_loom_file
      )
    end
  end

  def recover_clones
    Project.where(being_cloned: true).find_each do |project|
      enqueue(ProjectCloneJob, project.id)
    end
  end

  def recover_project_validations
    Project.where(being_validated: true).find_each do |project|
      enqueue(ScfairValidationJob, project.id)
    end
  end

  def recover_module_scores
    ModuleScoreRequest.where(status: %w[pending running]).find_each do |request|
      enqueue(GeneSetItemModuleScoreJob, request.id)
    end
  end

  def enqueue(job_class, *args, uniqueness: nil, **kwargs)
    token = uniqueness.nil? ? args.first : uniqueness
    if unfinished_job?(job_class, token)
      Rails.logger.info("[InterruptedJobRecovery] skip #{job_class.name} already queued token=#{token.inspect}")
      return
    end

    if kwargs.empty?
      job_class.perform_later(*args)
    else
      job_class.perform_later(*args, **kwargs)
    end
    Rails.logger.info("[InterruptedJobRecovery] enqueued #{job_class.name} args=#{args.inspect} kwargs=#{kwargs.inspect}")
  end

  def unfinished_job?(job_class, token)
    return false unless defined?(SolidQueue::Job)
    return false unless SolidQueue::Job.table_exists?
    return false if token.nil?

    SolidQueue::Job.where(class_name: job_class.name, finished_at: nil).any? do |job|
      job.arguments.to_s.include?(token.to_s)
    end
  end
end
