# lib/tasks/extraction_benchmark.rake
# Ukur latensi ekstraksi (YuNet + SFace via C++), normalisasi+rotasi, dan sketch.
# Jalankan dua kali:
#   rails performance:extraction_benchmark
#   taskset -c 0 rails performance:extraction_benchmark     # batasi 1 CPU
# ENV: N (200) jumlah pengukuran, WARMUP (5), IMG_DIR (opsional)
require "base64"

module ExtractionBench
  def self.pct(arr, p)
    s = arr.sort
    s[((s.size - 1) * p).round]
  end

  def self.line(label, arr_ms)
    format("%-28s p50=%7.2f  p95=%7.2f  p99=%7.2f  mean=%7.2f ms",
           label, pct(arr_ms, 0.50), pct(arr_ms, 0.95), pct(arr_ms, 0.99), arr_ms.sum / arr_ms.size)
  end

  def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def self.rss_mb
    File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i / 1024.0
  rescue
    nil
  end
end

namespace :performance do
  desc "Benchmark latensi ekstraksi wajah end-to-end. ENV: N WARMUP IMG_DIR"
  task extraction_benchmark: :environment do
    n      = (ENV["N"] || 200).to_i
    warmup = (ENV["WARMUP"] || 5).to_i

    paths =
      if ENV["IMG_DIR"]
        Dir.glob(File.join(ENV["IMG_DIR"], "*.{jpg,jpeg,png,pgm}")).sort
      else
        CalibrationHelper.plan.select { |e| e[:dataset] == "lfw" }.map { |e| e[:path] }
      end
    abort "Tidak ada gambar." if paths.empty?
    paths = paths.first(n + warmup)
    # extract_face menerima base64; yang dihapus C++ hanya salinan di tmp/, bukan file asli.
    b64s = paths.map { |p| Base64.strict_encode64(File.binread(p)) }

    cpus = (File.read("/proc/self/status")[/Cpus_allowed_list:\s*(\S+)/, 1] rescue "?")
    puts "[INFO] gambar=#{b64s.size} warmup=#{warmup} Cpus_allowed_list=#{cpus} nproc=#{`nproc`.strip}"

    t_extract = []
    t_norm    = []
    t_sketch  = []
    t_total   = []
    fta       = 0

    b64s.each_with_index do |b64, i|
      t0  = ExtractionBench.now
      res = FaceRecognitionService.extract_face(b64)
      t1  = ExtractionBench.now
      unless res[:success]
        fta += 1 if i >= warmup
        next
      end
      v   = VectorRotationCipher.l2_normalize(FaceRecognitionService.hex_to_float_array(res[:embedding]))
      g   = VectorRotationCipher.apply_global_rotation(v)
      t2  = ExtractionBench.now
      VectorRotationCipher.sketch(g)
      t3  = ExtractionBench.now

      next if i < warmup
      t_extract << (t1 - t0) * 1000
      t_norm    << (t2 - t1) * 1000
      t_sketch  << (t3 - t2) * 1000
      t_total   << (t3 - t0) * 1000
    end

    abort "Semua ekstraksi gagal." if t_total.empty?
    puts
    puts "== LATENSI (n=#{t_total.size}, FTA=#{fta}) =="
    puts ExtractionBench.line("extract_face (C++ YuNet+SFace)", t_extract)
    puts ExtractionBench.line("normalisasi + rotasi Tier 1", t_norm)
    puts ExtractionBench.line("sketch 64 bit", t_sketch)
    puts ExtractionBench.line("TOTAL sisi klien/edge", t_total)
    rss = ExtractionBench.rss_mb
    puts format("\nRSS proses Rails: %.0f MB", rss) if rss
    puts "Throughput (p50): #{(1000.0 / ExtractionBench.pct(t_total, 0.5)).round(2)} wajah/detik"
  end
end