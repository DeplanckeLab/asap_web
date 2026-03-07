class RenameValidToPassedInComplianceValidations < ActiveRecord::Migration[7.2]
  def up
    unless table_exists?(:compliance_validations)
      raise "Table compliance_validations does not exist"
    end

    has_valid = column_exists?(:compliance_validations, :valid)
    has_passed = column_exists?(:compliance_validations, :passed)

    if has_valid && !has_passed
      rename_column :compliance_validations, :valid, :passed
    elsif !has_valid && has_passed
      say "Column already renamed (valid -> passed), skipping"
    else
      raise "Unexpected compliance_validations column state (valid: #{has_valid}, passed: #{has_passed})"
    end
  end

  def down
    unless table_exists?(:compliance_validations)
      raise "Table compliance_validations does not exist"
    end

    has_valid = column_exists?(:compliance_validations, :valid)
    has_passed = column_exists?(:compliance_validations, :passed)

    if has_passed && !has_valid
      rename_column :compliance_validations, :passed, :valid
    elsif has_valid && !has_passed
      say "Column already renamed back (passed -> valid), skipping"
    else
      raise "Unexpected compliance_validations column state (valid: #{has_valid}, passed: #{has_passed})"
    end
  end
end
