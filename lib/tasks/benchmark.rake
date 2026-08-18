namespace :biometric do
  desc "Benchmark Bertahap Spesifik (10k s.d 250k) dengan Sistem Averaging"
  task :step_benchmark_custom => :environment do
    # Daftar titik pengujian (milestone) yang Anda inginkan
    milestones = [10_000, 20_000, 30_000, 40_000, 50_000, 60_000, 70_000, 80_000, 90_000, 100_000, 150_000, 200_000, 250_000]

    puts "\n=========================================================="
    puts " MEMULAI BENCHMARK CUSTOM (10k - 250k) + AVERAGING       "
    puts "=========================================================="

    test_image_path = Rails.root.join('tmp', 'dataset_uji', 'jono.jpg')
    unless File.exist?(test_image_path)
      test_image_path = Dir.glob(Rails.root.join('tmp', 'dataset_uji', '*.{jpg,jpeg}')).first
    end

    image_bytes = File.read(test_image_path)
    base64_img = "data:image/jpeg;base64,#{Base64.strict_encode64(image_bytes)}"
    result = FaceRecognitionService.extract_face(base64_img)
    camera_vector = FaceRecognitionService.hex_to_float_array(result[:embedding])

    report_results = []

    milestones.each do |target|
      current_count = User.count
      needed = target - current_count

      if needed > 0
        puts "\n--- MENAMBAHKAN DATA: Mencapai target N = #{target} (Kurang #{needed} data) ---"
        batch_size = 2000
        batches = [needed / batch_size, 1].max

        batches.times do
          users_batch = []
          actual_batch_size = needed / batches
          actual_batch_size.times do |j|
            random_vector = Array.new(128) { rand(-1.0..1.0) }
            idx = User.count + j
            users_batch << {
              name: "Custom Dummy #{idx}",
              email: "cust_#{idx}_#{SecureRandom.hex(4)}@mail.com",
              encrypted_password: "password123",
              face_embedding: "[#{random_vector.join(',')}]",
              created_at: Time.current,
              updated_at: Time.current
            }
          end
          User.insert_all(users_batch)
          print "."
        end
        puts "\n[INFO] Database sekarang tepat berisi: #{User.count} records."
      elsif needed < 0
        puts "[INFO] Database memiliki lebih dari #{target} data. Melewati penambahan."
      end

      # ---------------------------------------------------------
      # JALANKAN BENCHMARK DENGAN PENGULANGAN (3 KALI TRIAL)
      # ---------------------------------------------------------
      puts "Menjalankan benchmark pada N = #{target} (Rata-rata dari 3 percobaan)..."
      
      ruby_times = []
      pg_times = []

      3.times do
        # 1. Non-Pgvector Trial
        start_ruby = Time.now
        highest_sim = 0.0
        User.find_each do |user|
          next if user.face_embedding.blank?
          sim = FaceRecognitionService.cosine_similarity(camera_vector, user.face_embedding)
          highest_sim = sim if sim > highest_sim
        end
        ruby_times << (Time.now - start_ruby)

        # 2. Pgvector Trial
        start_pg = Time.now
        User.nearest_neighbors(:face_embedding, camera_vector, distance: "cosine").first
        pg_times << (Time.now - start_pg)
      end

      # Hitung rata-rata
      avg_ruby = (ruby_times.sum / ruby_times.size).round(4)
      avg_pg = (pg_times.sum / pg_times.size).round(4)

      report_results << { count: target, ruby: avg_ruby, pg: avg_pg }
      puts "Hasil Rata-rata -> Non-Pgvector: #{avg_ruby}s | Pgvector: #{avg_pg}s"
    end

    # ---------------------------------------------------------
    # CETAK FORMAT SIAP-PAKAI PYTHON MATPLOTLIB
    # ---------------------------------------------------------
    puts "\n\n" + "="*70
    puts " COPY KODE DI BAWAH INI LANGSUNG KE DALAM SKRIP PYTHON ANDA:"
    puts "="*70
    
    counts_str = report_results.map { |r| r[:count] }.join(', ')
    ruby_str   = report_results.map { |r| r[:ruby] }.join(', ')
    pg_str     = report_results.map { |r| r[:pg] }.join(', ')

    puts "data_sizes        = [#{counts_str}]"
    puts "time_non_pgvector = [#{ruby_str}]"
    puts "time_pgvector     = [#{pg_str}]"
    puts "="*70 + "\n\n"
  end

  desc "Pengujian FAR Sebenarnya (Real Faces vs Real Faces)"
  task true_far: :environment do
    puts "\n=========================================================="
    puts " MEMULAI PENGUJIAN TRUE FAR (Real Wajah vs Real Wajah)    "
    puts "=========================================================="

    # 1. Kelompokkan dataset LFW berdasarkan nama (Identitas)
    # File LFW bernama seperti: Aaron_Eckhart_0001.jpg
    files = Dir.glob(Rails.root.join('tmp', 'dataset_uji', '**', '*.{jpg,jpeg,JPG,JPEG}'))
    identities = {}
    
    files.each do |file|
      filename = File.basename(file)
      # Ambil nama dengan menghapus angka di belakang, misal: Aaron_Eckhart
      name = filename.sub(/_\d+\.jpe?g/i, '')
      identities[name] ||= []
      identities[name] << file
    end

    if identities.keys.size < 1000
      puts "[PERINGATAN] Dataset Anda kurang dari 1000 orang. Sistem akan menggunakan data semaksimal mungkin."
    end

    all_names = identities.keys.shuffle
    
    # Kita bagi dua kelompok yang BENAR-BENAR BERBEDA
    # Kelompok A (Terdaftar): 500 orang
    # Kelompok B (Penyusup) : 500 orang lainnya
    target_size = [all_names.size / 2, 500].min
    
    registered_names = all_names[0...target_size]
    intruder_names = all_names[target_size...(target_size * 2)]

    puts "[INFO] Mengekstrak #{target_size} Wajah Terdaftar (Kelompok A)..."
    registered_vectors = []
    registered_names.each do |name|
      file_path = identities[name].first
      image_bytes = File.read(file_path)
      base64_img = "data:image/jpeg;base64,#{Base64.strict_encode64(image_bytes)}"
      result = FaceRecognitionService.extract_face(base64_img)
      if result[:success]
        registered_vectors << FaceRecognitionService.hex_to_float_array(result[:embedding])
      end
      print "."
    end

    puts "\n[INFO] Mengekstrak #{target_size} Wajah Penyusup (Kelompok B)..."
    intruder_vectors = []
    intruder_names.each do |name|
      file_path = identities[name].first
      image_bytes = File.read(file_path)
      base64_img = "data:image/jpeg;base64,#{Base64.strict_encode64(image_bytes)}"
      result = FaceRecognitionService.extract_face(base64_img)
      if result[:success]
        intruder_vectors << FaceRecognitionService.hex_to_float_array(result[:embedding])
      end
      print "."
    end

    # 2. Mengadu Kelompok B ke Kelompok A
    puts "\n\n[INFO] Memulai Simulasi Serangan (Cross-Matching)..."
    
    thresholds = [0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6]
    far_counts = Hash.new(0)
    total_tested = intruder_vectors.size

    intruder_vectors.each do |intruder_vec|
      # Cari jarak terdekat (paling mirip) dengan salah satu orang di Kelompok A
      closest_distance = 1.0 # Default paling jauh
      
      registered_vectors.each do |reg_vec|
        # Ingat: cosine_similarity = 1 - distance. Jadi distance = 1 - similarity
        sim = FaceRecognitionService.cosine_similarity(intruder_vec, reg_vec)
        dist = 1.0 - sim
        closest_distance = dist if dist < closest_distance
      end

      # Cek jebol di threshold mana saja
      thresholds.each do |t|
        far_counts[t] += 1 if closest_distance <= t
      end
    end

    # 3. Hasil
    far_values = thresholds.map { |t| ((far_counts[t].to_f / total_tested) * 100).round(2) }

    puts "\n\n" + "="*70
    puts " COPY KODE DI BAWAH INI LANGSUNG KE DALAM SKRIP PYTHON ANDA:"
    puts "="*70
    puts "thresholds = #{thresholds}"
    puts "far_values = #{far_values}"
    puts "="*70 + "\n\n"
  end

  desc "Evaluasi EER (FRR vs FAR) Skala Penuh di antara Ratusan Ribu Data Dummy"
  task e2e_roc_eval: :environment do
    puts "\n=========================================================="
    puts " MEMULAI EVALUASI E.E.R (NEEDLE IN A HAYSTACK) VIA DATABASE "
    puts "=========================================================="
    puts "[INFO] Mempertahankan #{User.count} data dummy yang sudah ada di database."

    # 1. Pemilahan Dataset LFW
    files = Dir.glob(Rails.root.join('tmp', 'dataset_uji', '**', '*.{jpg,jpeg,JPG,JPEG}'))
    identities = {}
    
    files.each do |file|
      name = File.basename(file).sub(/_\d+\.jpe?g/i, '')
      identities[name] ||= []
      identities[name] << file
    end

    # Karyawan (Punya >= 2 foto: 1 untuk didaftarkan, sisanya untuk uji gaya/pose)
    employees = identities.select { |_, photos| photos.size >= 2 }
    
    # Penyusup (Hanya punya 1 foto: Tidak didaftarkan, murni untuk uji kebobolan)
    intruders = identities.select { |_, photos| photos.size == 1 }.keys.shuffle.first(500) # Ambil 500 penyusup

    puts "[INFO] Skenario Pengujian (Ditanam di dalam #{User.count} data):"
    puts " - Karyawan Terdaftar Baru : #{employees.size} orang"
    puts " - Wajah Uji Pose (FRR)    : #{employees.values.map{|p| p.size - 1}.sum} tes absen"
    puts " - Wajah Uji Penyusup (FAR): #{intruders.size} tes penyusupan"
    puts "----------------------------------------------------------"

    # 2. PENDAFTARAN KE DATABASE (ENROLLMENT)
    puts "\n[PHASE 1] Menanamkan Wajah Karyawan Asli ke dalam Tumpukan Database..."
    valid_employees = 0
    enrolled_emails = [] # Menyimpan email karyawan yang berhasil didaftarkan untuk verifikasi nanti

    employees.each do |name, photos|
      file_path = photos.first
      image_bytes = File.read(file_path)
      base64_img = "data:image/jpeg;base64,#{Base64.strict_encode64(image_bytes)}"
      result = FaceRecognitionService.extract_face(base64_img)
      
      if result[:success]
        email = "real_#{name.downcase.gsub(/[^a-z0-9]/, '')}_#{SecureRandom.hex(2)}@mail.com"
        User.create!(
          name: name,
          email: email,
          password: 'password123',
          face_embedding: FaceRecognitionService.hex_to_float_array(result[:embedding])
        )
        enrolled_emails << email
        valid_employees += 1
      end
      print "."
    end
    puts "\n[SUKSES] #{valid_employees} Karyawan asli berhasil ditanamkan!"
    puts "[INFO] Total data di database saat ini: #{User.count}"

    # Inisialisasi Threshold & Variabel Hasil
    thresholds = [0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6]
    far_counts = Hash.new(0)
    frr_counts = Hash.new(0)
    total_far_tests = 0
    total_frr_tests = 0

    # 3. UJI FRR (Apakah pose beda / cahaya beda bikin Karyawan ditolak?)
    puts "\n[PHASE 2] Uji FRR: Mencari #{valid_employees} Karyawan Asli (Beda Pose) di antara ratusan ribu data..."
    employees.each do |name, photos|
      # Lewati foto pertama (karena sudah jadi foto profil)
      photos[1..-1].each do |test_photo|
        image_bytes = File.read(test_photo)
        base64_img = "data:image/jpeg;base64,#{Base64.strict_encode64(image_bytes)}"
        result = FaceRecognitionService.extract_face(base64_img)
        next unless result[:success]

        total_frr_tests += 1
        test_vector = FaceRecognitionService.hex_to_float_array(result[:embedding])

        # CARI DI DATABASE
        best_match = User.nearest_neighbors(:face_embedding, test_vector, distance: "cosine").first
        
        thresholds.each do |t|
          # Karyawan DITOLAK JIKA:
          # 1. Database tidak menemukan siapapun (sangat tidak mungkin di pgvector)
          # 2. Skor jarak (distance) lebih besar dari Threshold
          # 3. Wajah yang ditemukan ternyata BUKAN dia (sistem salah mengenali sebagai orang lain/dummy)
          if best_match.blank? || best_match.neighbor_distance > t || !enrolled_emails.include?(best_match.email)
            frr_counts[t] += 1
          end
        end
        print "R" 
      end
    end

    # 4. UJI FAR (Apakah database kebobolan oleh orang asing?)
    puts "\n\n[PHASE 3] Uji FAR: Mengirim Penyusup Asing ke dalam sistem..."
    intruders.each do |name|
      file_path = identities[name].first
      image_bytes = File.read(file_path)
      base64_img = "data:image/jpeg;base64,#{Base64.strict_encode64(image_bytes)}"
      result = FaceRecognitionService.extract_face(base64_img)
      next unless result[:success]

      total_far_tests += 1
      test_vector = FaceRecognitionService.hex_to_float_array(result[:embedding])

      best_match = User.nearest_neighbors(:face_embedding, test_vector, distance: "cosine").first
      
      thresholds.each do |t|
        # PENYUSUP BERHASIL MASUK JIKA: 
        # Jarak dengan siapapun (baik data dummy atau Karyawan Asli) lebih kecil atau sama dengan Threshold
        if best_match.present? && best_match.neighbor_distance <= t
          far_counts[t] += 1 
        end
      end
      print "A" 
    end

    # 5. BERSIHKAN KARYAWAN ASLI SETELAH SELESAI (Opsional, agar database bersih kembali ke 250k)
    # Jika Anda ingin mempertahankannya, hapus dua baris di bawah ini
    puts "\n\n[PHASE 4] Membersihkan karyawan uji..."
    User.where(email: enrolled_emails).delete_all
    puts "[SUKSES] Karyawan uji dihapus. Total data kembali ke: #{User.count}"

    # Kalkulasi Persentase
    far_values = thresholds.map { |t| ((far_counts[t].to_f / total_far_tests) * 100).round(2) }
    frr_values = thresholds.map { |t| ((frr_counts[t].to_f / total_frr_tests) * 100).round(2) }

    puts "\n\n" + "="*70
    puts " COPY KODE DI BAWAH INI LANGSUNG KE DALAM PYTHON ANDA:"
    puts "="*70
    puts "thresholds = #{thresholds}"
    puts "far_values = #{far_values}"
    puts "frr_values = #{frr_values}"
    puts "="*70 + "\n\n"
  end

  desc "Analisis Dataset Menyeluruh (Ekstraksi, FAR, FRR, dan Deteksi Kualitas Buruk)"
  task advanced_dataset_analysis: :environment do
    puts "\n=========================================================="
    puts " MEMULAI ANALISIS DATASET LFW (KUALITAS & AKURASI E2E)    "
    puts "=========================================================="

    # 1. Bersihkan sisa data karyawan asli dari tes sebelumnya (Dummies tetap aman)
    User.where("email LIKE 'real_%'").delete_all
    puts "[INFO] Membersihkan sisa data tes sebelumnya. Total data saat ini: #{User.count}"

    files = Dir.glob(Rails.root.join('tmp', 'dataset_uji', '**', '*.{jpg,jpeg,JPG,JPEG}'))
    identities = {}
    
    files.each do |file|
      name = File.basename(file).sub(/_\d+\.jpe?g/i, '')
      identities[name] ||= []
      identities[name] << file
    end

    # Variabel Laporan Analisis Kualitatif untuk Paper Anda
    rejected_by_engine = [] # Gambar yang gagal diekstrak C++ (Blur parah / Wajah tidak ada)
    rejected_by_threshold = [] # Karyawan asli yang ditolak database (FRR Failure)
    
    threshold_for_report = 0.35 #  0.35 sebagai acuan laporan kualitatif

    frr_probes = []
    far_probes = []
    valid_employees = 0

    puts "\n[PHASE 1] Memindai #{files.size} Gambar, Ekstraksi Kualitas, dan Pendaftaran..."
    
    identities.each do |name, photos|
      valid_photos_for_this_person = []

      photos.each do |photo_path|
        image_bytes = File.read(photo_path)
        base64_img = "data:image/jpeg;base64,#{Base64.strict_encode64(image_bytes)}"
        result = FaceRecognitionService.extract_face(base64_img)
        
        if result[:success]
          valid_photos_for_this_person << { path: photo_path, vector: FaceRecognitionService.hex_to_float_array(result[:embedding]) }
        else
          # SIMPAN DATA GAMBAR BURUK UNTUK PAPER ANDA
          rejected_by_engine << { file: File.basename(photo_path), reason: result[:error] }
        end
      end

      # Jika orang ini punya >= 2 foto valid, daftarkan foto pertama, sisanya untuk tes FRR
      if valid_photos_for_this_person.size >= 2
        profile_photo = valid_photos_for_this_person.first
        email = "real_#{name.downcase.gsub(/[^a-z0-9]/, '')}_#{SecureRandom.hex(2)}@mail.com"
        
        User.create!(
          name: name,
          email: email,
          password: 'password123',
          face_embedding: profile_photo[:vector]
        )
        valid_employees += 1
        
        # Masukkan sisa fotonya ke daftar tes FRR (Absensi Karyawan Asli)
        valid_photos_for_this_person[1..-1].each do |test_photo|
          frr_probes << { name: name, email: email, path: test_photo[:path], vector: test_photo[:vector] }
        end
      
      # Jika orang ini hanya punya 1 foto valid, jadikan dia Penyusup (Tes FAR)
      elsif valid_photos_for_this_person.size == 1
        far_probes << { name: name, path: valid_photos_for_this_person.first[:path], vector: valid_photos_for_this_person.first[:vector] }
      end
      print "."
    end

    puts "\n\n[HASIL PHASE 1]"
    puts "- Karyawan Berhasil Didaftarkan : #{valid_employees} orang"
    puts "- Gambar Gagal Diekstrak (Blur) : #{rejected_by_engine.size} gambar"
    
    # Inisialisasi Threshold Array untuk Grafik
    thresholds = [0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6]
    far_counts = Hash.new(0)
    frr_counts = Hash.new(0)

    puts "\n[PHASE 2] Menguji FRR (Variasi Pose/Cahaya Karyawan Asli)..."
    frr_probes.each do |probe|
      best_match = User.nearest_neighbors(:face_embedding, probe[:vector], distance: "cosine").first
      
      # Catat untuk laporan kualitatif paper (Jika ditolak di threshold 0.45)
      if best_match.blank? || best_match.neighbor_distance > threshold_for_report || best_match.email != probe[:email]
        rejected_by_threshold << { 
          file: File.basename(probe[:path]), 
          expected: probe[:name], 
          matched: (best_match.present? ? best_match.name : "Tidak ada"),
          distance: (best_match.present? ? best_match.neighbor_distance.round(4) : "N/A")
        }
      end

      # Hitung untuk grafik
      thresholds.each do |t|
        if best_match.blank? || best_match.neighbor_distance > t || best_match.email != probe[:email]
          frr_counts[t] += 1
        end
      end
      print "R"
    end

    puts "\n\n[PHASE 3] Menguji FAR (Mencegah Penyusup Masuk)..."
    far_probes.first(1500).each do |probe| # Batasi 1500 agar seimbang dan cepat
      best_match = User.nearest_neighbors(:face_embedding, probe[:vector], distance: "cosine").first
      
      thresholds.each do |t|
        if best_match.present? && best_match.neighbor_distance <= t
          far_counts[t] += 1 
        end
      end
      print "A"
    end

    # ==========================================================
    # CETAK LAPORAN KUALITATIF UNTUK KEBUTUHAN PAPER
    # ==========================================================
    puts "\n\n" + "="*70
    puts " LAPORAN KUALITATIF UNTUK PAPER JURNAL (CATAT FILE INI!)"
    puts "="*70
    
    puts "\n1. CONTOH GAMBAR DITOLAK MESIN AI (Blur / Tidak Terdeteksi Wajah)"
    puts "Tampilkan gambar-gambar ini di paper sebagai batasan input sistem:"
    rejected_by_engine.first(10).each_with_index do |rej, idx|
      puts "  [#{idx+1}] File: #{rej[:file]} | Error: #{rej[:reason]}"
    end

    puts "\n2. CONTOH KASUS FRR (Wajah Sama, Ditolak Database karena Pose/Sudut)"
    puts "Tampilkan gambar-gambar ini di paper sebagai tantangan ekstraksi 2D:"
    rejected_by_threshold.first(10).each_with_index do |rej, idx|
      puts "  [#{idx+1}] File: #{rej[:file]} | Seharusnya: #{rej[:expected]} | Skor Jarak: #{rej[:distance]}"
    end

    # Kalkulasi Persentase Grafik
    total_far = [far_probes.size, 1500].min
    far_values = thresholds.map { |t| ((far_counts[t].to_f / total_far) * 100).round(2) }
    frr_values = thresholds.map { |t| ((frr_counts[t].to_f / frr_probes.size) * 100).round(2) }

    puts "\n" + "="*70
    puts " DATA GRAFIK PYTHON EER (SAMA SEPERTI SEBELUMNYA):"
    puts "="*70
    puts "thresholds = #{thresholds}"
    puts "far_values = #{far_values}"
    puts "frr_values = #{frr_values}"
    puts "="*70 + "\n\n"
  end

  desc "Stress Test & Resource Utilization (Memantau RAM & Memory Leak)"
  task resource_monitor: :environment do
    puts "\n=========================================================="
    puts " MEMULAI STRESS TEST (CPU & RAM UTILIZATION)              "
    puts "=========================================================="

    # Fungsi khusus Linux/Debian untuk membaca pemakaian RAM proses saat ini (dalam MB)
    def current_ram_mb
      `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
    end

    total_requests = 1000 # Simulasi 1000 orang absen berturut-turut
    batch_size = 100

    # Ambil satu gambar valid dari dataset untuk disimulasikan berkali-kali
    test_image_path = Dir.glob(Rails.root.join('tmp', 'dataset_uji', '**', '*.{jpg,jpeg,JPG,JPEG}')).first
    image_bytes = File.read(test_image_path)
    base64_img = "data:image/jpeg;base64,#{Base64.strict_encode64(image_bytes)}"

    ram_usage = []
    time_taken = []
    
    puts "[INFO] Mempersiapkan simulasi 'Peak Hour' dengan #{total_requests} request."
    initial_ram = current_ram_mb
    puts "[INFO] Konsumsi RAM Awal Server: #{initial_ram.round(2)} MB"
    
    # Titik Nol (0 Request)
    ram_usage << initial_ram.round(2)
    time_taken << 0.0

    puts "\n[PHASE 1] Membombardir sistem dengan #{total_requests} ekstraksi wajah & pencarian database..."
    
    start_time_global = Time.now

    (1..total_requests).each do |i|
      # 1. Ekstraksi Wajah AI (C++ YuNet/SFace)
      result = FaceRecognitionService.extract_face(base64_img)
      
      # 2. Pencarian Database (Pgvector) pada tumpukan 250.000+ data
      if result[:success]
        camera_vector = FaceRecognitionService.hex_to_float_array(result[:embedding])
        User.nearest_neighbors(:face_embedding, camera_vector, distance: "cosine").first
      end
      
      # Catat Performa setiap kelipatan 100
      if i % batch_size == 0
        elapsed = Time.now - start_time_global
        current_ram = current_ram_mb
        ram_usage << current_ram.round(2)
        time_taken << elapsed.round(2)
        puts " -> [#{i}/#{total_requests} Selesai] Waktu Berlalu: #{elapsed.round(1)}s | RAM: #{current_ram.round(1)} MB"
      end
    end

    puts "\n=========================================================="
    puts " HASIL STRESS TEST RESOURCE UTILIZATION"
    puts "=========================================================="
    puts " Total Waktu Eksekusi : #{(Time.now - start_time_global).round(2)} detik"
    puts " RAM Awal             : #{ram_usage.first} MB"
    puts " RAM Puncak           : #{ram_usage.max} MB"
    puts " Kenaikan RAM Maksimal: #{(ram_usage.max - ram_usage.first).round(2)} MB"
    puts "=========================================================="

    # Format Array untuk Python
    puts "\n\n" + "="*70
    puts " COPY KODE DI BAWAH INI LANGSUNG KE DALAM PYTHON ANDA:"
    puts "="*70
    puts "requests = #{ (0..total_requests).step(batch_size).to_a }"
    puts "ram_usage = #{ram_usage}"
    puts "time_taken = #{time_taken}"
    puts "="*70 + "\n\n"
  end
  
end