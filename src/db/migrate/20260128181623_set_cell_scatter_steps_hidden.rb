class SetCellScatterStepsHidden < ActiveRecord::Migration[8.1]
  def up
    # Use raw SQL with error handling
    begin
      execute("UPDATE steps SET hidden = TRUE WHERE name = 'cell_scatter'") if table_exists?(:steps)
    rescue ActiveRecord::StatementInvalid => e
      # If table doesn't exist, skip silently (might be running before schema is loaded)
      Rails.logger.warn("Could not update steps table: #{e.message}") if defined?(Rails)
    end
  end

  def down
    # Use raw SQL with error handling
    begin
      execute("UPDATE steps SET hidden = FALSE WHERE name = 'cell_scatter'") if table_exists?(:steps)
    rescue ActiveRecord::StatementInvalid => e
      # If table doesn't exist, skip silently
      Rails.logger.warn("Could not update steps table: #{e.message}") if defined?(Rails)
    end
  end
end
