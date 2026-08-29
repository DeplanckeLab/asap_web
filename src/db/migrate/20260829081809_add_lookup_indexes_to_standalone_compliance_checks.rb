# frozen_string_literal: true

class AddLookupIndexesToStandaloneComplianceChecks < ActiveRecord::Migration[7.2]
  def change
    add_index :standalone_compliance_checks, :source_url,
              name: 'index_standalone_compliance_checks_on_source_url'
    add_index :standalone_compliance_checks, :filename,
              name: 'index_standalone_compliance_checks_on_filename'
  end
end
