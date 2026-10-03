class AttendancesController < ApplicationController
  THRESHOLD_DISTANCE = 0.35

  def index
    @attendances = Attendance.order(created_at: :desc).limit(10)
  end

  def create
    unless params[:image].present?
      return render json: { success: false, message: "Foto wajah tidak terdeteksi dari kamera." },
                     status: :unprocessable_entity
    end

    result = FaceRecognitionService.extract_face(params[:image])

    unless result[:success]
      return render json: { success: false, message: result[:error] }, status: :unprocessable_entity
    end

    camera_vector = FaceRecognitionService.hex_to_float_array(result[:embedding])
    # normalisasi vektor sebelum masuk ke sistem cipher
    camera_vector = VectorRotationCipher.l2_normalize(camera_vector)
    global_vector = VectorRotationCipher.apply_global_rotation(camera_vector)
    hash, probe_hashes = VectorRotationCipher.tier1_hash_and_probes(global_vector)

    best_user, best_similarity = VectorRotationCipher.search_with_logging(
      event_type: "attendance",
      global_vector: global_vector,
      hash: hash,
      probe_hashes: probe_hashes,
      threshold_distance: THRESHOLD_DISTANCE
    )


    if best_user.present? && (1.0 - best_similarity) <= THRESHOLD_DISTANCE
      best_user.attendances.create!(
        status: "Hadir",
        latitude: params[:latitude],
        longitude: params[:longitude]
      )
      render json: {
        success: true,
        message: "Presensi berhasil! Halo, #{best_user.name}",
        similarity_score: best_similarity.round(4)
      }
    else
      render json: {
        success: false,
        message: "Wajah tidak dikenali. Silakan coba lagi.",
        highest_score_found: best_similarity.round(4)
      }, status: :unauthorized
    end
  end
end
