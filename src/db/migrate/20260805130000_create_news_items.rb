class CreateNewsItems < ActiveRecord::Migration[8.1]
  def change
    create_table :news_items do |t|
      t.string :title, null: false
      t.text :body, null: false
      t.string :news_type, null: false, default: 'announcement'
      t.string :icon, null: false
      t.datetime :published_at, null: false
      t.boolean :published, null: false, default: true
      t.boolean :show_on_welcome, null: false, default: true
      t.integer :user_id

      t.timestamps
    end

    add_index :news_items, :user_id
    add_index :news_items, :news_type
    add_index :news_items, :published
    add_index :news_items, :published_at
    add_index :news_items, :show_on_welcome
    add_foreign_key :news_items, :users
  end
end
