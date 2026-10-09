# app/services/fuzzy_threshold_engine.rb
class FuzzyThresholdEngine
  # ============================================================
  # FUNGSI KEANGGOTAAN (Membership Functions)
  # ============================================================
  def self.triangular(x, a, b, c)
    return 0.0 if x <= a || x >= c
    return (x - a) / (b - a).to_f if x <= b
    (c - x) / (c - b).to_f
  end

  def self.trapezoidal(x, a, b, c, d)
    return 0.0 if x <= a || x >= d
    return (x - a) / (b - a).to_f if x < b
    return 1.0 if x <= c
    (d - x) / (d - c).to_f
  end

  # ---- Brightness ----
  def self.mu_dark(x)     = trapezoidal(x, 0, 0, 15, 35)
  def self.mu_normal_b(x) = triangular(x, 20, 50, 80)
  def self.mu_bright(x)   = trapezoidal(x, 65, 85, 100, 100)

  # ---- Sharpness ----
  def self.mu_blurred(x)  = trapezoidal(x, 0, 0, 8, 20)
  def self.mu_normal_s(x) = triangular(x, 12, 30, 50)
  def self.mu_sharp(x)    = trapezoidal(x, 35, 50, 100, 100)

  # ============================================================
  # Fungsi keanggotaan OUTPUT (dipakai saat agregasi & defuzzifikasi)
  # ============================================================
  # def self.mu_k_low(z)    = triangular(z, 50, 100, 300)
  # def self.mu_k_medium(z) = triangular(z, 200, 500, 900)
  # def self.mu_k_high(z)   = triangular(z, 700, 1500, 2000)
  # setelah benchmark 
  # # K-Limit digeser lebih besar karena K=500 ternyata kurang untuk Yale B (FRR masih 14%)
  def self.mu_k_low(z)    = triangular(z, 300, 500, 800)
  def self.mu_k_medium(z) = triangular(z, 600, 1000, 1500)
  def self.mu_k_high(z)   = triangular(z, 1200, 2000, 2500)

  # def self.mu_t_lenient(z) = triangular(z, 0.60, 0.620, 0.645)
  # def self.mu_t_normal(z)  = triangular(z, 0.630, 0.650, 0.670)
  # def self.mu_t_strict(z)  = triangular(z, 0.655, 0.680, 0.700)
  # setelah benchmark
  # Threshold diturunkan ke area 0.58 - 0.62 untuk menekan False Rejection Rate (FRR)
  # yang sebelumnya mencapai 42% pada dataset liar (LFW)
  def self.mu_t_lenient(z) = triangular(z, 0.56, 0.58, 0.60)
  def self.mu_t_normal(z)  = triangular(z, 0.59, 0.60, 0.62)
  def self.mu_t_strict(z)  = triangular(z, 0.61, 0.63, 0.65)
  # ============================================================
  # BASIS ATURAN -- mengembalikan [firing_strength, k_label, t_label]
  # ============================================================
  RULES = [
    [:mu_dark,     :mu_blurred,  :mu_k_high,   :mu_t_strict],
    [:mu_dark,     :mu_normal_s, :mu_k_high,   :mu_t_normal],
    [:mu_dark,     :mu_sharp,    :mu_k_medium, :mu_t_normal],
    [:mu_normal_b, :mu_blurred,  :mu_k_medium, :mu_t_normal],
    [:mu_normal_b, :mu_normal_s, :mu_k_low,    :mu_t_normal],
    [:mu_normal_b, :mu_sharp,    :mu_k_low,    :mu_t_lenient],
    [:mu_bright,   :mu_blurred,  :mu_k_high,   :mu_t_strict],
    [:mu_bright,   :mu_normal_s, :mu_k_medium, :mu_t_normal],
    [:mu_bright,   :mu_sharp,    :mu_k_medium, :mu_t_normal],
  ].freeze

  # ============================================================
  # INFERENSI MAMDANI + DEFUZZIFIKASI CENTROID
  # ============================================================
  def self.calculate(brightness_score, sharpness_score)
      firing_strengths = RULES.map do |b_fn, s_fn, k_fn, t_fn|
        mu_b = send(b_fn, brightness_score)
        mu_s = send(s_fn, sharpness_score)
        strength = [mu_b, mu_s].min
        [strength, k_fn, t_fn]
      end

      # PERBAIKAN DOMAIN: K diekspansi hingga 2500 (sesuai mu_k_high)
      k_limit = defuzzify_centroid(firing_strengths.map { |s, k, _| [s, k] }, (50..2500).step(10).to_a)
      
      # PERBAIKAN DOMAIN: Threshold diekspansi ke 0.50 - 0.70 agar lenient (0.56-0.60) masuk hitungan
      threshold = defuzzify_centroid(firing_strengths.map { |s, _, t| [s, t] }, (0.50..0.70).step(0.001).to_a)

      {
        k_limit: k_limit.round,
        threshold: threshold.round(4),
        status: dominant_status(firing_strengths)
      }
    end

  # Centroid method: agregasi via MAX antar aturan yang menunjuk ke label output sama,
  # lalu hitung titik berat (centroid) dari kurva hasil agregasi
  def self.defuzzify_centroid(strength_and_output_fns, domain)
    numerator = 0.0
    denominator = 0.0

    domain.each do |z|
      # Agregasi MAX: untuk tiap titik z, ambil nilai keanggotaan tertinggi
      # di antara semua aturan yang aktif (firing_strength terpotong oleh fungsi output)
      mu_agg = strength_and_output_fns.map { |strength, output_fn|
        [strength, send(output_fn, z)].min  # clipping (implikasi Mamdani)
      }.max

      numerator += z * mu_agg
      denominator += mu_agg
    end

    denominator.zero? ? (domain.first + domain.last) / 2.0 : numerator / denominator
  end

  def self.dominant_status(firing_strengths)
    strongest = firing_strengths.max_by { |s, _, _| s }
    return "Normal" if strongest[0] < 0.3
    "Adaptive (rule-based fuzzy inference)"
  end
end