require "json"
require "set"

namespace :performance do
  desc "Evaluasi Adaptif vs Full Scan (Galeri Besar n>5000 & Kasus Ekstrem >= 60 Derajat)"
  task evaluate_real_adaptive: :environment do
    puts "[INFO] Memuat galeri skala besar dari cache..."
    rows = File.foreach(CalibrationHelper.cache_path).map { |l| JSON.parse(l) }
    
    key = ->(r) { "#{r['dataset']}:#{r['identity']}" }
    
    # 1. Bangun Galeri Raksasa (n = ~5700+)
    gallery = rows.select { |r| r["role"] == "gallery" }
    gidx = {}
    gallery.each_with_index { |g, j| gidx[key.(g)] = j }
    n = gallery.size
    
    puts "[INFO] Total galeri terdaftar (n) : #{n}"

    dot = lambda do |a, b|
      s = 0.0; i = 0
      while i < 128; s += a[i] * b[i]; i += 1; end
      s
    end
    
    to_int = ->(proj) { proj.map { |x| x >= 0 ? "1" : "0" }.join.to_i(2) }
    popcount = Array.new(65_536) { |i| i.to_s(2).count("1") }
    
    g_emb  = gallery.map { |g| g["embedding"] }
    g_hash = gallery.map { |g| to_int.(g["proj16"]) }

    # 2. Filter Kueri: HANYA Yale B dengan sudut pencahayaan ekstrem (>= 60 derajat)
    extreme_queries = rows.select do |r|
      r["role"] == "query" && 
      r["dataset"] == "yale" && 
      gidx.key?(key.(r)) && 
      r["light_angle"].to_f >= 60.0
    end

    puts "[INFO] Total Kueri Ekstrem (>= 60 derajat): #{extreme_queries.size}"

    full_correct = 0
    adaptive_correct = 0
    discrepancies = 0

    extreme_queries.each do |q|
      qe = q["embedding"]
      t  = gidx[key.(q)]
      
      # Hitung simulasi skor
      sims = Array.new(n) { |j| dot.(qe, g_emb[j]) }
      genuine_sim = sims[t]
      impostor_max = -2.0
      sims.each_with_index { |s, j| impostor_max = s if j != t && s > impostor_max }

      # Dapatkan K dan Threshold dari mesin Fuzzy yang domainnya sudah diperbaiki
      fuzzy = FuzzyThresholdEngine.calculate(q["brightness"], q["sharpness"])
      k_dyn = fuzzy[:k_limit]
      t_dyn = fuzzy[:threshold]

      # Cek Baseline Full Scan (batas threshold murni, tanpa batas K)
      full_success = (genuine_sim >= t_dyn) && (genuine_sim > impostor_max)

      # Cek Adaptive Fuzzy Engine (cari dalam top-K Hamming neighborhood)
      qh = to_int.(q["proj16"])
      d  = Array.new(n) { |j| popcount[qh ^ g_hash[j]] }
      
      order = (0...n).sort_by { |j| [ d[j], j ] }
      kk = [ k_dyn, n ].min
      top_indices = order.first(kk)
      
      adaptive_best_sim = -2.0
      adaptive_best_idx = -1
      top_indices.each do |j|
        if sims[j] > adaptive_best_sim
          adaptive_best_sim = sims[j]
          adaptive_best_idx = j
        end
      end

      adaptive_success = (adaptive_best_idx == t) && (adaptive_best_sim >= t_dyn)

      full_correct += 1 if full_success
      adaptive_correct += 1 if adaptive_success

      unless full_success == adaptive_success
        discrepancies += 1
        puts " !! BEDA: #{q['identity']} (Sudut: #{q['light_angle']}) | B:#{q['brightness'].round(1)} | Fuzzy(K:#{k_dyn}, T:#{t_dyn.round(3)}) | Full:#{full_success} Adaptif:#{adaptive_success}"
      end
    end

    total_samples = extreme_queries.size.to_f
    puts "\n=================================================="
    puts "=== VALIDASI ADAPTIF VS FULL SCAN (SKALA NYATA) ==="
    puts "Total Galeri (n)              : #{n}"
    puts "Total Sampel Ekstrem (>=60°)  : #{extreme_queries.size}"
    puts "Full Scan Benar               : #{full_correct} (#{(full_correct / total_samples * 100).round(2)}%)"
    puts "Adaptive Fuzzy Engine Benar   : #{adaptive_correct} (#{(adaptive_correct / total_samples * 100).round(2)}%)"
    puts "Discrepancy (Gagal Adaptif)   : #{discrepancies}"
    puts "=================================================="
  end
end