# frozen_string_literal: true

class AddBeingPublishedToProjects < ActiveRecord::Migration[7.2]
  def change
    add_column :projects, :being_published, :boolean, default: false, null: false
    add_column :projects, :publication_error, :text
  end
end
