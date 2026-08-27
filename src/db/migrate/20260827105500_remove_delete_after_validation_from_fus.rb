# frozen_string_literal: true

# Temporary column from an abandoned approach; remote downloads are cleaned up
# via Fu#url + fu_id after validation instead.
class RemoveDeleteAfterValidationFromFus < ActiveRecord::Migration[8.0]
  def up
    remove_column :fus, :delete_after_validation if column_exists?(:fus, :delete_after_validation)
  end

  def down
    return if column_exists?(:fus, :delete_after_validation)

    add_column :fus, :delete_after_validation, :boolean, null: false, default: false
  end
end
