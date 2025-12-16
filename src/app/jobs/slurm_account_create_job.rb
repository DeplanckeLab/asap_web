class SlurmAccountCreateJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    # Check if account already exists
    if SlurmAccountService.account_exists?(user_id)
      Rails.logger.info("[SlurmAccountCreateJob] SLURM account for user #{user_id} already exists, skipping creation")
      return
    end
    
    Rails.logger.info("[SlurmAccountCreateJob] Creating SLURM account for user #{user_id}")
    
    if SlurmAccountService.create_account_for_user(user_id)
      Rails.logger.info("[SlurmAccountCreateJob] Successfully created SLURM account for user #{user_id}")
    else
      Rails.logger.error("[SlurmAccountCreateJob] Failed to create SLURM account for user #{user_id}")
    end
  rescue => e
    Rails.logger.error("[SlurmAccountCreateJob] Error creating SLURM account for user #{user_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
  end
end

