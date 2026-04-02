class AddPlatformToGroups < ActiveRecord::Migration[7.0]
  def change
    add_column :groups, :platform, :string
  end
end
