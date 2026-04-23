class AddBadgeClassesToStatuses < ActiveRecord::Migration[7.1]
  # Store Tailwind badge classes for each run status directly in the database so
  # views and helpers can render the correct pill without hardcoded case/when
  # statements. Also store a human-facing display label so we are not forced to
  # derive it from +name+ or the legacy +label+ column (which holds Bootstrap
  # alert classes like "default", "info", "danger").
  def up
    add_column :statuses, :badge_bg_class, :text unless column_exists?(:statuses, :badge_bg_class)
    add_column :statuses, :badge_text_class, :text unless column_exists?(:statuses, :badge_text_class)
    add_column :statuses, :display_label, :text unless column_exists?(:statuses, :display_label)

    badges = {
      'pending' => { bg: 'bg-yellow-100', text: 'text-yellow-800', label: 'Pending' },
      'running' => { bg: 'bg-blue-100',   text: 'text-blue-800',   label: 'Running' },
      'success' => { bg: 'bg-green-100',  text: 'text-green-800',  label: 'Success' },
      'failed'  => { bg: 'bg-red-100',    text: 'text-red-800',    label: 'Failed'  },
      'stopped' => { bg: 'bg-gray-100',   text: 'text-gray-800',   label: 'Stopped' },
      'waiting' => { bg: 'bg-yellow-100', text: 'text-yellow-800', label: 'Waiting' }
    }

    badges.each do |name, cfg|
      execute(
        ActiveRecord::Base.sanitize_sql_array([
          "UPDATE statuses SET badge_bg_class = ?, badge_text_class = ?, display_label = ? WHERE LOWER(name) = ?",
          cfg[:bg], cfg[:text], cfg[:label], name
        ])
      )
    end
  end

  def down
    remove_column :statuses, :badge_bg_class if column_exists?(:statuses, :badge_bg_class)
    remove_column :statuses, :badge_text_class if column_exists?(:statuses, :badge_text_class)
    remove_column :statuses, :display_label if column_exists?(:statuses, :display_label)
  end
end
