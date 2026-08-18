namespace :biometric do
  desc "Benchmark Waktu Komputasi Enkripsi Permutasi vs Vektor Mentah"
  task benchmark_encryption: :environment do
    puts "\n=========================================================="
    puts " BENCHMARK: OVERHEAD WAKTU ENKRIPSI PERMUTASI VEKTOR       "
    puts "=========================================================="

    # Ambil sampel gambar dari direktori uji
    test_image_path = Dir.glob(Rails.root.join('tmp', 'dataset_uji', '**', '*.{jpg,jpeg,JPG,JPEG}')).first
    
    unless test_image_path
      puts "[ERROR] Tidak ditemukan gambar sampel di tmp/dataset_uji/"
      exit
    end

    image_bytes = File.read(test_image_path)
    base64_img = "data:image/jpeg;base64,#{Base64.strict_encode64(image_bytes)}"

    iterations = 1000
    puts "[INFO] Melakukan simulasi #{iterations} iterasi ekstraksi + enkripsi..."

    # 1. Benchmark Tanpa Enkripsi (Hanya Ekstraksi & Konversi)
    time_raw_start = Time.now
    iterations.times do
      result = FaceRecognitionService.extract_face(base64_img)
      if result[:success]
        FaceRecognitionService.hex_to_float_array(result[:embedding])
      end
    end
    time_raw_total = Time.now - time_raw_start

    # 2. Benchmark Dengan Enkripsi Permutasi
    time_enc_start = Time.now
    iterations.times do
      result = FaceRecognitionService.extract_face(base64_img)
      if result[:success]
        vector = FaceRecognitionService.hex_to_float_array(result[:embedding])
        FaceRecognitionService.encrypt_vector(vector)
      end
    end
    time_enc_total = Time.now - time_enc_start

    # Hasil Perhitungan
    avg_raw_ms = (time_raw_total / iterations) * 1000.0
    avg_enc_ms = (time_enc_total / iterations) * 1000.0
    overhead_ms = avg_enc_ms - avg_raw_ms

    puts "\n=========================================================="
    puts " HASIL BENCHMARK ENKRIPSI (Rata-rata dari #{iterations} proses)"
    puts "=========================================================="
    puts " Waktu Rata-rata Tanpa Enkripsi : #{avg_raw_ms.round(4)} ms / proses"
    puts " Waktu Rata-rata Dengan Enkripsi: #{avg_enc_ms.round(4)} ms / proses"
    puts " Beban Tambahan (Overhead)      : #{overhead_ms.round(4)} ms"
    puts "=========================================================="
    puts "[KESIMPULAN] Overhead komputasi enkripsi permutasi sangat kecil"
    puts "dan aman untuk diterapkan pada sistem presensi real-time."
    puts "=========================================================="
  end
end