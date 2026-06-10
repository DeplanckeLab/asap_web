# frozen_string_literal: true

class CreateAssembliesAndAddFirstEnsemblReleaseToGenes < ActiveRecord::Migration[8.1]
  def change
    create_table :assemblies, id: :serial do |t|
      t.text :name
      t.integer :first_ensembl_release
      t.integer :latest_ensembl_release
    end

    add_column :genes, :first_ensembl_release, :integer
  end
end
