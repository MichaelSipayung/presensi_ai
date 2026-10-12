# frozen_string_literal: true

# Users::RegistrationsController
# ==============================
# Memperluas Devise::RegistrationsController: pendaftaran akun sekaligus
# enrollment wajah (template biometrik terbatalkan dua tingkat).
#
# Alur #create:
#   1. Foto wajah wajib ada, lalu diekstrak menjadi embedding SFace 128-d.
#   2. Embedding dinormalisasi L2 dan dirotasi global (Tier 1): g = R·x̂.
#   3. Deteksi akun ganda: pemindaian PENUH (bukan sketch) agar tidak ada wajah
#      yang sama lolos mendaftar dua kali.
#   4. Jika lolos: buat kunci Tier 2 baru (permutasi bertanda) khusus akun ini,
#      simpan template w = P·g, kunci (terenkripsi), dan sketch Hamming 64 bit.
#   5. Foto mentah tidak pernah disimpan; hanya `face_image` yang dikecualikan
#      dari atribut User.
class Users::RegistrationsController < Devise::RegistrationsController
  before_action :configure_sign_up_params, only: [ :create ]

  # POST /users
  #
  # Params: user[name], user[email], user[password], user[face_image] (+ field Devise lain).
  # Gagal -> render :new dengan status 422 (foto kosong, wajah tidak valid,
  # wajah sudah terdaftar, atau validasi model gagal).
  def create
    build_resource(sign_up_params.except(:face_image))

    unless params[:user][:face_image].present?
      return reject_registration("Foto wajah wajib diambil untuk pendaftaran sistem presensi.")
    end

    # 1. Deteksi wajah (YuNet) + embedding SFace lewat mesin C++.
    result = FaceRecognitionService.extract_face(params[:user][:face_image])
    unless result[:success]
      return reject_registration("Validasi Wajah Gagal: #{result[:error]}")
    end

    # 2. Normalisasi L2 sebelum masuk ke cipher, lalu rotasi global Tier 1 (sekali saja).
    camera_vector = VectorRotationCipher.l2_normalize(
      FaceRecognitionService.hex_to_float_array(result[:embedding])
    )
    global_vector = VectorRotationCipher.apply_global_rotation(camera_vector)

    # 3. Cek duplikasi dengan full scan; hasil tercatat di PerformanceLog.
    #    Ambang dedup sama dengan ambang presensi (FaceMatching::TAU).
    duplicate_user, duplicate_similarity = VectorRotationCipher.search_full_scan(
      event_type: "registration_dedup_fullscan",
      global_vector: global_vector, tau: FaceMatching::TAU
    )

    if duplicate_user.present? && duplicate_similarity >= FaceMatching::TAU
      return reject_registration(
        "Registrasi ditolak! Wajah Anda sudah terdaftar di dalam sistem atas nama " \
        "'#{duplicate_user.name}'. Satu wajah hanya dapat mendaftarkan satu akun."
      )
    end

    # 4. Lolos: kunci Tier 2 BARU untuk akun ini (revocable: ganti kunci = template baru).
    user_key     = VectorRotationCipher.generate_user_key
    tier2_vector = VectorRotationCipher.tier2_transform(global_vector, user_key)

    resource.sketch         = VectorRotationCipher.sketch(global_vector) # indeks pencarian Hamming
    resource.tier2_vector   = tier2_vector.to_json
    resource.tier2_user_key = user_key.to_json # dienkripsi otomatis (Active Record Encryption) saat save

    resource.save
    yield resource if block_given?

    # 5. Alur Devise standar setelah penyimpanan.
    if resource.persisted?
      if resource.active_for_authentication?
        set_flash_message! :notice, :signed_up
        sign_up(resource_name, resource)
        respond_with resource, location: after_sign_up_path_for(resource)
      else
        set_flash_message! :notice, :"signed_up_but_#{resource.inactive_message}"
        expire_data_after_sign_in!
        respond_with resource, location: after_inactive_sign_up_path_for(resource)
      end
    else
      render_invalid_form
    end
  end

  protected

  # Mengizinkan field tambahan pada form pendaftaran.
  def configure_sign_up_params
    devise_parameter_sanitizer.permit(:sign_up, keys: [ :name, :face_image ])
  end

  private

  # Menolak pendaftaran: tambahkan pesan galat lalu tampilkan ulang form (422).
  def reject_registration(message)
    resource.errors.add(:base, message)
    render_invalid_form
  end

  # Mengosongkan password pada form dan merender ulang halaman pendaftaran.
  def render_invalid_form
    clean_up_passwords resource
    set_minimum_password_length
    render :new, status: :unprocessable_entity
  end
end