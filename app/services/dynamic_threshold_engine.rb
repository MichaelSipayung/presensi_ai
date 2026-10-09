class DynamicThresholdEngine
  # Parameter Baseline (Kondisi Normal)
  BASE_K = 500
  BASE_THRESHOLD = 0.650

  def self.calculate(brightness_score, sharpness_score)
    # Skenario 1: Iluminasi Ekstrem (Seperti Kasus Yale B yang gagal kemarin)
    # Jika kecerahan di bawah 30% (terlalu gelap) atau di atas 85% (backlight silau)
    if brightness_score < 30.0 || brightness_score > 85.0
      return {
        k_limit: 1500,        # Lebarkan jaring pencarian untuk menangani mutasi Hash
        threshold: 0.680,     # Perketat Satpam agar wajah orang asing tidak lolos
        status: "Extreme Illumination"
      }
    end

    # Skenario 2: Gambar Buram / Kamera Bergerak (Blur)
    if sharpness_score < 15.0
      return {
        k_limit: 800,
        threshold: 0.665,
        status: "Low Sharpness / Blurred"
      }
    end

    # Skenario 3: Kondisi Ideal (Kamera terang, wajah jelas)
    {
      k_limit: BASE_K,
      threshold: BASE_THRESHOLD,
      status: "Normal"
    }
  end
end