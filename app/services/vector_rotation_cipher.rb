require "matrix"
require "json"
require "set"

class VectorRotationCipher
  DIM = 128
  HASH_BITS = 16

  # ============================================================
  # R_global -- kunci dense, SHARED, dibaca dari file
  # ============================================================
  def self.rotation_key
    @rotation_key ||= begin
      path = ENV["VECTOR_ROTATION_KEY_PATH"] or raise "[ERROR] VECTOR_ROTATION_KEY_PATH belum diset!"
      raw = JSON.parse(File.read(path))
      unless raw.length == DIM && raw.all? { |row| row.length == DIM }
        raise "[ERROR] Dimensi R_global tidak valid! Diharapkan #{DIM}x#{DIM}"
      end
      Matrix[*raw]
    end
  end

  # Rotasi global: dihitung SEKALI per vektor query (operasi termahal, O(n^2))
  def self.apply_global_rotation(vector)
    raise ArgumentError, "Vektor harus berdimensi #{DIM}, diterima #{vector.length}" unless vector.length == DIM
    (rotation_key * Vector.elements(vector)).to_a
  end

  def self.invert_global_rotation(global_vector)
    (rotation_key.transpose * Vector.elements(global_vector)).to_a
  end

  # ============================================================
  # TIER 1 -- hash kasar (lossy) + multi-probe cerdas berbasis magnitude
  # ============================================================
  # Mengembalikan [hash_asli, daftar_varian_hash_untuk_probe]
  #
  # near_zero_count: jumlah bit "paling rawan noise" (proyeksi dekat 0) yang
  #                  akan dicoba dibalik-balik -- bit yang jauh dari 0 dianggap
  #                  stabil dan TIDAK ikut dikombinasikan (supaya kombinasi tetap murah)
  # max_flip: jumlah bit yang boleh dibalik sekaligus dalam satu varian
  def self.tier1_hash_and_probes(global_vector, near_zero_count: 8, max_flip: 3)
    projections = global_vector.first(HASH_BITS)
    hash = projections.map { |x| x >= 0 ? "1" : "0" }.join

    ranked_by_risk = (0...HASH_BITS).sort_by { |i| projections[i].abs }
    risky_bits = ranked_by_risk.first(near_zero_count)

    variants = Set.new([ hash ])
    (1..max_flip).each do |k|
      risky_bits.combination(k).each do |combo|
        v = hash.chars
        combo.each { |i| v[i] = (v[i] == "1" ? "0" : "1") }
        variants << v.join
      end
    end

    [ hash, variants.to_a ]
  end

  # ============================================================
  # TIER 2 -- signed permutation, UNIK per user, murah secara komputasi O(n)
  # ============================================================
  def self.generate_user_key
    {
      "permutation" => (0...DIM).to_a.shuffle,
      "signs"       => Array.new(DIM) { [ 1, -1 ].sample }
    }
  end

  def self.tier2_transform(global_vector, user_key)
    perm  = user_key["permutation"] || user_key[:permutation]
    signs = user_key["signs"] || user_key[:signs]
    raise ArgumentError, "user_key tidak valid" unless perm && signs
    perm.each_index.map { |i| signs[i] * global_vector[perm[i]] }
  end

  # ============================================================
  # Pencarian kandidat terbaik dari sekumpulan user (dipakai utk Tier 2
  # maupun fallback full-scan -- logic sama, bedanya cuma input `users`)
  # ============================================================
  # users: ActiveRecord::Relation atau Array of User
  # Mengembalikan [best_user, best_similarity] (best_user bisa nil kalau users kosong)
  def self.find_best_match(users, global_vector)
    best_user = nil
    best_similarity = -1.0

    users.find_each_or_each do |candidate|
      next if candidate.tier2_vector.blank? || candidate.tier2_user_key.blank?

      candidate_tier2 = JSON.parse(candidate.tier2_vector)
      user_key        = JSON.parse(candidate.tier2_user_key)
      query_tier2     = tier2_transform(global_vector, user_key)
      similarity      = cosine_similarity(query_tier2, candidate_tier2)

      if similarity > best_similarity
        best_similarity = similarity
        best_user = candidate
      end
    end

    [ best_user, best_similarity ]
  end

  # ============================================================
  # PENCARIAN TERINSTRUMENTASI -- dipakai controller, otomatis
  # mengukur waktu & mencatat PerformanceLog
  # ============================================================
  # event_type: "registration_dedup" atau "attendance"
  # Mengembalikan [best_user, best_similarity] (sama seperti find_best_match biasa)
  def self.search_with_logging(event_type:, global_vector:, hash:, probe_hashes:, threshold_distance:)
    # t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    candidates = User.where(tier1_hash: probe_hashes)
    # probe_candidate_count = candidates.count
    best_user, best_similarity = find_best_match(candidates, global_vector)

    # t_after_probe = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # probe_time_ms = (t_after_probe - t_start) * 1000.0

    used_fallback = best_user.nil? || (1.0 - best_similarity) > threshold_distance
    # fallback_time_ms = 0.0
    # fallback_candidate_count = 0

    if used_fallback
      # fallback_candidate_count = User.count
      best_user, best_similarity = find_best_match(User.all, global_vector)
      # t_after_fallback = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # fallback_time_ms = (t_after_fallback - t_after_probe) * 1000.0
    end

    # total_time_ms = probe_time_ms + fallback_time_ms
    # match_found = best_user.present? && (1.0 - best_similarity) <= threshold_distance

    # PerformanceLog.create!(
    #   event_type: event_type,
    #   tier1_hash: hash,
    #   probe_candidate_count: probe_candidate_count,
    #   used_fallback: used_fallback,
    #   fallback_candidate_count: fallback_candidate_count,
    #   probe_time_ms: probe_time_ms.round(4),
    #   fallback_time_ms: fallback_time_ms.round(4),
    #   total_time_ms: total_time_ms.round(4),
    #   best_similarity: best_similarity.round(6),
    #   match_found: match_found,
    #   matched_user_id: match_found ? best_user.id : nil
    # )

    [ best_user, best_similarity ]
  end

  # ============================================================
  # Utilitas
  # ============================================================
  # 1. Fungsi baru untuk menormalisasi vektor
  def self.l2_normalize(vector)
    magnitude = Math.sqrt(vector.sum { |x| x**2 })
    return vector if magnitude.zero? # Cegah pembagian dengan 0
    vector.map { |x| x / magnitude }
  end

  def self.cosine_similarity(a, b)
      # KARENA VEKTOR SUDAH DI-L2-NORMALIZE, COSINE SIMILARITY = DOT PRODUCT
      dot = 0.0
      i = 0
      len = DIM

      while i < len
        dot += a[i] * b[i]
        i += 1
      end

      dot
  end
end

# ============================================================
# Patch kecil: biar find_best_match bisa terima ActiveRecord::Relation
# (pakai find_each, hemat memori) MAUPUN plain Array (pakai each biasa)
# ============================================================
module FindEachOrEach
  def find_each_or_each(&block)
    if respond_to?(:find_each)
      find_each(&block)
    else
      each(&block)
    end
  end
end
ActiveRecord::Relation.include(FindEachOrEach) if defined?(ActiveRecord::Relation)
Array.include(FindEachOrEach)
