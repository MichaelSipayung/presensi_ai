# app/services/vector_rotation_cipher.rb
require 'matrix'
require 'json'

class VectorRotationCipher
  DIM = 128

  def self.encrypt_vector(vector)
    v = Vector.elements(vector)
    (rotation_key * v).to_a
  end

  def self.decrypt_vector(encrypted_vector)
    v = Vector.elements(encrypted_vector)
    (rotation_key.transpose * v).to_a
  end

  def self.rotation_key
    @rotation_key ||= begin
      path = ENV['VECTOR_ROTATION_KEY_PATH'] or raise "[ERROR] VECTOR_ROTATION_KEY_PATH belum diset di .env!"
      raw = JSON.parse(File.read(path))   # array 128x128 nested
      Matrix[*raw]
    end
  end
end