class AttendancesController < ApplicationController
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

    camera_vector = VectorRotationCipher.l2_normalize(
      FaceRecognitionService.hex_to_float_array(result[:embedding])
    )
    global_vector = VectorRotationCipher.apply_global_rotation(camera_vector)

    best_user, best_similarity = VectorRotationCipher.search_sketch(
      event_type: "attendance_sketch64",
      global_vector: global_vector, k: FaceMatching::K, tau: FaceMatching::TAU
    )

    if best_user.present? && best_similarity >= FaceMatching::TAU
      best_user.attendances.create!(status: "Hadir", latitude: params[:latitude], longitude: params[:longitude])
      render json: { success: true, message: "Presensi berhasil! Halo, #{best_user.name}",
                     similarity_score: best_similarity.round(4) }
    else
      render json: { success: false, message: "Wajah tidak dikenali. Silakan coba lagi.",
                     highest_score_found: best_similarity.round(4) }, status: :unauthorized
    end
  end
end