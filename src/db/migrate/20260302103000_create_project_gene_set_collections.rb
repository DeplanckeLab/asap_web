class CreateProjectGeneSetCollections < ActiveRecord::Migration[7.2]
  def change
    create_table :gene_set_collections do |t|
      t.integer :project_id, null: false
      t.integer :user_id
      t.string :name, null: false
      t.string :file_key, null: false
      t.string :source_kind, null: false

      t.timestamps
    end

    add_index :gene_set_collections, :project_id
    add_index :gene_set_collections, :user_id
    add_index :gene_set_collections, :file_key, unique: true
    add_index :gene_set_collections, [:project_id, :source_kind]
  end
end
