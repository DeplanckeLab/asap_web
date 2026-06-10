# frozen_string_literal: true

class AddOrganismIdToAssemblies < ActiveRecord::Migration[8.1]
  def up
    execute("TRUNCATE TABLE assemblies")

    add_column :assemblies, :organism_id, :integer, null: false
    add_index :assemblies, :organism_id, unique: true, name: "index_assemblies_on_organism_id"
    add_foreign_key :assemblies, :organisms, column: :organism_id, name: "assemblies_organism_id_fkey"
  end

  def down
    remove_foreign_key :assemblies, name: "assemblies_organism_id_fkey"
    remove_index :assemblies, name: "index_assemblies_on_organism_id"
    remove_column :assemblies, :organism_id
  end
end
