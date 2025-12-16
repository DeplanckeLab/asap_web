namespace :slurm do
  desc "Initialize SLURM accounts for all users in the database"
  task init_accounts: :environment do
    puts "Initializing SLURM accounts for all users..."
    
    # Get all user IDs from the users table
    user_ids = User.pluck(:id).compact.sort
    
    if user_ids.empty?
      puts "No users found in users table."
      return
    end
    
    puts "Found #{user_ids.count} users: #{user_ids.inspect}"
    
    created_count = 0
    failed_count = 0
    
    user_ids.each do |user_id|
      account_name = "user_#{user_id}"
      puts "Creating account: #{account_name}..."
      
      begin
        db_result = create_account_via_db(account_name)
        if db_result
          puts "  ✓ Created account: #{account_name}"
          created_count += 1
        else
          puts "  ✗ Failed to create account: #{account_name}"
          failed_count += 1
        end
      rescue => e
        puts "  ✗ Exception creating account #{account_name}: #{e.message}"
        failed_count += 1
      end
    end
    
    puts "\nSummary:"
    puts "  Created: #{created_count}"
    puts "  Failed: #{failed_count}"
    puts "  Total: #{user_ids.count}"
  end
  
  desc "Create SLURM account for a specific user ID"
  task :create_account, [:user_id] => :environment do |t, args|
    user_id = args[:user_id]&.to_i
    
    unless user_id && user_id > 0
      puts "Usage: rails slurm:create_account[USER_ID]"
      puts "Example: rails slurm:create_account[5]"
      exit 1
    end
    
    account_name = "user_#{user_id}"
    puts "Creating SLURM account: #{account_name}..."
    
    if SlurmAccountService.create_account_for_user(user_id)
      puts "✓ Successfully created account: #{account_name}"
    else
      puts "✗ Failed to create account: #{account_name}"
      exit 1
    end
  end
  
  desc "List all SLURM accounts"
  task list_accounts: :environment do
    puts "Listing SLURM accounts..."
    list_accounts_via_db
  end
  
  private
  
  def create_account_via_db(account_name)
    # Extract user_id from account_name (format: "user_123")
    user_id = account_name.gsub('user_', '').to_i
    SlurmAccountService.create_account_for_user(user_id)
  end
  
  def list_accounts_via_db
    begin
      db_cmd = "docker exec slurmdb mysql -u slurm -pslurm slurm_acct_db -e 'SELECT name, description FROM acct_table;' 2>&1"
      result = `#{db_cmd}`
      if $?.success?
        puts result
      else
        puts "Failed to list accounts from database"
      end
    rescue => e
      puts "Error listing accounts: #{e.message}"
    end
  end
end

