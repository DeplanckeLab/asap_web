# frozen_string_literal: true

class AddInsdcAccessionToAssemblies < ActiveRecord::Migration[8.1]
  def change
    add_column :assemblies, :insdc_accession, :text
  end
end
