class AddPageDigestToGroups < ActiveRecord::Migration[7.0]
  def change
    add_column :groups, :page_digest, :string
  end
end
