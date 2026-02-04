class PopulateStatusIcons < ActiveRecord::Migration[8.1]
  def up
    # Populate icon_class for each status
    # Using actual database status names
    status_icons = {
      'pending' => 'fas fa-hourglass-half',  # ID 1 - used as "waiting" in views
      'running' => 'fas fa-spinner',          # ID 2
      'success' => 'fas fa-check-circle',     # ID 3 - used as "completed" in views
      'failed' => 'fas fa-exclamation-circle', # ID 4
      'waiting' => 'fas fa-hourglass-half',   # ID 6 - also uses hourglass
      'stopped' => 'fas fa-stop-circle'       # ID 5
    }

    status_icons.each do |name, icon_class|
      execute <<-SQL.squish
        UPDATE statuses
        SET icon_class = '#{icon_class}'
        WHERE LOWER(name) = '#{name}'
      SQL
    end
  end

  def down
    # Clear the icon_class column
    execute <<-SQL.squish
      UPDATE statuses
      SET icon_class = NULL
    SQL
  end
end

