require 'mini_magick'
require 'base64'

class ImageQualityAnalyzer
  # tambahkan ke ImageQualityAnalyzer
  def self.analyze_file(path)
    image = MiniMagick::Image.open(path)
    {
      brightness: image["%[fx:mean*100]"].to_f.round(2),
      sharpness:  image["%[fx:standard_deviation*100]"].to_f.round(2)
    }
  rescue StandardError => e
    Rails.logger.error "[ImageQualityAnalyzer] #{path}: #{e.message}"
    nil
  end
  
  def self.analyze(base64_image)
    # 1. Bersihkan header Base64
    encoded_data = base64_image.include?(',') ? base64_image.split(',').last : base64_image
    decoded_data = Base64.decode64(encoded_data)

    # 2. Baca gambar ke memori
    image = MiniMagick::Image.read(decoded_data)

    # 3. Menggunakan pintasan pemanggilan properti bawaan MiniMagick
    # Ini secara otomatis mengeksekusi: identify -format "%[fx:...]"
    brightness = image["%[fx:mean*100]"].to_f
    sharpness = image["%[fx:standard_deviation*100]"].to_f

    {
      brightness: brightness.round(2),
      sharpness: sharpness.round(2)
    }
  rescue StandardError => e
    Rails.logger.error "[ImageQualityAnalyzer] Gagal menganalisis gambar: #{e.message}"
    { brightness: 50.0, sharpness: 50.0 }
  end
end