class CreateAttendances < ActiveRecord::Migration[8.1]
  def change
    create_table :attendances do |t|
      t.references :user, null: false, foreign_key: true
      t.string :status
      t.string :latitude
      t.string :longitude
      t.string :photo_path

      t.timestamps
    end
  end
end
