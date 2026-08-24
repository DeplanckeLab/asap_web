class AddCreatorIpToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :creator_ip, :string
  end
end
