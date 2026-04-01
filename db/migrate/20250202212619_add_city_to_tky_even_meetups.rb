class AddCityToTkyEvenMeetups < ActiveRecord::Migration[7.0]
  def change
    add_column :tky_even_meetups, :city, :string
  end
end
