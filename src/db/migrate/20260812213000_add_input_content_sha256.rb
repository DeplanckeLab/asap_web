# frozen_string_literal: true

class AddInputContentSha256 < ActiveRecord::Migration[8.1]
  def change
    add_column :fus, :content_sha256, :string, limit: 64
    add_index :fus, :content_sha256

    add_column :projects, :input_content_sha256, :string, limit: 64
    add_index :projects, :input_content_sha256
  end
end
