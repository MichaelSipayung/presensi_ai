class AddSketchToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :sketch, :bit, limit: 64
  end
end