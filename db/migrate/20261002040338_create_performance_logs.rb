# db/migrate/xxxxxx_create_performance_logs.rb
class CreatePerformanceLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :performance_logs do |t|
      t.string  :event_type        # "registration_dedup" atau "attendance"
      t.string  :tier1_hash
      t.integer :probe_candidate_count   # jumlah kandidat dari multi-probe (sebelum fallback)
      t.boolean :used_fallback, default: false
      t.integer :fallback_candidate_count  # jumlah user discan saat fallback (0 kalau tidak fallback)
      t.float   :probe_time_ms      # waktu tahap multi-probe (query DB + Tier 2 verifikasi kandidat)
      t.float   :fallback_time_ms   # waktu tahap fallback (0 kalau tidak terpicu)
      t.float   :total_time_ms      # total end-to-end (ekstraksi wajah C++ + rotasi + pencarian)
      t.float   :best_similarity
      t.boolean :match_found
      t.references :matched_user, foreign_key: { to_table: :users }, null: true

      t.timestamps
    end
  end
end