require 'base64'

namespace :performance do
  desc "Seed user dummy secara REALISTIS melewati C++ dan Cek Duplikasi. Usage: rails performance:seed_realistic[/path/to/faces]"
  task :seed_realistic, [:dataset_path] => :environment do |_t, args|
    dataset_path = args[:dataset_path] or raise "Usage: rails performance:seed_realistic[/path/to/faces_folder]"
    
    puts "[INFO] Memulai proses registrasi realistis dari: #{dataset_path}"
    
    # Kumpulkan semua file gambar (jpg, png, pgm)
    files = Dir.glob("#{dataset_path}/**/*.{jpg,png,pgm}")
    puts "[INFO] Ditemukan #{files.size} file gambar."

    # Percepatan database sementara (tanpa merusak keamanan log)
    old_stretches = Devise.stretches
    Devise.stretches = 1
    old_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = nil
    
    start_time = Time.now
    success_count = 0
    rejected_no_face = 0
    rejected_duplicate = 0

    begin
      files.each_with_index do |file, index|
        # 1. Konversi ke Base64 (Sama persis seperti dari UI Webcam)
        base64_str = Base64.strict_encode64(File.binread(file))
        ext = File.extname(file).delete('.').downcase
        mime_type = (ext == 'pgm') ? 'jpeg' : ext # fallback mime
        base64_image = "data:image/#{mime_type};base64,#{base64_str}"

        # 2. Panggil Service C++ (Gerbang Pertama)
        result = FaceRecognitionService.extract_face(base64_image)
        unless result[:success]
          rejected_no_face += 1
          next # Skip, sama seperti Controller menolak wajah tidak jelas
        end

        camera_vector = FaceRecognitionService.hex_to_float_array(result[:embedding])
        camera_vector = VectorRotationCipher.l2_normalize(camera_vector)
        
        global_vector = VectorRotationCipher.apply_global_rotation(camera_vector)
        hash, probe_hashes = VectorRotationCipher.tier1_hash_and_probes(global_vector)

        # 3. Cek Duplikasi (Gerbang Kedua, sama seperti Controller)
        duplicate_user, duplicate_sim = VectorRotationCipher.search_with_logging(
          event_type: "realistic_seed_dedup",
          global_vector: global_vector,
          hash: hash,
          probe_hashes: probe_hashes,
          threshold_distance: 0.35
        )

        if duplicate_user.present? && (1.0 - duplicate_sim) <= 0.35
          rejected_duplicate += 1
          next # Skip, karena wajah ini (atau yang sangat mirip) sudah ada!
        end

        # 4. Lolos semua validasi, Daftarkan ke Database!
        user_key = VectorRotationCipher.generate_user_key
        tier2_vector = VectorRotationCipher.tier2_transform(global_vector, user_key)

        User.create!(
          name: "RealDummy_#{SecureRandom.hex(4)}",
          email: "real_#{SecureRandom.hex(6)}@test.local",
          password: "password_123",
          tier1_hash: hash,
          tier2_vector: tier2_vector.to_json,
          tier2_user_key: user_key.to_json
        )
        success_count += 1

        # Cetak progress setiap 100 sukses
        if (success_count % 100).zero? && success_count.positive?
          puts "  [Progress] #{success_count} user berhasil diregistrasi..."
        end
      end
    ensure
      Devise.stretches = old_stretches
      ActiveRecord::Base.logger = old_logger
    end

    total_time = Time.now - start_time
    puts "\n=== LAPORAN REGISTRASI REALISTIS ==="
    puts "Waktu eksekusi     : #{total_time.round(1)} detik"
    puts "Berhasil Daftar    : #{success_count} user"
    puts "Ditolak (No Face)  : #{rejected_no_face} gambar"
    puts "Ditolak (Duplikat) : #{rejected_duplicate} gambar"
    puts "Total User di DB   : #{User.count}"
  end
end