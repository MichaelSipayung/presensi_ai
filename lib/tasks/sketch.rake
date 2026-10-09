# lib/tasks/sketch.rake
namespace :sketch do
  desc "Isi sketch user lama (membalik Tier 2 dengan kunci per-user)"
  task backfill: :environment do
    n = 0
    User.where(sketch: nil).where.not(tier2_vector: nil).find_each do |u|
      key = JSON.parse(u.tier2_user_key)
      w   = JSON.parse(u.tier2_vector)
      g   = Array.new(VectorRotationCipher::DIM)
      key["permutation"].each_with_index { |src, i| g[src] = key["signs"][i] * w[i] }
      u.sketch = VectorRotationCipher.sketch(g)
      u.save!(validate: false)
      n += 1
    end
    puts "#{n} user diisi sketch"
  end
end

namespace :calibration do
  desc "Isi tabel users dari galeri cache (tanpa ekstraksi ulang, tanpa dedup) untuk uji latensi"
  task seed_from_cache: :environment do
    gal = File.foreach(CalibrationHelper.cache_path).map { |l| JSON.parse(l) }.select { |r| r["role"] == "gallery" }
    puts "[INFO] membuat #{gal.size} user dari galeri cache"
    old_stretches = Devise.stretches
    old_logger    = ActiveRecord::Base.logger
    Devise.stretches = 1
    ActiveRecord::Base.logger = nil
    begin
      gal.each_with_index do |r, i|
        gv      = VectorRotationCipher.apply_global_rotation(r["embedding"])
        hash, _ = VectorRotationCipher.tier1_hash_and_probes(gv)
        key     = VectorRotationCipher.generate_user_key
        User.create!(
          name: "cal_#{r['identity']}"[0, 60], email: "cal_#{i}_#{SecureRandom.hex(4)}@test.local",
          password: "dummy_password_123", tier1_hash: hash,
          sketch: VectorRotationCipher.sketch(gv),
          tier2_vector: VectorRotationCipher.tier2_transform(gv, key).to_json,
          tier2_user_key: key.to_json
        )
        puts "  #{i + 1}/#{gal.size}" if ((i + 1) % 1000).zero?
      end
    ensure
      Devise.stretches = old_stretches
      ActiveRecord::Base.logger = old_logger
    end
    puts "[SELESAI] total user: #{User.count}"
  end
end

namespace :performance do
  desc "Latensi jalur presensi sketch vs full scan pada galeri saat ini. ENV: TRIALS(300) K"
  task sketch_benchmark: :environment do
    trials = (ENV["TRIALS"] || 300).to_i
    k      = (ENV["K"] || FaceMatching::K).to_i
    qs = File.foreach(CalibrationHelper.cache_path).map { |l| JSON.parse(l) }
             .select { |r| r["role"] == "query" }.sample(trials, random: Random.new(7))
    puts "[INFO] N=#{User.count} K=#{k} trials=#{qs.size}"
    qs.each do |q|
      gv = VectorRotationCipher.apply_global_rotation(q["embedding"])
      VectorRotationCipher.search_sketch(event_type: "bench_sketch_k#{k}", global_vector: gv, k: k, tau: FaceMatching::TAU)
    end
    logs = PerformanceLog.where(event_type: "bench_sketch_k#{k}").order(:id).last(qs.size)
    pct  = ->(a, p) { s = a.sort; s[((s.size - 1) * p).round] }
    { "probe_time_ms" => "SQL Hamming Top-K", "fallback_time_ms" => "verifikasi Tier 2", "total_time_ms" => "total" }.each do |c, label|
      v = logs.map { |l| l[c] }
      puts format("%-20s p50=%.1f  p95=%.1f  mean=%.1f ms", label, pct.(v, 0.5), pct.(v, 0.95), v.sum / v.size)
    end
    full = qs.first(20).map do |q|
      gv = VectorRotationCipher.apply_global_rotation(q["embedding"])
      t  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      VectorRotationCipher.find_best_match(User.all, gv)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
    end
    puts format("%-20s p50=%.1f  mean=%.1f ms (n=%d)", "full scan", pct.(full, 0.5), full.sum / full.size, full.size)
  end
end