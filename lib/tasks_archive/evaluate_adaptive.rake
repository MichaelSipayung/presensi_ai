require "json"
require "base64"
require "set"

namespace :performance do
  desc "Evaluasi perbandingan langsung Full Scan vs Adaptive Fuzzy Engine pada Dataset Yale B"
  task evaluate_adaptive: :environment do
    yale_root = ENV.fetch("YALE_ROOT", File.expand_path("~/Downloads/extended_yale_b/cropped"))
    unless Dir.exist?(yale_root)
      puts "[ERROR] Direktori Yale B tidak ditemukan: #{yale_root}"
      exit
    end

    puts "[INFO] Memuat galeri wajah (pose frontal P00A+000E+00)..."
    gallery_map = {}
    
    Dir.glob(File.join(yale_root, "yaleB*")).sort.each do |dir|
      name = File.basename(dir)
      frontal_path = Dir.glob(File.join(dir, "*_P00A+000E+00.pgm")).first
      next unless frontal_path && File.exist?(frontal_path)

      res = FaceRecognitionService.extract_face(Base64.strict_encode64(File.binread(frontal_path)))
      next unless res[:success]
      v = VectorRotationCipher.l2_normalize(FaceRecognitionService.hex_to_float_array(res[:embedding]))
      gv = VectorRotationCipher.apply_global_rotation(v)
      gallery_map[name] = { embedding: v, global_vector: gv }
    end

    puts "[INFO] Total galeri terdaftar: #{gallery_map.size}"
    
    gallery_names = gallery_map.keys.sort
    n = gallery_names.size
    g_embeddings = gallery_names.map { |name| gallery_map[name][:embedding] }
    g_gv = gallery_names.map { |name| gallery_map[name][:global_vector] }
    
    to_int = ->(proj) { proj.map { |x| x >= 0 ? "1" : "0" }.join.to_i(2) }
    popcount = Array.new(65_536) { |i| i.to_s(2).count("1") }
    
    g_hashes = g_gv.map do |gv|
      proj = gv.first(VectorRotationCipher::HASH_BITS)
      to_int.(proj)
    end

    dot = lambda do |a, b|
      s = 0.0; i = 0
      while i < 128; s += a[i] * b[i]; i += 1; end
      s
    end

    total_samples = 0
    full_correct = 0
    adaptive_correct = 0
    discrepancies = 0

    Dir.glob(File.join(yale_root, "yaleB*")).sort.each do |dir|
      subject_name = File.basename(dir)
      target_idx = gallery_names.index(subject_name)
      next unless target_idx

      query_files = Dir.glob(File.join(dir, "*.pgm")).reject { |f| f.include?("P00A+000E+00") }.sort
      next if query_files.empty?

      puts "\n[TEST] Subjek: #{subject_name}"

      # Batasi beberapa sampel per subjek agar pengujian efisien dan terfokus
      query_files.first(8).each do |q_path|
        q_name = File.basename(q_path)
        
        res = FaceRecognitionService.extract_face(Base64.strict_encode64(File.binread(q_path)))
        next unless res[:success]

        q_emb = VectorRotationCipher.l2_normalize(FaceRecognitionService.hex_to_float_array(res[:embedding]))
        q_gv = VectorRotationCipher.apply_global_rotation(q_emb)
        q_proj = q_gv.first(VectorRotationCipher::HASH_BITS)
        q_qh = to_int.(q_proj)

        # Analisis kualitas gambar (brightness & sharpness) secara real-time
        quality = ImageQualityAnalyzer.analyze_file(q_path)
        next unless quality

        # Inferensi Fuzzy untuk mendapatkan K-Limit dan Threshold Adaptif
        fuzzy = FuzzyThresholdEngine.calculate(quality[:brightness], quality[:sharpness])
        k_dyn = fuzzy[:k_limit]
        t_dyn = fuzzy[:threshold]

        # 1. Full Scan Simulation
        sims = Array.new(n) { |j| dot.(q_emb, g_embeddings[j]) }
        genuine_sim = sims[target_idx]
        impostor_max = -2.0
        sims.each_with_index { |s, j| impostor_max = s if j != target_idx && s > impostor_max }
        
        full_success = (genuine_sim >= t_dyn) && (genuine_sim > impostor_max)

        # 2. Adaptive Fuzzy Search Simulation (dengan K dinamis hasil inferensi)
        d = Array.new(n) { |j| popcount[q_qh ^ g_hashes[j]] }
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

        adaptive_success = (adaptive_best_idx == target_idx) && (adaptive_best_sim >= t_dyn)

        total_samples += 1
        full_correct += 1 if full_success
        adaptive_correct += 1 if adaptive_success

        status_str = if full_success == adaptive_success
          "OK (Seimbang)"
        else
          discrepancies += 1
          "!! BEDA HASIL !!"
        end

        puts "   #{q_name} [B:#{quality[:brightness]}, S:#{quality[:sharpness]} | K:#{k_dyn}, T:#{t_dyn.round(3)}]: full=#{full_success}(#{genuine_sim.round(3)}) adaptive=#{adaptive_success}(#{adaptive_best_sim.round(3)}) #{status_str}"
      end
    end

    puts "\n=================================================="
    puts "=== RINGKASAN VALIDASI METODE ADAPTIF FUZZY ==="
    puts "Total Sampel Diuji            : #{total_samples}"
    puts "Full Scan Benar               : #{full_correct} (#{(full_correct.to_f / total_samples * 100).round(2)}%)"
    puts "Adaptive Fuzzy Engine Benar   : #{adaptive_correct} (#{(adaptive_correct.to_f / total_samples * 100).round(2)}%)"
    puts "Discrepancy (Selisih Hasil)   : #{discrepancies}"
    puts "=================================================="
  end
end