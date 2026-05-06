class AddHiddenToGuidedTours < ActiveRecord::Migration[8.1]
  def change
    add_column :guided_tours, :hidden, :boolean, null: false, default: false
  end
end
