class AddStatusIconStyles < ActiveRecord::Migration[8.1]
  def up
    add_column :statuses, :icon_spin, :text
    add_column :statuses, :active_color, :text
    add_column :statuses, :inactive_color, :text

    # Populate the new columns for each status
    status_styles = {
      'pending' => { icon_spin: '', active_color: 'text-yellow-500', inactive_color: 'text-gray-300' },
      'waiting' => { icon_spin: '', active_color: 'text-yellow-500', inactive_color: 'text-gray-300' },
      'running' => { icon_spin: 'fa-spin', active_color: 'text-blue-500', inactive_color: 'text-gray-300' },
      'success' => { icon_spin: '', active_color: 'text-green-500', inactive_color: 'text-gray-300' },
      'failed' => { icon_spin: '', active_color: 'text-red-500', inactive_color: 'text-gray-300' },
      'stopped' => { icon_spin: '', active_color: 'text-gray-500', inactive_color: 'text-gray-300' }
    }

    status_styles.each do |name, styles|
      execute <<-SQL.squish
        UPDATE statuses
        SET icon_spin = '#{styles[:icon_spin]}',
            active_color = '#{styles[:active_color]}',
            inactive_color = '#{styles[:inactive_color]}'
        WHERE LOWER(name) = '#{name}'
      SQL
    end
  end

  def down
    remove_column :statuses, :icon_spin
    remove_column :statuses, :active_color
    remove_column :statuses, :inactive_color
  end
end

