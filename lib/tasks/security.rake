namespace :security do
  desc "Bangkitkan Permutation Key untuk Enkripsi Vektor"
  task generate_key: :environment do
    # Membuat urutan acak 0-127 (untuk vektor 128-dimensi)
    # Seed menggunakan waktu agar unik setiap kali dibangkitkan
    permutation_key = (0..127).to_a.shuffle(random: Random.new(Time.now.to_i)).join(',')
    
    env_path = Rails.root.join('.env')
    
    # Menulis/Memperbarui file .env
    if File.exist?(env_path)
      content = File.read(env_path)
      if content.include?("VECTOR_PERMUTATION_KEY")
        puts "[ERROR] VECTOR_PERMUTATION_KEY sudah ada di .env!"
      else
        File.open(env_path, 'a') { |f| f.puts "\nVECTOR_PERMUTATION_KEY=#{permutation_key}" }
        puts "[SUKSES] Kunci berhasil disimpan ke .env!"
      end
    else
      File.open(env_path, 'w') { |f| f.puts "VECTOR_PERMUTATION_KEY=#{permutation_key}" }
      puts "[SUKSES] File .env dibuat dan kunci disimpan!"
    end
  end
end