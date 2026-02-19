class RenameValidToPassedInComplianceValidations < ActiveRecord::Migration[7.2]
  def change
    rename_column :compliance_validations, :valid, :passed
  end
end
