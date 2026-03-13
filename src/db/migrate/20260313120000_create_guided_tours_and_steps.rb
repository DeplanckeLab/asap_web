class CreateGuidedToursAndSteps < ActiveRecord::Migration[8.1]
  def change
    create_table :guided_tours do |t|
      t.string :name, null: false
      t.integer :rank, null: false
      t.integer :duration_time

      t.timestamps
    end

    add_index :guided_tours, :rank

    create_table :guided_tour_steps do |t|
      t.references :guided_tour, null: false, foreign_key: true
      t.integer :rank, null: false
      t.string :page_url, null: false
      t.string :title, null: false
      t.string :focus_element, null: false
      t.text :description

      t.timestamps
    end

    add_index :guided_tour_steps, [:guided_tour_id, :rank], unique: true
  end
end
