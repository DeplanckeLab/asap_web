# frozen_string_literal: true

class CreateServerErrors < ActiveRecord::Migration[8.1]
  def change
    create_table :server_errors do |t|
      t.string :exception_class, null: false, default: 'UnknownError'
      t.text :message
      t.text :backtrace
      t.string :path, null: false, default: ''
      t.string :http_method, null: false, default: 'GET', limit: 16
      t.integer :status, null: false, default: 500
      t.string :request_id, limit: 64
      t.string :ip, limit: 64
      t.references :user, foreign_key: { on_delete: :nullify }
      t.text :user_agent
      t.text :filtered_params

      t.timestamps
    end

    add_index :server_errors, :created_at
    add_index :server_errors, :exception_class
    add_index :server_errors, :status
  end
end
