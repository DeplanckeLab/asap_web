class AddResultDigestToComplianceValidations < ActiveRecord::Migration[7.2]
  def up
    unless table_exists?(:compliance_validations)
      raise "Table compliance_validations does not exist"
    end

    if column_exists?(:compliance_validations, :result_digest)
      say "Column result_digest already exists, skipping"
    else
      add_column :compliance_validations, :result_digest, :string, limit: 32
    end
  end

  def down
    unless table_exists?(:compliance_validations)
      raise "Table compliance_validations does not exist"
    end

    if column_exists?(:compliance_validations, :result_digest)
      remove_column :compliance_validations, :result_digest
    else
      say "Column result_digest already removed, skipping"
    end
  end
end
