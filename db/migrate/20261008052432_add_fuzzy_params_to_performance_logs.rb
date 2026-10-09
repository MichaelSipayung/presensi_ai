class AddFuzzyParamsToPerformanceLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :performance_logs, :brightness_score, :float
    add_column :performance_logs, :sharpness_score, :float
    add_column :performance_logs, :fuzzy_k_limit, :integer
    add_column :performance_logs, :fuzzy_threshold, :float
    add_column :performance_logs, :fuzzy_status, :string
  end
end