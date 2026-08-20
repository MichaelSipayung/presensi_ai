# class Users::RegistrationsController < Devise::RegistrationsController
#   before_action :configure_sign_up_params, only: [:create]

#   def create
#     build_resource(sign_up_params.except(:face_image))

#     if params[:user][:face_image].present?
#       # 1. Panggil service C++ untuk mengekstrak wajah menjadi Hex String
#       result = FaceRecognitionService.extract_face(params[:user][:face_image])

#       if result[:success]
#         new_hex_embedding = result[:embedding]
#         new_float_vector = FaceRecognitionService.hex_to_float_array(new_hex_embedding)

#         # ====================================================================
#         # PENCEGAHAN DUPLIKASI WAJAH (VERSI NON-PGVECTOR / APPLICATION LAYER)
#         # ====================================================================
#         threshold_similarity = 0.65 # Batas kemiripan SFace (semakin tinggi semakin mirip)
#         duplicate_found = false
#         duplicate_name = ""

#         # Looping semua user yang sudah terdaftar untuk mengecek kemiripan wajah
#         User.find_each do |existing_user|
#           next if existing_user.face_embedding.blank?

#           # Ubah hex dari database kembali ke array float
#           existing_float_vector = FaceRecognitionService.hex_to_float_array(existing_user.face_embedding)
          
#           # Hitung cosine similarity di Ruby
#           similarity = FaceRecognitionService.cosine_similarity(new_float_vector, existing_float_vector)

#           # Jika tingkat kemiripan melewati batas threshold, berarti wajah sudah ada
#           if similarity >= threshold_similarity
#             duplicate_found = true
#             duplicate_name = existing_user.name
#             break
#           end
#         end

#         if duplicate_found
#           resource.errors.add(:base, "Registrasi ditolak! Wajah Anda sudah terdaftar di dalam sistem atas nama '#{duplicate_name}'. Satu wajah hanya dapat mendaftarkan satu akun.")
#           clean_up_passwords resource
#           set_minimum_password_length
#           return render :new, status: :unprocessable_entity
#         end
#         # ====================================================================

#         # Jika lolos (tidak ada duplikat), simpan hex string ke database
#         resource.face_embedding = new_hex_embedding
#       else
#         resource.errors.add(:base, "Validasi Wajah Gagal: #{result[:error]}")
#         clean_up_passwords resource
#         set_minimum_password_length
#         return render :new, status: :unprocessable_entity
#       end
#     else
#       resource.errors.add(:base, "Foto wajah wajib diambil untuk pendaftaran sistem presensi.")
#       clean_up_passwords resource
#       set_minimum_password_length
#       return render :new, status: :unprocessable_entity
#     end

#     # Lanjutkan proses simpan bawaan Devise
#     resource.save
#     yield resource if block_given?
#     if resource.persisted?
#       if resource.active_for_authentication?
#         set_flash_message! :notice, :signed_up
#         sign_up(resource_name, resource)
#         respond_with resource, location: after_sign_up_path_for(resource)
#       else
#         set_flash_message! :notice, :"signed_up_but_#{resource.inactive_message}"
#         expire_data_after_sign_in!
#         respond_with resource, location: after_inactive_sign_up_path_for(resource)
#       end
#     else
#       clean_up_passwords resource
#       set_minimum_password_length
#       render :new, status: :unprocessable_entity
#     end
#   end

#   protected

#   def configure_sign_up_params
#     devise_parameter_sanitizer.permit(:sign_up, keys: [:name, :face_image])
#   end
# end

class Users::RegistrationsController < Devise::RegistrationsController
  before_action :configure_sign_up_params, only: [:create]

  def create
    build_resource(sign_up_params.except(:face_image))

    if params[:user][:face_image].present?
      # 1. Ekstrak vektor dari C++
      result = FaceRecognitionService.extract_face(params[:user][:face_image])

      if result[:success]
        # Konversi hex ke array float
        camera_vector = FaceRecognitionService.hex_to_float_array(result[:embedding])
        # permutasi vektor -- encryption mode
        secure_camera_vector = FaceRecognitionService.encrypt_vector(camera_vector)
        # ====================================================================
        # TAHAP BARU: CEK DUPLIKASI WAJAH (DEDUPLIKASI BIOMETRIK)
        # ====================================================================
        threshold_distance = 0.35 # Batas wajar model SFace (Cosine Distance)
        
        # Cari apakah ada user di database yang wajahnya mirip dengan pendaftar ini
        #existing_duplicate = User.nearest_neighbors(:face_embedding, camera_vector, distance: "cosine").first
        
        # gunakan data yang sudah dienkripsi untuk pencarian duplikasi
        existing_duplicate = User.nearest_neighbors(:face_embedding, secure_camera_vector, 
          distance: "cosine").first

        if existing_duplicate.present? && existing_duplicate.neighbor_distance <= threshold_distance
          # wajah sudah terdaftar, tolak pendaftaran!
          resource.errors.add(:base, "Registrasi ditolak! Wajah Anda sudah terdaftar di dalam sistem atas nama '
            #{existing_duplicate.name}'. Satu wajah hanya dapat mendaftarkan satu akun.")
          clean_up_passwords resource
          set_minimum_password_length
          return render :new, status: :unprocessable_entity
        end
        # ====================================================================

        # Jika lolos cek duplikasi, simpan vektor ke akun baru
        #resource.face_embedding = camera_vector
        # simpan vektor terenkripsi ke database
        resource.face_embedding = secure_camera_vector
      else
        resource.errors.add(:base, "Validasi Wajah Gagal: #{result[:error]}")
        clean_up_passwords resource
        set_minimum_password_length
        return render :new, status: :unprocessable_entity
      end
    else
      resource.errors.add(:base, "Foto wajah wajib diambil untuk pendaftaran sistem presensi.")
      clean_up_passwords resource
      set_minimum_password_length
      return render :new, status: :unprocessable_entity
    end

    # Lanjutkan proses simpan bawaan Devise (ke database)
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
    devise_parameter_sanitizer.permit(:sign_up, keys: [:name, :face_image])
  end
end