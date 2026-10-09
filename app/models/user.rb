class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  # atribut virtual karena tidak disimpan di database, hanya untuk proses sementara
  attr_accessor :face_image
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  has_many :attendances, dependent: :destroy

  has_neighbors :face_embedding,  dimensions: 128
  encrypts :tier2_user_key   # <-- active record encryption, otomatis terenkripsi saat save
end
