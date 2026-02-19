class AddResultDigestToComplianceValidations < ActiveRecord::Migration[7.2]
  def change
    add_column :compliance_validations, :result_digest, :string, limit: 32
  end
end
