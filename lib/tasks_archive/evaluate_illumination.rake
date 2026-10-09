require 'base64'
THRESHOLD = 1.0 - 0.35 # (Yaitu 0.65)

namespace :performance do
  desc "Evaluasi false rejection rate Adaptive vs Full-Scan pakai Extended Yale B."
  task :evaluate_illumination, [:dataset_path] => :environment do |_t, args|
    dataset_path = args[:dataset_path] or raise "Usage: rails performance:evaluate_illumination[/path/to/cropped]"

    FILENAME_PATTERN = /yaleB\d+_P(\d{2})(?:A([+-]\d+)E([+-]\d+)|_Ambient)/

    def self.lighting_difficulty(azimuth, elevation)
      return :extreme if azimuth.nil?
      angle = Math.sqrt(azimuth.to_f**2 + elevation.to_f**2)
      return :good    if angle <= 25
      return :extreme if angle >= 70
      :medium
    end

    def self.encode_image(path)
      base64_str = Base64.strict_encode64(File.binread(path))
      "data:image/jpeg;base64,#{base64_str}"
    end

    results = []
    subject_dirs = Dir.glob("#{dataset_path}/yaleB*").select { |d| File.directory?(d) }
    puts "[INFO] Ditemukan #{subject_dirs.size} folder subjek."

    subject_dirs.each do |subject_dir|
      subject_name = File.basename(subject_dir)
      files = Dir.glob("#{subject_dir}/*.pgm")

      frontal_files = files.select { |f| f =~ /_P00/ }
      next if frontal_files.empty?

      categorized = frontal_files.group_by do |f|
        m = File.basename(f).match(FILENAME_PATTERN)
        next :unknown unless m
        lighting_difficulty(m[2], m[3])
      end

      baik_path = categorized[:good]&.first
      buruk_paths = categorized[:extreme] || []

      next unless baik_path && buruk_paths.any?

      result = FaceRecognitionService.extract_face(encode_image(baik_path))
      unless result[:success]
        puts "[SKIP] #{subject_name}: gagal ekstrak foto baik (#{result[:error]})"
        next
      end

      camera_vector = FaceRecognitionService.hex_to_float_array(result[:embedding])
      camera_vector = VectorRotationCipher.l2_normalize(camera_vector)
      global_vector = VectorRotationCipher.apply_global_rotation(camera_vector)
      hash, _probes = VectorRotationCipher.tier1_hash_and_probes(global_vector)
      user_key = VectorRotationCipher.generate_user_key
      tier2_vector = VectorRotationCipher.tier2_transform(global_vector, user_key)

      user = User.create!(
        name: "yale_#{subject_name}",
        email: "yale_#{subject_name}_#{SecureRandom.hex(4)}@test.local",
        password: "dummy_password_123",
        tier1_hash: hash,
        tier2_vector: tier2_vector.to_json,
        tier2_user_key: user_key.to_json
      )

      puts "[REGISTER] #{subject_name} -> #{File.basename(baik_path)}"

      buruk_paths.each do |buruk_path|
        r2 = FaceRecognitionService.extract_face(encode_image(buruk_path))
        next unless r2[:success]

        query_vector = FaceRecognitionService.hex_to_float_array(r2[:embedding])
        query_vector = VectorRotationCipher.l2_normalize(query_vector)
        query_global = VectorRotationCipher.apply_global_rotation(query_vector)
        query_hash, _ = VectorRotationCipher.tier1_hash_and_probes(query_global)

        full_match, full_sim = VectorRotationCipher.find_best_match(User.all, query_global)
        
        # Menggunakan limit 500 seperti yang sudah disepakati
        adaptive_candidates = VectorRotationCipher.adaptive_neighbor_search(query_hash, limit: 500)
        adaptive_match, adaptive_sim = VectorRotationCipher.find_best_match(adaptive_candidates, query_global)

        # correct_full = full_match&.id == user.id
        # correct_adaptive = adaptive_match&.id == user.id

        # Controller Simulation: Harus cocok ID-nya DAN skor kemiripannya harus >= 0.65
        correct_full = (full_match&.id == user.id) && (full_sim >= THRESHOLD)
        correct_adaptive = (adaptive_match&.id == user.id) && (adaptive_sim >= THRESHOLD)

        results << {
          subject: subject_name,
          file: File.basename(buruk_path),
          full_correct: correct_full,
          adaptive_correct: correct_adaptive,
          full_similarity: full_sim,
          adaptive_similarity: adaptive_sim
        }

        status = correct_full == correct_adaptive ? "OK" : "!! BEDA HASIL !!"
        puts "  #{File.basename(buruk_path)}: full=#{correct_full}(#{full_sim.round(3)}) adaptive=#{correct_adaptive}(#{adaptive_sim.round(3)}) #{status}"
      end
    end

    total = results.size
    if total.zero?
      puts "\n[PERINGATAN] Tidak ada sampel yang berhasil diuji. Cek pola nama file / path dataset."
    else
      false_rejections = results.count { |r| r[:full_correct] && !r[:adaptive_correct] }
      both_correct = results.count { |r| r[:full_correct] && r[:adaptive_correct] }

      puts "\n=== HASIL EVALUASI (#{total} sampel pencahayaan ekstrem) ==="
      puts "Full scan benar mengenali     : #{results.count { |r| r[:full_correct] }} (#{(results.count { |r| r[:full_correct] }.to_f/total*100).round(2)}%)"
      puts "Adaptive-500 benar mengenali  : #{results.count { |r| r[:adaptive_correct] }} (#{(results.count { |r| r[:adaptive_correct] }.to_f/total*100).round(2)}%)"
      puts "False rejection (full benar, adaptive salah): #{false_rejections} (#{(false_rejections.to_f/total*100).round(2)}%)"
      puts "Kedua metode sama-sama benar  : #{both_correct} (#{(both_correct.to_f/total*100).round(2)}%)"
    end
  end
end
