namespace :performance do
  desc "Seed N user dummy (CEPAT -- bcrypt cost diturunkan sementara). Usage: rails performance:seed_dummy[1000]"
  task :seed_dummy, [:count] => :environment do |_t, args|
    count = (args[:count] || 1000).to_i
    puts "[INFO] Membuat #{count} user dummy (mode cepat)..."

    # ---- Percepatan 1: turunkan cost bcrypt drastis (dummy data, tidak perlu keamanan penuh) ----
    old_stretches = Devise.stretches
    Devise.stretches = 1

    # ---- Percepatan 2: matikan logger SQL sementara (ribuan baris log bikin lambat) ----
    old_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = nil

    start_time = Time.now

    begin
      count.times do |i|
        camera_vector = Array.new(VectorRotationCipher::DIM) { rand(-2.0..2.0) }
        global_vector  = VectorRotationCipher.apply_global_rotation(camera_vector)
        hash, _probes  = VectorRotationCipher.tier1_hash_and_probes(global_vector)
        user_key       = VectorRotationCipher.generate_user_key
        tier2_vector   = VectorRotationCipher.tier2_transform(global_vector, user_key)

        User.create!(
          name: "dummy_user_#{i}_#{SecureRandom.hex(4)}",
          email: "dummy_#{i}_#{SecureRandom.hex(6)}@test.local",
          password: "dummy_password_123",  # sama utk semua, tidak masalah (dummy, tidak pernah dipakai login)
          tier1_hash: hash,
          tier2_vector: tier2_vector.to_json,
          tier2_user_key: user_key.to_json
        )

        if (i % 500).zero? && i.positive?
          elapsed = Time.now - start_time
          rate = i / elapsed
          eta = (count - i) / rate
          puts "  [#{i}/#{count}] #{elapsed.round(1)}s berlalu, ~#{rate.round(1)} user/detik, ETA #{eta.round(0)}s lagi"
        end
      end
    ensure
      # ---- WAJIB dikembalikan, supaya user ASLI (bukan dummy) tetap pakai bcrypt penuh ----
      Devise.stretches = old_stretches
      ActiveRecord::Base.logger = old_logger
    end

    total_time = Time.now - start_time
    puts "\n[SUKSES] #{count} user dummy dibuat dalam #{total_time.round(1)} detik (#{(count/total_time).round(1)} user/detik)."
    puts "Total user sekarang: #{User.count}"
  end

  desc "Hapus semua user dummy (nama diawali 'dummy_user_')"
  task clear_dummy: :environment do
    deleted = User.where("name LIKE 'dummy_user_%'").delete_all
    puts "[SUKSES] #{deleted} user dummy dihapus. Total user sekarang: #{User.count}"
  end

  desc "Benchmark probe vs fallback pada skala N saat ini, pakai vektor query ACAK"
  task :benchmark_at_current_scale, [:trials] => :environment do |_t, args|
    trials = (args[:trials] || 20).to_i
    n = User.count
    puts "[INFO] N saat ini = #{n} user. Menjalankan #{trials} percobaan query acak..."

    trials.times do
      camera_vector = Array.new(VectorRotationCipher::DIM) { rand(-2.0..2.0) }
      global_vector = VectorRotationCipher.apply_global_rotation(camera_vector)
      hash, probe_hashes = VectorRotationCipher.tier1_hash_and_probes(global_vector)

      VectorRotationCipher.search_with_logging(
        event_type: "benchmark_n#{n}",
        global_vector: global_vector,
        hash: hash,
        probe_hashes: probe_hashes,
        threshold_distance: 0.35
      )
    end

    logs = PerformanceLog.where(event_type: "benchmark_n#{n}")
    puts "\n=== HASIL BENCHMARK N=#{n} ==="
    puts "Rata-rata waktu probe    : #{logs.average(:probe_time_ms)&.round(4)} ms"
    puts "Rata-rata waktu fallback : #{logs.where(used_fallback: true).average(:fallback_time_ms)&.round(4) || 'N/A'} ms"
    puts "Fallback rate            : #{(logs.where(used_fallback: true).count.to_f / trials * 100).round(2)}%"
  end
end