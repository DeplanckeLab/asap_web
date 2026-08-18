# frozen_string_literal: true

class AddAdminReportOnlyToProjectTypes < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:project_types)

    unless column_exists?(:project_types, :admin_report_only)
      add_column :project_types, :admin_report_only, :boolean, null: false, default: false
    end

    execute <<~SQL.squish
      UPDATE project_types
      SET admin_report_only = TRUE
      WHERE tag IN ('spat', 'atac', 'multi')
    SQL
  end

  def down
    return unless table_exists?(:project_types)

    remove_column :project_types, :admin_report_only if column_exists?(:project_types, :admin_report_only)
  end
end
