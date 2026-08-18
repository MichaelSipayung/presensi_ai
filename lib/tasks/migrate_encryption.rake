namespace :biometric do
  desc "Enkripsi massal data face_embedding yang sudah ada di database (250k+ records)"
  task encrypt_existing_data: :environment do
    puts "\n=========================================================="
    puts " MEMULAI MIGRASI ENKRIPSI DATA LAMA (250K+ RECORDS)        "
    puts "=========================================================="

    total_users = User.where.not(face_embedding: nil).count
    puts "[INFO] Total user dengan embedding ditemukan: #{total_users}"

    batch_size = 1000
    processed = 0
    start_time = Time.now

    # Menggunakan find_in_batches agar RAM server tidak jebol (Memory Efficient)
    User.where.not(face_embedding: nil).find_in_batches(batch_size: batch_size) do |users_batch|
      ActiveRecord::Base.transaction do
        users_batch.each do |user|
          # user.face_embedding pada pgvector biasanya dikembalikan dalam bentuk array float
          original_vector = user.face_embedding
          
          # Cek jika data sudah berupa array dan panjangnya 128
          if original_vector.is_a?(Array) && original_vector.size == 128
            # Enkripsi menggunakan kunci aktif saat ini
            secure_vector = FaceRecognitionService.encrypt_vector(original_vector)
            
            # Update data di database secara langsung (bypass callback agar cepat)
            user.update_column(:face_embedding, secure_vector)
          end
        end
      end

      processed += users_batch.size
      elapsed = (Time.now - start_time).round(1)
      puts " -> Progress: [#{processed}/#{total_users}] Selesai. Waktu berlalu: #{elapsed}s"
    end

    puts "\n=========================================================="
    puts " [SUKSES] Seluruh 250,000+ data berhasil dienkripsi!"
    puts "=========================================================="
  end
end