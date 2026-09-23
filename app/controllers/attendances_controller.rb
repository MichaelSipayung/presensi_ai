class AttendancesController < ApplicationController
  # Tidak menggunakan before_action :authenticate_user! karena karyawan 
  # belum login saat berdiri di depan mesin presensi.
  def index
    # Ambil 10 data presensi terakhir dari database untuk ditampilkan di tabel
    # (Pastikan variabel ini di-set agar tidak nil di view)
    @attendances = Attendance.order(created_at: :desc).limit(10)
  end

  # def create
  #   # 1. Ekstrak wajah dari kamera (memanggil C++)
  #   result = FaceRecognitionService.extract_face(params[:image])

  #   unless result[:success]
  #     return render json: { success: false, message: result[:error] }, status: :unprocessable_entity
  #   end

  #   camera_hex = result[:embedding]
  #   camera_vector = FaceRecognitionService.hex_to_float_array(camera_hex)

  #   # 2. Proses Pencocokan (Iterasi ke Database)
  #   best_match_user = nil
  #   highest_similarity = 0.0
    
  #   # Threshold SFace (Di atas 0.65 dianggap orang yang sama)
  #   threshold = 0.65 

  #   # Looping ke seluruh user (Catatan: Ini O(N), cocok untuk skala < 1000 user)
  #   User.find_each do |user|
  #     next if user.face_embedding.blank?

  #     db_vector = FaceRecognitionService.hex_to_float_array(user.face_embedding)
  #     similarity = FaceRecognitionService.cosine_similarity(camera_vector, db_vector)

  #     if similarity > highest_similarity
  #       highest_similarity = similarity
  #       best_match_user = user
  #     end
  #   end

  #   # 3. Keputusan Presensi
  #   if highest_similarity >= threshold && best_match_user.present?
  #     # Catat kehadiran
  #     attendance = best_match_user.attendances.create!(
  #       status: "Hadir",
  #       latitude: params[:latitude],
  #       longitude: params[:longitude]
  #     )
      
  #     render json: { 
  #       success: true, 
  #       message: "Presensi berhasil! Halo, #{best_match_user.name}",
  #       similarity_score: highest_similarity.round(4)
  #     }
  #   else
  #     render json: { 
  #       success: false, 
  #       message: "Wajah tidak dikenali. Silakan coba lagi.",
  #       highest_score_found: highest_similarity.round(4)
  #     }, status: :unauthorized
  #   end
  # end

  
  # test mode PGVector
  def create
    # MENGGUNAKAN params[:image] SESUAI KODE ASLI ANDA
    if params[:image].present?
      # 1. Ekstrak wajah dari kamera (memanggil C++)
      result = FaceRecognitionService.extract_face(params[:image])

      unless result[:success]
        return render json: { success: false, message: result[:error] }, status: :unprocessable_entity
      end

      # 2. Persiapan Vektor
      camera_vector = FaceRecognitionService.hex_to_float_array(result[:embedding])

      # encrypt vector menggunakan permutasi
      # secure_camera_vector = FaceRecognitionService.encrypt_vector(camera_vector)
      # by qr
      secure_camera_vector = VectorRotationCipher.encrypt_vector(camera_vector)
      # 3. Mode Pgvector
      threshold_distance = 0.35 # Setara dengan similarity >= 0.65
      # best_match_user = User.nearest_neighbors(:face_embedding, camera_vector, distance: "cosine").first
      best_match_user = User.nearest_neighbors(:face_embedding, secure_camera_vector, distance: "cosine").first
      # 4. Keputusan Presensi
      if best_match_user.present? && best_match_user.neighbor_distance <= threshold_distance
        # Hitung similarity untuk ditampilkan di UI (Similarity = 1 - Distance)
        similarity = 1.0 - best_match_user.neighbor_distance

        # Catat kehadiran beserta Lokasi GPS
        best_match_user.attendances.create!(
          status: "Hadir",
          latitude: params[:latitude],
          longitude: params[:longitude]
        )
        
        render json: { 
          success: true, 
          message: "Presensi berhasil! Halo, #{best_match_user.name}",
          similarity_score: similarity.round(4)
        }
      else
        # Hitung skor tertinggi yang ditolak (jika ada) untuk debugging log
        highest_score_found = best_match_user.present? ? (1.0 - best_match_user.neighbor_distance).round(4) : 0.0

        render json: { 
          success: false, 
          message: "Wajah tidak dikenali. Silakan coba lagi.",
          highest_score_found: highest_score_found
        }, status: :unauthorized
      end
    else
      render json: { 
        success: false, 
        message: "Foto wajah tidak terdeteksi dari kamera." 
      }, status: :unprocessable_entity
    end
  end

end