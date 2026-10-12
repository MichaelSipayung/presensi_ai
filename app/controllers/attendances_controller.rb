# frozen_string_literal: true

# AttendancesController
# =====================
# Endpoint presensi wajah.
#
#   GET  /attendances  -> halaman presensi + 10 riwayat terbaru
#   POST /attendances  -> menerima foto dari kamera (JSON), mengembalikan hasil verifikasi
#
# Prinsip privasi (privacy by design / data minimization):
#   * Foto hanya dipakai untuk mengekstrak embedding; citra mentah TIDAK disimpan.
#   * Embedding langsung ditransformasi (rotasi global Tier 1) sebelum dicari.
#   * Yang dibandingkan dengan basis data hanyalah template terproteksi, bukan embedding asli.
class AttendancesController < ApplicationController
  # Daftar 10 presensi terakhir (terbaru di atas).
  def index
    @attendances = Attendance.order(created_at: :desc).limit(10)
  end

  # Memverifikasi wajah dan mencatat presensi.
  #
  # Params:
  #   image     [String] foto wajah dari kamera (wajib)
  #   latitude  [Float]  lokasi presensi (opsional, disimpan apa adanya)
  #   longitude [Float]
  #
  # Respons JSON:
  #   200 { success: true,  message, similarity_score }       presensi tercatat
  #   401 { success: false, message, highest_score_found }    wajah tidak dikenali
  #   422 { success: false, message }                         foto kosong / wajah tidak terdeteksi
  def create
    unless params[:image].present?
      return render json: { success: false, message: "Foto wajah tidak terdeteksi dari kamera." },
                    status: :unprocessable_entity
    end

    # 1. Deteksi wajah (YuNet) dan ekstraksi embedding SFace 128-d lewat mesin C++.
    result = FaceRecognitionService.extract_face(params[:image])
    unless result[:success]
      return render json: { success: false, message: result[:error] }, status: :unprocessable_entity
    end

    # 2. Normalisasi L2 (x̂), lalu Tier 1: rotasi ortogonal global g = R·x̂.
    #    Normalisasi wajib agar cosine similarity cukup berupa dot product.
    camera_vector = VectorRotationCipher.l2_normalize(
      FaceRecognitionService.hex_to_float_array(result[:embedding])
    )
    global_vector = VectorRotationCipher.apply_global_rotation(camera_vector)

    # 3. Pencarian: sketch Hamming 64 bit memilih K kandidat di PostgreSQL,
    #    lalu kandidat diverifikasi dengan cosine (setelah Tier 2 per pengguna).
    #    Hasil pencarian juga dicatat ke PerformanceLog untuk evaluasi.
    best_user, best_similarity = VectorRotationCipher.search_sketch(
      event_type: "attendance_sketch64",
      global_vector: global_vector, k: FaceMatching::K, tau: FaceMatching::TAU
    )

    # 4. Keputusan: terima hanya jika similarity mencapai ambang TAU.
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