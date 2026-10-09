require 'base64'

namespace :performance do
  desc "Diagnostik detail mengapa hash rusak pada satu foto ekstrem"
  task diagnose_yaleb12: :environment do
    # 1. Pastikan yaleB12 ada di database (kalau kosong, daftarkan manual via rails c)
    user = User.find_by("name LIKE ?", "%yaleB12%")
    if user.nil?
      puts "[ERROR] User yaleB12 tidak ada di DB. Harap jalankan script evaluate sebelumnya untuk mendaftarkan yaleB."
      next
    end

    puts "=== DIAGNOSTIK KASUS: yaleB12_P00A+085E+20.pgm ==="
    puts "Wajah Asli di DB : #{user.name}"
    puts "Hash Asli (DB)   : #{user.tier1_hash[0..30]}... (dipotong)"

    # 2. Load foto yang bermasalah (Ubah path jika berbeda)
    bad_image_path = "/home/hannah/Downloads/extended_yale_b/cropped/yaleB12/yaleB12_P00A+085E+20.pgm"
    base64_str = Base64.strict_encode64(File.binread(bad_image_path))
    base64_image = "data:image/jpeg;base64,#{base64_str}"

    # 3. Ekstrak foto bermasalah
    result = FaceRecognitionService.extract_face(base64_image)
    query_vector = FaceRecognitionService.hex_to_float_array(result[:embedding])
    query_vector = VectorRotationCipher.l2_normalize(query_vector)
    query_global = VectorRotationCipher.apply_global_rotation(query_vector)
    query_hash, _ = VectorRotationCipher.tier1_hash_and_probes(query_global)

    puts "Hash Foto Gelap  : #{query_hash[0..30]}... (dipotong)"

    # 4. BONGKAR MESIN: Tarik SEMUA data (limit 7600) berurutan dari yang paling mirip hash-nya
    puts "\n[MENJALANKAN PENCARIAN FASE 1 (Levenshtein Hash)...]"
    all_ordered_candidates = VectorRotationCipher.adaptive_neighbor_search(query_hash, limit: 8000)
    
    # 5. Cari tahu di peringkat berapa wajah asli berada!
    rank_index = all_ordered_candidates.index { |u| u.id == user.id }
    
    if rank_index
      rank = rank_index + 1
      puts "=> Peringkat Wajah Asli di urutan Hash: RANK #{rank} dari #{all_ordered_candidates.size} data."
      
      if rank > 500
        puts "\n[KESIMPULAN] TERBUKTI! Wajah asli terlempar ke peringkat #{rank}. Karena limit Anda 500, wajah ini tidak pernah dihitung Cosine Similarity-nya. Itulah mengapa skor Adaptif menjadi sangat rendah (menghitung wajah orang lain)."
      else
        puts "\n[KESIMPULAN] Wajah asli ada di dalam batas 500 (Peringkat #{rank})."
      end
    else
      puts "Wajah asli sama sekali tidak ditemukan dalam pencarian."
    end
  end
end