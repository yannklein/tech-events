class AddCityToGroups < ActiveRecord::Migration[7.0]
  def change
    add_column :groups, :city, :string
  end
end
