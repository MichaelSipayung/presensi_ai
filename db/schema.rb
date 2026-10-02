# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_02_040338) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vector"

  create_table "attendances", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "latitude"
    t.string "longitude"
    t.string "photo_path"
    t.string "status"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_attendances_on_user_id"
  end

  create_table "performance_logs", force: :cascade do |t|
    t.float "best_similarity"
    t.datetime "created_at", null: false
    t.string "event_type"
    t.integer "fallback_candidate_count"
    t.float "fallback_time_ms"
    t.boolean "match_found"
    t.bigint "matched_user_id"
    t.integer "probe_candidate_count"
    t.float "probe_time_ms"
    t.string "tier1_hash"
    t.float "total_time_ms"
    t.datetime "updated_at", null: false
    t.boolean "used_fallback", default: false
    t.index ["matched_user_id"], name: "index_performance_logs_on_matched_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.vector "face_embedding", limit: 128
    t.string "name"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.string "tier1_hash", limit: 16
    t.text "tier2_user_key"
    t.text "tier2_vector"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["tier1_hash"], name: "index_users_on_tier1_hash"
  end

  add_foreign_key "attendances", "users"
  add_foreign_key "performance_logs", "users", column: "matched_user_id"
end
