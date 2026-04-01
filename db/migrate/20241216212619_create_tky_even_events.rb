class CreateTkyEvenEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :tky_even_events do |t|
      t.references :tky_even_meetup, null: false, foreign_key: true
      t.string :meetup_event_id
      t.string :name
      t.string :venue
      t.string :local_date
      t.string :url
      t.string :description
      t.datetime :event_date

      t.timestamps
    end
  end
end