class AddGithubDiscussionFieldsToNewsItems < ActiveRecord::Migration[8.1]
  def change
    add_column :news_items, :github_discussion_node_id, :string
    add_column :news_items, :github_discussion_url, :string
    add_column :news_items, :github_discussion_number, :integer
    add_column :news_items, :github_synced_at, :datetime

    add_index :news_items, :github_discussion_node_id, unique: true
    add_index :news_items, :github_discussion_number
  end
end
