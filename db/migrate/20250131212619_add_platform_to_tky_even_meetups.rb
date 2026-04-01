class AddPlatformToTkyEvenMeetups < ActiveRecord::Migration[7.0]
  def change
    add_column :tky_even_meetups, :platform, :string
  end
end
