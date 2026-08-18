# namespace :biometric do
#   desc "Batch Testing Skala Besar (Mendukung Sub-folder LFW)"
#   task batch_test_massal: :environment do
#     puts "\n=================================================="
#     puts " MEMULAI BATCH TESTING SKALA BESAR (NON-PGVECTOR) "
#     puts "=================================================="

#     # Gunakan pola **/* untuk mencari file .jpg/.jpeg di dalam seluruh sub-folder (termasuk lfw-deepfunneled)
#     folder_path = Rails.root.join('tmp', 'dataset_uji', '**', '*.{jpg,jpeg,JPG,JPEG}')
#     image_files = Dir.glob(folder_path)

#     if image_files.empty?
#       puts "[GAGAL] Tidak ada file gambar ditemukan di dalam direktori tmp/dataset_uji/"
#       next
#     end

#     total_images = image_files.length
#     puts "[INFO] Total ditemukan #{total_images} gambar untuk diuji."
#     puts "[INFO] Memulai pemrosesan (Catatan: Mode Non-Pgvector memakan waktu lebih lama jika data ribuan)..."
#     puts "--------------------------------------------------"

#     success_extraction = 0
#     start_global_time = Time.now

#     image_files.each_with_index do |file_path, index|
#       filename = File.basename(file_path)
      
#       # Batasi log agar terminal tidak penuh (tampilkan setiap kelipatan 50 atau file tunggal)
#       print "[#{index + 1}/#{total_images}] Memproses: #{filename} ... "

#       begin
#         image_bytes = File.read(file_path)
#         base64_img = "data:image/jpeg;base64,#{Base64.strict_encode64(image_bytes)}"

#         # 1. Ekstrak via C++ Engine
#         result = FaceRecognitionService.extract_face(base64_img)

#         unless result[:success]
#           puts "GAGAL EKSTRAK"
#           next
#         end

#         success_extraction += 1
#         camera_vector = FaceRecognitionService.hex_to_float_array(result[:embedding])

#         # 2. Pencocokan Linier ke Database (Non-Pgvector Looping)
#         best_match_user = nil
#         highest_similarity = 0.0
#         threshold = 0.65

#         User.find_each do |user|
#           next if user.face_embedding.blank?
#           db_vector = FaceRecognitionService.hex_to_float_array(user.face_embedding)
#           similarity = FaceRecognitionService.cosine_similarity(camera_vector, db_vector)

#           if similarity > highest_similarity
#             highest_similarity = similarity
#             best_match_user = user
#           end
#         end

#         if highest_similarity >= threshold
#           puts "COCOK (#{best_match_user.name} - #{highest_similarity.round(3)})"
#         else
#           puts "DITOLAK (Max: #{highest_similarity.round(3)})"
#         end

#       rescue => e
#         puts "ERROR EXCEPTION: #{e.message}"
#       end
#     end

#     duration = Time.now - start_global_time
#     puts "\n=================================================="
#     puts " LAPORAN HASIL STRESS TESTING (NON-PGVECTOR)"
#     puts " Total Gambar Diuji     : #{total_images}"
#     puts " Berhasil Diekstrak AI  : #{success_extraction}"
#     puts " Total Waktu Eksekusi   : #{duration.round(2)} detik"
#     puts "==================================================\n\n"
#   end
# end

namespace :biometric do
  desc "Batch Testing Skala Besar MENGGUNAKAN PGVECTOR"
  task batch_test_pgvector: :environment do
    puts "\n=================================================="
    puts " MEMULAI BATCH TESTING SKALA BESAR (MODE PGVECTOR)  "
    puts "=================================================="

    # Gunakan pola **/* untuk mencari file .jpg/.jpeg di seluruh sub-folder
    folder_path = Rails.root.join('tmp', 'dataset_uji', '**', '*.{jpg,jpeg,JPG,JPEG}')
    image_files = Dir.glob(folder_path)

    if image_files.empty?
      puts "[GAGAL] Tidak ada file gambar ditemukan di dalam direktori tmp/dataset_uji/"
      next
    end

    total_images = image_files.length
    puts "[INFO] Total ditemukan #{total_images} gambar untuk diuji."
    puts "[INFO] Memulai pemrosesan dengan Akselerasi Database (Pgvector)..."
    puts "--------------------------------------------------"

    success_extraction = 0
    start_global_time = Time.now

    # Jarak Cosine SFace <= 0.35 sama dengan Similarity >= 0.65
    threshold_distance = 0.35 

    image_files.each_with_index do |file_path, index|
      filename = File.basename(file_path)
      print "[#{index + 1}/#{total_images}] Memproses: #{filename} ... "

      begin
        image_bytes = File.read(file_path)
        base64_img = "data:image/jpeg;base64,#{Base64.strict_encode64(image_bytes)}"

        # 1. Ekstrak via C++ Engine
        result = FaceRecognitionService.extract_face(base64_img)

        unless result[:success]
          puts "GAGAL EKSTRAK"
          next
        end

        success_extraction += 1
        camera_vector = FaceRecognitionService.hex_to_float_array(result[:embedding])

        # 2. Pencocokan Instan ke Database menggunakan Pgvector
        best_match_user = User.nearest_neighbors(:face_embedding, camera_vector, distance: "cosine").first

        # 3. Evaluasi Hasil (Mengonversi Distance kembali menjadi Similarity untuk Log)
        if best_match_user.present?
          jarak = best_match_user.neighbor_distance
          similarity = 1.0 - jarak

          if jarak <= threshold_distance
            puts "COCOK (#{best_match_user.name} - #{similarity.round(3)})"
          else
            puts "DITOLAK (Max: #{similarity.round(3)})"
          end
        else
          puts "DITOLAK (Database kosong)"
        end

      rescue => e
        puts "ERROR EXCEPTION: #{e.message}"
      end
    end

    duration = Time.now - start_global_time
    rata_rata = duration / total_images

    puts "\n=================================================="
    puts " LAPORAN HASIL STRESS TESTING (MODE PGVECTOR)"
    puts " Total Gambar Diuji     : #{total_images}"
    puts " Berhasil Diekstrak AI  : #{success_extraction}"
    puts " Total Waktu Eksekusi   : #{duration.round(2)} detik"
    puts " Rata-rata per Gambar   : #{rata_rata.round(4)} detik"
    puts "==================================================\n\n"
  end
end