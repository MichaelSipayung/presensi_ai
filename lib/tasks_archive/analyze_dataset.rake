namespace :performance do
  desc "Menganalisis distribusi kecerahan dan ketajaman seluruh dataset Yale B"
  task :analyze_dataset, [:dir_path] => :environment do |t, args|
    dir_path = args[:dir_path] || "/home/hannah/Downloads/extended_yale_b/cropped"
    
    unless Dir.exist?(dir_path)
    puts "[ERROR] Direktori tidak ditemukan: #{dir_path}"
      exit
    end

    total_images = 0
    extreme_dark = 0
    normal_count = 0
    min_bright = 100.0
    max_bright = 0.0

    puts "[INFO] Memulai pemindaian seluruh gambar di #{dir_path}..."

    # Iterasi semua subfolder subjek (yaleB11, yaleB12, dll)
    Dir.glob("#{dir_path}/**/*.pgm").each do |file_path|
      total_images += 1
      
      begin
        # Baca file langsung sebagai base64 untuk dianalisis analyzer kita
        base64_str = Base64.strict_encode64(File.binread(file_path))
        base64_image = "data:image/jpeg;base64,#{base64_str}"

        quality = ImageQualityAnalyzer.analyze(base64_image)
        b = quality[:brightness]

        min_bright = b if b < min_bright
        max_bright = b if b > max_bright

        decision = DynamicThresholdEngine.calculate(b, quality[:sharpness])
        
        if decision[:status].include?("Extreme")
          extreme_dark += 1
        else
          normal_count += 1
        end
      rescue => e
        # Lewati jika ada file corrupt
        next
      end

      # Cetak progress tiap 100 gambar
      print "." if total_images % 100 == 0
    end

    puts "\n\n=== HASIL ANALISIS DATASET EXTENDED YALE B ==="
    puts "Total Gambar Dipindai  : #{total_images}"
    puts "Kecerahan Minimum      : #{min_bright.round(2)}%"
    puts "Kecerahan Maksimum     : #{max_bright.round(2)}%"
    puts "Kategori Normal        : #{normal_count} (#{((normal_count.to_f/total_images)*100).round(2)}%)"
    puts "Kategori Extreme Illum : #{extreme_dark} (#{((extreme_dark.to_f/total_images)*100).round(2)}%)"
    puts "============================================="
  end
end