class SlurmAccountService
  def self.create_account_for_user(user_id)
    # Check if account already exists
    return true if account_exists?(user_id)
    
    account_name = "user_#{user_id}"
    
    creation_time = Time.now.to_i
    mod_time = creation_time
    
    # Insert account into acct_table
    db_cmd = <<~SQL
      docker exec slurmdb mysql -u slurm -pslurm slurm_acct_db -e "
      INSERT IGNORE INTO acct_table (creation_time, mod_time, deleted, name, description, organization)
      VALUES (#{creation_time}, #{mod_time}, 0, '#{account_name}', 'Account for user #{account_name}', 'asap_cluster');
      " 2>&1
    SQL
    
    result = `#{db_cmd}`
    
    if $?.success?
      # Also create association for root user (uid 0) with this account
      # This allows jobs submitted as root to use the account
      parent_id = 1  # Root account parent
      
      assoc_cmd = <<~SQL
        docker exec slurmdb mysql -u slurm -pslurm slurm_acct_db -e "
        INSERT IGNORE INTO asap_cluster_assoc_table 
        (creation_time, mod_time, deleted, user, acct, \\\`partition\\\`, parent_acct, lft, rgt, shares, is_def, max_tres_pj, max_tres_pn, max_tres_mins_pj, grp_tres, qos, delta_qos)
        VALUES 
        (#{creation_time}, #{mod_time}, 0, 'root', '#{account_name}', '', 'root', 1, 1, 1, 0, '', '', '', '', '', '');
        " 2>&1
      SQL
      
      assoc_result = `#{assoc_cmd}`
      return $?.success?
    else
      Rails.logger.error("[SlurmAccountService] Failed to create account in database: #{result}")
      return false
    end
  rescue => e
    Rails.logger.error("[SlurmAccountService] Failed to create account via database: #{e.message}")
    false
  end
  
  def self.account_exists?(user_id)
    account_name = "user_#{user_id}"
    # Use -Nse flags: -N (no column names), -s (silent), -e (execute)
    # Redirect stderr to avoid warnings interfering with output
    check_db_cmd = "docker exec slurmdb mysql -u slurm -pslurm slurm_acct_db -Nse \"SELECT COUNT(*) FROM acct_table WHERE name='#{account_name}' AND deleted=0;\" 2>/dev/null"
    db_result = `#{check_db_cmd}`.strip
    $?.success? && db_result.to_i > 0
  rescue => e
    Rails.logger.error("[SlurmAccountService] Error checking account: #{e.message}")
    false
  end
end

