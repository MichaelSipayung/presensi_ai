class Users::RegistrationsController < Devise::RegistrationsController
  before_action :configure_sign_up_params, only: [ :create ]

  # THRESHOLD_DISTANCE = 0.35  # cosine distance; similarity >= 0.65 dianggap wajah sama
  THRESHOLD_DISTANCE = 1.0 - FaceMatching::TAU
  def create
    build_resource(sign_up_params.except(:face_image))

    unless params[:user][:face_image].present?
      resource.errors.add(:base, "Foto wajah wajib diambil untuk pendaftaran sistem presensi.")
      clean_up_passwords resource
      set_minimum_password_length
      return render :new, status: :unprocessable_entity
    end

    result = FaceRecognitionService.extract_face(params[:user][:face_image])

    unless result[:success]
      resource.errors.add(:base, "Validasi Wajah Gagal: #{result[:error]}")
      clean_up_passwords resource
      set_minimum_password_length
      return render :new, status: :unprocessable_entity
    end

    camera_vector = FaceRecognitionService.hex_to_float_array(result[:embedding])
    # Normalisasi vektor sebelum masuk ke sistem cipher
    camera_vector = VectorRotationCipher.l2_normalize(camera_vector)
    # ---- Rotasi global (sekali) + hash Tier 1 + daftar varian probe ----
    global_vector = VectorRotationCipher.apply_global_rotation(camera_vector)
    hash, probe_hashes = VectorRotationCipher.tier1_hash_and_probes(global_vector)

    # ---- CEK DUPLIKASI: multi-probe + fallback otomatis, sekaligus tercatat di PerformanceLog ----
    duplicate_user, duplicate_similarity = VectorRotationCipher.search_full_scan(
      event_type: "registration_dedup_fullscan",
      global_vector: global_vector, tau: FaceMatching::TAU
    )

    if duplicate_user.present? && duplicate_similarity >= FaceMatching::TAU
        resource.errors.add(:base,
        "Registrasi ditolak! Wajah Anda sudah terdaftar di dalam sistem atas nama '#{duplicate_user.name}'. Satu wajah hanya dapat mendaftarkan satu akun.")
      clean_up_passwords resource
      set_minimum_password_length
      return render :new, status: :unprocessable_entity
    end

    # ---- Lolos cek duplikasi: generate kunci Tier 2 BARU untuk akun ini ----
    user_key     = VectorRotationCipher.generate_user_key
    tier2_vector = VectorRotationCipher.tier2_transform(global_vector, user_key)

    # resource.tier1_hash     = hash
    resource.sketch         = VectorRotationCipher.sketch(global_vector)
    resource.tier2_vector   = tier2_vector.to_json
    resource.tier2_user_key = user_key.to_json   # terenkripsi otomatis saat save

    resource.sketch = VectorRotationCipher.sketch(global_vector)
    resource.save
    yield resource if block_given?

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
      clean_up_passwords resource
      set_minimum_password_length
      render :new, status: :unprocessable_entity
    end
  end

  protected

  def configure_sign_up_params
    devise_parameter_sanitizer.permit(:sign_up, keys: [ :name, :face_image ])
  end
end
