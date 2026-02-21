class CreateRatings < ActiveRecord::Migration[7.2]
  def change
    create_table :ratings do |t|
      t.integer :user_id, null: false
      t.integer :stars, null: false
      t.text :review
      t.boolean :display_publicly, null: false, default: false
      t.boolean :use_for_funding, null: false, default: false

      t.timestamps
    end

    add_index :ratings, :user_id
    add_index :ratings, :stars
  end
end
