# frozen_string_literal: true

class RemoveUniqueIndexFromAssembliesOrganismId < ActiveRecord::Migration[8.1]
  def up
    remove_index :assemblies, name: "index_assemblies_on_organism_id"
    add_index :assemblies, :organism_id, name: "index_assemblies_on_organism_id"
    add_index :assemblies, %i[organism_id name], unique: true, name: "index_assemblies_on_organism_id_and_name"
  end

  def down
    remove_index :assemblies, name: "index_assemblies_on_organism_id_and_name"
    remove_index :assemblies, name: "index_assemblies_on_organism_id"
    add_index :assemblies, :organism_id, unique: true, name: "index_assemblies_on_organism_id"
  end
end
