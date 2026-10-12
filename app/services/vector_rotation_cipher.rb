# frozen_string_literal: true

require "matrix"
require "json"

# VectorRotationCipher
# ====================
# Lapisan perlindungan template biometrik (cancelable biometrics) dan pencarian
# kandidat untuk sistem presensi wajah.
#
# Alur data (lihat naskah JTIIK, Bab 2):
#
#   embedding SFace 128-d (sudah L2-normalized, x̂)
#     └─ Tier 1: rotasi ortogonal global rahasia R      →  g = R·x̂
#          ├─ sketch Hamming 64 bit (median-threshold)  →  indeks pencarian cepat
#          └─ Tier 2: signed permutation per pengguna   →  w = P·g  (template tersimpan)
#
# Sifat penting:
#   * R (orthogonal) dan P (permutasi bertanda) sama-sama ISOMETRIK, sehingga
#     cosine(P·g_query, w_enrolled) sama dengan cosine antar embedding asli.
#     Akurasi pencocokan tidak berubah oleh lapisan privasi.
#   * Kunci Tier 2 per pengguna (permutation + signs) disimpan terenkripsi
#     (Active Record Encryption, AES-256-GCM) pada kolom User#tier2_user_key.
#   * Template bisa dibatalkan (revocable): ganti kunci pengguna lalu enroll ulang.
#
# Dua jalur pencarian:
#   * {search_sketch}    -> presensi harian: Top-K Hamming di PostgreSQL, lalu cosine.
#   * {search_full_scan} -> registrasi (deteksi akun ganda): cosine ke semua pengguna.
#
# Variabel lingkungan yang wajib diset:
#   VECTOR_ROTATION_KEY_PATH  JSON matriks 128x128 (R). RAHASIA, jangan di-commit.
#   SKETCH_OFFSETS_PATH       JSON array 64 angka (ambang median per dimensi sketch).
class VectorRotationCipher
  # Dimensi embedding SFace.
  DIM = 128

  # Panjang sketch Hamming (bit). Harus sama dengan lebar kolom bit(64) pada
  # users.sketch dan jumlah entri pada file SKETCH_OFFSETS_PATH.
  SKETCH_BITS = 64

  class << self
    # ==========================================================
    # Kunci global R (Tier 1)
    # ==========================================================

    # Matriks rotasi global R (DIM x DIM), dibaca dari file dan di-cache per proses.
    # Satu kunci dipakai bersama oleh semua pengguna; kerahasiaannya dijaga di
    # level server (file di luar repositori).
    #
    # @return [Matrix]
    # @raise [RuntimeError] jika env belum diset atau dimensi tidak 128x128
    def rotation_key
      @rotation_key ||= begin
        path = ENV["VECTOR_ROTATION_KEY_PATH"] or raise "[ERROR] VECTOR_ROTATION_KEY_PATH belum diset!"
        raw = JSON.parse(File.read(path))
        unless raw.length == DIM && raw.all? { |row| row.length == DIM }
          raise "[ERROR] Dimensi R_global tidak valid! Diharapkan #{DIM}x#{DIM}"
        end
        Matrix[*raw]
      end
    end

    # Tier 1: g = R·x̂. Dihitung SEKALI per vektor query (operasi termahal, O(n²)).
    #
    # @param vector [Array<Float>] embedding ter-normalisasi L2, panjang DIM
    # @return [Array<Float>] vektor global g
    # @raise [ArgumentError] jika panjang vektor bukan DIM
    def apply_global_rotation(vector)
      raise ArgumentError, "Vektor harus berdimensi #{DIM}, diterima #{vector.length}" unless vector.length == DIM
      (rotation_key * Vector.elements(vector)).to_a
    end

    # Kebalikan Tier 1: x̂ = Rᵀ·g (R ortogonal, jadi invers = transpos).
    # Tidak dipakai di jalur produksi; hanya untuk pengujian/analisis keamanan
    # (mis. simulasi penyerang yang memegang R).
    #
    # @param global_vector [Array<Float>]
    # @return [Array<Float>]
    def invert_global_rotation(global_vector)
      (rotation_key.transpose * Vector.elements(global_vector)).to_a
    end

    # ==========================================================
    # Tier 2: signed permutation per pengguna
    # ==========================================================

    # Membuat kunci Tier 2 acak untuk satu pengguna: permutasi indeks + tanda ±1.
    # Ruang kunci 128! · 2¹²⁸. Simpan hasilnya (JSON) di User#tier2_user_key.
    #
    # @return [Hash{String=>Array<Integer>}] {"permutation" => [...], "signs" => [...]}
    def generate_user_key
      {
        "permutation" => (0...DIM).to_a.shuffle,
        "signs"       => Array.new(DIM) { [ 1, -1 ].sample }
      }
    end

    # Tier 2: w_i = s_i · g[π_i]. Biaya O(n), isometrik terhadap g.
    #
    # @param global_vector [Array<Float>] g hasil {apply_global_rotation}
    # @param user_key [Hash] kunci dari {generate_user_key} (kunci String atau Symbol)
    # @return [Array<Float>] template Tier 2 (w)
    # @raise [ArgumentError] jika kunci tidak lengkap
    def tier2_transform(global_vector, user_key)
      perm  = user_key["permutation"] || user_key[:permutation]
      signs = user_key["signs"] || user_key[:signs]
      raise ArgumentError, "user_key tidak valid" unless perm && signs
      perm.each_index.map { |i| signs[i] * global_vector[perm[i]] }
    end

    # ==========================================================
    # Sketch Hamming 64 bit
    # ==========================================================

    # Ambang per-bit sketch (median tiap dimensi dari populasi enrollment),
    # dibaca dari file dan di-cache per proses.
    #
    # @return [Array<Float>] panjang SKETCH_BITS
    # @raise [RuntimeError] jika env belum diset atau jumlah angka salah
    def sketch_offsets
      @sketch_offsets ||= begin
        path = ENV["SKETCH_OFFSETS_PATH"] or raise "[ERROR] SKETCH_OFFSETS_PATH belum diset!"
        offs = JSON.parse(File.read(path)).map(&:to_f)
        raise "[ERROR] sketch_offsets harus #{SKETCH_BITS} angka, ada #{offs.length}" unless offs.length == SKETCH_BITS
        offs
      end
    end

    # Sketch = bit ke-j bernilai 1 bila g[j] >= offset[j] (SimHash dengan ambang
    # median agar bit seimbang). Dihitung dari vektor global g, bukan dari w.
    #
    # @param global_vector [Array<Float>]
    # @return [String] string "0"/"1" sepanjang SKETCH_BITS (cocok dengan tipe bit(64))
    def sketch(global_vector)
      offs = sketch_offsets
      (0...SKETCH_BITS).map { |j| global_vector[j] >= offs[j] ? "1" : "0" }.join
    end

    # Mengambil Top-K pengguna dengan jarak Hamming terkecil terhadap sketch query.
    # Perhitungan dilakukan di PostgreSQL: operator `#` (XOR bit) + bit_count().
    # Hasil di-materialisasi dengan `.to_a` karena `find_each` mengabaikan ORDER BY.
    #
    # @param sketch [String] sketch query (lihat {sketch})
    # @param limit [Integer] K (nilai evaluasi: 200)
    # @return [Array<User>] diurutkan menaik menurut jarak Hamming
    def sketch_candidates(sketch, limit:)
      order_sql = ActiveRecord::Base.sanitize_sql_array(
        [ "bit_count(sketch # CAST(? AS bit(#{SKETCH_BITS})))", sketch ]
      )
      User.where.not(sketch: nil)
          .select(:id, :name, :tier2_vector, :tier2_user_key)
          .order(Arel.sql(order_sql))
          .limit(limit)
          .to_a
    end

    # ==========================================================
    # Pencarian terinstrumentasi (mencatat PerformanceLog)
    # ==========================================================

    # Jalur presensi: sketch → Top-K Hamming → verifikasi cosine pada kandidat.
    # Waktu dipecah: probe_time_ms (SQL Hamming) dan fallback_time_ms (verifikasi
    # Tier 2: parse + dekripsi + cosine). Nama kolom `fallback_*` dipertahankan
    # demi kompatibilitas skema log; di jalur ini artinya "tahap verifikasi".
    #
    # @param event_type [String] mis. "attendance"
    # @param global_vector [Array<Float>] g hasil {apply_global_rotation}
    # @param k [Integer] jumlah kandidat Hamming
    # @param tau [Float] ambang cosine; match jika similarity >= tau (evaluasi: 0,60)
    # @return [Array(User, Float)] [pengguna terbaik atau nil, similarity terbaik]
    def search_sketch(event_type:, global_vector:, k:, tau:)
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      t0 = clock.call
      sk = sketch(global_vector)
      candidates = sketch_candidates(sk, limit: k)
      t1 = clock.call
      best_user, best_similarity = find_best_match(candidates, global_vector)
      t2 = clock.call

      PerformanceLog.create!(
        event_type: event_type, tier1_hash: sk, # kolom tier1_hash menyimpan sketch
        probe_candidate_count: candidates.size,
        probe_time_ms: ((t1 - t0) * 1000).round(4),
        fallback_time_ms: ((t2 - t1) * 1000).round(4),
        total_time_ms: ((t2 - t0) * 1000).round(4),
        used_fallback: false, fallback_candidate_count: 0,
        best_similarity: best_similarity.round(6),
        match_found: best_user.present? && best_similarity >= tau,
        matched_user_id: best_user&.id
      )
      [ best_user, best_similarity ]
    end

    # Jalur registrasi: cosine ke SEMUA pengguna terdaftar (tanpa sketch) agar
    # tidak ada akun ganda yang lolos. Gunakan tau_dedup <= tau presensi.
    #
    # @param event_type [String] mis. "registration_dedup"
    # @param global_vector [Array<Float>]
    # @param tau [Float]
    # @return [Array(User, Float)] [pengguna terbaik atau nil, similarity terbaik]
    def search_full_scan(event_type:, global_vector:, tau:)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      users = User.where.not(tier2_vector: nil).select(:id, :name, :tier2_vector, :tier2_user_key)
      best_user, best_similarity = find_best_match(users, global_vector)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(4)
      PerformanceLog.create!(
        event_type: event_type, total_time_ms: ms, probe_time_ms: 0.0, fallback_time_ms: ms,
        used_fallback: true, fallback_candidate_count: User.count,
        best_similarity: best_similarity.round(6),
        match_found: best_user.present? && best_similarity >= tau,
        matched_user_id: best_user&.id
      )
      [ best_user, best_similarity ]
    end

    # ==========================================================
    # Utilitas
    # ==========================================================

    # Normalisasi L2. Vektor nol dikembalikan apa adanya (hindari pembagian nol).
    #
    # @param vector [Array<Float>]
    # @return [Array<Float>]
    def l2_normalize(vector)
      magnitude = Math.sqrt(vector.sum { |x| x**2 })
      return vector if magnitude.zero?
      vector.map { |x| x / magnitude }
    end

    # Cosine similarity untuk dua vektor DIM-dimensi yang SUDAH ter-normalisasi L2,
    # sehingga cukup dot product. Loop `while` dipakai sengaja (lebih cepat dari
    # zip/sum pada jalur panas). Tidak memvalidasi panjang masukan.
    #
    # @param a [Array<Float>]
    # @param b [Array<Float>]
    # @return [Float]
    def cosine_similarity(a, b)
      dot = 0.0
      i = 0
      while i < DIM
        dot += a[i] * b[i]
        i += 1
      end
      dot
    end

    # Mencari kandidat dengan cosine tertinggi. Untuk tiap pengguna: ubah query
    # global g ke ruang Tier 2 miliknya (kunci pribadi), lalu bandingkan dengan
    # template tersimpan. Pengguna tanpa template/kunci dilewati.
    #
    # @param users [ActiveRecord::Relation, Array<User>]
    # @param global_vector [Array<Float>]
    # @return [Array(User, Float)] [best_user, best_similarity]; best_user nil jika
    #   tidak ada kandidat (similarity awal -1,0)
    def find_best_match(users, global_vector)
      best_user = nil
      best_similarity = -1.0

      each_record(users) do |candidate|
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

    private

    # Iterasi hemat memori: Relation memakai find_each (batch), Array memakai each.
    # Menggantikan monkey patch global `find_each_or_each` pada versi sebelumnya.
    def each_record(users, &block)
      users.respond_to?(:find_each) ? users.find_each(&block) : users.each(&block)
    end
  end
end