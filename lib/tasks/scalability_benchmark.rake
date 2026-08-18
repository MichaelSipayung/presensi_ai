namespace :biometric do
  desc "Benchmark Skalabilitas Pencarian Vektor Berdasarkan Jumlah Data di Database"
  task benchmark_scalability: :environment do
    puts "\n=========================================================="
    puts " BENCHMARK: SKALABILITAS PENCARIAN (PGVECTOR INDEXING)    "
    puts "=========================================================="

    # Ambil satu sampel vektor terenkripsi yang valid dari database untuk dijadikan query uji
    sample_user = User.where.not(face_embedding: nil).first
    unless sample_user
      puts "[ERROR] Tidak ada data user di database untuk diuji!"
      exit
    end

    test_vector = sample_user.face_embedding
    sample_sizes = [1000, 10000, 50000, 100000, 250000] 
    iterations = 50 

    results = []

    sample_sizes.each do |size|
      actual_count = User.count
      if size > actual_count
        puts "[INFO] Melewati ukuran #{size} (Data di DB saat ini: #{actual_count})"
        next
      end

      puts "[INFO] Menguji kecepatan pencarian dengan skala data N = #{size}..."

      # Warm-up / eksekusi awal menggunakan Time.now
      User.limit(size).nearest_neighbors(:face_embedding, test_vector, distance: "cosine").first

      # Pengukuran waktu rata-rata
      total_time = 0
      iterations.times do
        time_start = Time.now
        User.limit(size).nearest_neighbors(:face_embedding, test_vector, distance: "cosine").first
        total_time += (Time.now - time_start)
      end

      avg_ms = (total_time / iterations) * 1000.0
      results << { size: size, time_ms: avg_ms }
      puts " -> Skala N = #{size} | Waktu Rata-rata: #{avg_ms.round(4)} ms"
    end

    puts "\n[HASIL ARRAY UNTUK PYTHON]:"
    puts results.inspect
    puts "=========================================================="
  end
end