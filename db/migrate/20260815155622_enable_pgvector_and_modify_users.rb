class EnablePgvectorAndModifyUsers < ActiveRecord::Migration[8.1]
  def change
    # 1. Aktifkan ekstensi pgvector di PostgreSQL
    enable_extension 'vector'

    # 2. Hapus kolom face_embedding lama (yang bertipe text)
    remove_column :users, :face_embedding, :text

    # 3. Tambahkan kolom baru dengan tipe data vector dan panjang 128 dimensi
    add_column :users, :face_embedding, :vector, limit: 128
  end
end