class AddTwoTierFieldsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :tier1_hash, :string, limit: 16
    add_column :users, :tier2_vector, :text
    add_column :users, :tier2_user_key, :text

    add_index :users, :tier1_hash
  end
end