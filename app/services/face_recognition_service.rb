require 'open3'
require 'base64'
require 'securerandom'

class FaceRecognitionService
  def self.extract_face(base64_image)
    # 1. Bersihkan header base64 (data:image/jpeg;base64,...)
    image_data = base64_image.sub(/^data:image\/(png|jpg|jpeg);base64,/, '')
    decoded_image = Base64.decode64(image_data)
    
    # 2. Simpan gambar sementara di folder /tmp
    temp_path = Rails.root.join('tmp', "scan_#{SecureRandom.hex(8)}.jpg").to_s
    File.open(temp_path, 'wb') { |f| f.write(decoded_image) }

    # 3. Path ke aplikasi C++ (Pastikan face_engine dan folder models ada di sini)
    cpp_binary = Rails.root.join('lib', 'engine', 'face_engine').to_s

    # 4. EKSEKUSI C++ (Ini jembatan komunikasinya!)
    # stdout adalah teks yang di-cout oleh C++, stderr adalah pesan error jika program crash
    stdout, stderr, status = Open3.capture3("#{cpp_binary} #{temp_path}")

    # 5. Evaluasi Hasil C++
    if status.success? && stdout.include?("SUCCESS:")
      hex_string = stdout.split("SUCCESS:")[1].strip
      return { success: true, embedding: hex_string }
    else
      # Jika error, pastikan file dihapus secara manual sebagai fallback
      File.delete(temp_path) if File.exist?(temp_path)
      error_msg = stdout.include?("ERROR:") ? stdout.split("ERROR:")[1].strip : "Kegagalan sistem AI"
      return { success: false, error: error_msg }
    end
  end

  # 1. Konversi Hex String dari C++ kembali menjadi Array Float di Ruby
  def self.hex_to_float_array(hex_str)
    # pack('H*') mengubah string hex menjadi deretan byte (binary)
    # unpack('e*') mengubah byte tersebut menjadi array float (single-precision, little-endian)
    # Format 'e*' cocok dengan output C++ float pada arsitektur standar (x86/ARM)
    [hex_str].pack('H*').unpack('e*')
  end

  # 2. Perhitungan Cosine Similarity
  def self.cosine_similarity(vec_a, vec_b)
    return 0.0 if vec_a.nil? || vec_b.nil? || vec_a.length != vec_b.length

    dot_product = 0.0
    norm_a = 0.0
    norm_b = 0.0

    vec_a.each_with_index do |val_a, i|
      val_b = vec_b[i]
      dot_product += val_a * val_b
      norm_a += val_a ** 2
      norm_b += val_b ** 2
    end

    return 0.0 if norm_a == 0.0 || norm_b == 0.0

    # Mengembalikan nilai similarity (0.0 s/d 1.0)
    dot_product / (Math.sqrt(norm_a) * Math.sqrt(norm_b))
  end
  
  # Membaca kunci dari .env dan mengubahnya menjadi array integer
  def self.permutation_key
    unless ENV['VECTOR_PERMUTATION_KEY']
      raise "[ERROR] VECTOR_PERMUTATION_KEY belum di-generate! Jalankan 'rails security:generate_key'"
    end
    @permutation_key ||= ENV['VECTOR_PERMUTATION_KEY'].split(',').map(&:to_i)
  end

  # Fungsi Enkripsi (Permutasi Vektor)
  def self.encrypt_vector(vector)
    key = permutation_key
    encrypted = Array.new(128)
    key.each_with_index do |original_index, new_index|
      encrypted[new_index] = vector[original_index]
    end
    encrypted
  end
  
end