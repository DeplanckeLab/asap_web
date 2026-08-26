# frozen_string_literal: true

class AddAdminRunAndCreatorIpToStandaloneComplianceChecks < ActiveRecord::Migration[7.2]
  def change
    add_column :standalone_compliance_checks, :admin_run, :boolean, null: false, default: false
    add_column :standalone_compliance_checks, :creator_ip, :string
    add_index :standalone_compliance_checks, :admin_run

    add_column :fus, :admin_run, :boolean, null: false, default: false
    add_column :fus, :creator_ip, :string
  end
end
