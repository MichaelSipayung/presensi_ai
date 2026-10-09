# lib/tasks/calibration.rake
require "json"
require "base64"
require "csv"
require "set"

module CalibrationHelper
  YALE_FILE = /_P00A([+-]\d+)E([+-]\d+)\.pgm\z/

  def self.lfw_root  = ENV.fetch("LFW_ROOT",  File.expand_path("~/datasets/lfw/lfw-deepfunneled/lfw-deepfunneled"))
  def self.yale_root = ENV.fetch("YALE_ROOT", File.expand_path("~/Downloads/extended_yale_b/cropped"))
  def self.cache_path = ENV.fetch("CACHE_PATH", Rails.root.join("tmp", "calibration_cache.jsonl").to_s)
  
  def self.plan
    entries = []

    Dir.children(lfw_root).sort.each do |name|
      dir = File.join(lfw_root, name)
      next unless File.directory?(dir)
      imgs = Dir.glob(File.join(dir, "*.jpg")).sort
      next if imgs.empty?
      entries << { dataset: "lfw", identity: name, role: "gallery", path: imgs[0] }
      entries << { dataset: "lfw", identity: name, role: "query", path: imgs[1] } if imgs.size >= 2
    end

    Dir.glob(File.join(yale_root, "yaleB*")).sort.each do |dir|
      next unless File.directory?(dir)
      name = File.basename(dir)
      frontal = Dir.glob(File.join(dir, "*.pgm")).filter_map do |f|
        m = File.basename(f).match(YALE_FILE)
        next unless m
        { path: f, az: m[1].to_i, el: m[2].to_i, angle: Math.hypot(m[1].to_f, m[2].to_f) }
      end
      ref = frontal.find { |x| x[:az].zero? && x[:el].zero? } or next
      entries << { dataset: "yale", identity: name, role: "gallery", path: ref[:path], light_angle: 0.0 }
      (frontal - [ref]).each do |x|
        entries << { dataset: "yale", identity: name, role: "query", path: x[:path], light_angle: x[:angle].round(1) }
      end
    end
    entries
  end

  # Jalur AMAN: baca file -> base64 -> extract_face (yang dihapus C++ hanya salinan di tmp/)
  def self.embed(path)
    res = FaceRecognitionService.extract_face(Base64.strict_encode64(File.binread(path)))
    return nil unless res[:success]
    v  = VectorRotationCipher.l2_normalize(FaceRecognitionService.hex_to_float_array(res[:embedding]))
    gv = VectorRotationCipher.apply_global_rotation(v)
    { embedding: v, proj16: gv.first(VectorRotationCipher::HASH_BITS) }
  end
end

namespace :calibration do
  desc "Ekstrak embedding+kualitas citra LFW & Yale B ke cache JSONL (resumable). ENV: LIMIT_PER_DATASET"
  task build_cache: :environment do
    entries = CalibrationHelper.plan
    if ENV["LIMIT_PER_DATASET"]
      n = ENV["LIMIT_PER_DATASET"].to_i
      entries = entries.group_by { |e| e[:dataset] }.values.flat_map { |a| a.first(n) }
    end

    path = CalibrationHelper.cache_path
    done = Set.new
    if File.exist?(path)
      File.foreach(path) do |l|
        begin
          done << JSON.parse(l)["path"]
        rescue JSON::ParserError
          nil
        end
      end
    end

    todo = entries.reject { |e| done.include?(e[:path]) }
    puts "[INFO] total=#{entries.size} sudah_cache=#{entries.size - todo.size} akan_diproses=#{todo.size}"

    ok = fail = 0
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    File.open(path, "a") do |f|
      todo.each_with_index do |e, i|
        begin
          emb = CalibrationHelper.embed(e[:path])
          q   = ImageQualityAnalyzer.analyze_file(e[:path])
          if emb.nil? || q.nil?
            fail += 1
          else
            f.puts(e.merge(emb).merge(brightness: q[:brightness], sharpness: q[:sharpness]).to_json)
            f.flush
            ok += 1
          end
        rescue => ex
          fail += 1
          warn "[GAGAL] #{e[:path]}: #{ex.message}"
        end
        if ((i + 1) % 50).zero?
          el  = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
          eta = el / (i + 1) * (todo.size - i - 1)
          puts "  [#{i + 1}/#{todo.size}] ok=#{ok} gagal=#{fail} ETA #{(eta / 60).round(1)} menit"
        end
      end
    end
    puts "[SELESAI] ok=#{ok} gagal=#{fail} -> #{path}"
  end

  desc "Analisis offline dari cache -> CSV + ringkasan. ENV: NEAR_ZERO (8), TAU (0.65)"
  task analyze: :environment do
    rows    = File.foreach(CalibrationHelper.cache_path).map { |l| JSON.parse(l) }
    key     = ->(r) { "#{r['dataset']}:#{r['identity']}" }
    gallery = rows.select { |r| r["role"] == "gallery" }
    gidx    = {}
    gallery.each_with_index { |g, j| gidx[key.(g)] = j }
    queries = rows.select { |r| r["role"] == "query" && gidx.key?(key.(r)) }
    n   = gallery.size
    nz  = (ENV["NEAR_ZERO"] || 8).to_i
    tau = (ENV["TAU"] || 0.65).to_f
    ks  = [ 50, 100, 200, 500, 1000, 2000 ]
    puts "[INFO] galeri=#{n} query=#{queries.size} near_zero=#{nz} tau=#{tau}"

    dot = lambda do |a, b|
      s = 0.0
      i = 0
      while i < 128
        s += a[i] * b[i]
        i += 1
      end
      s
    end
    to_int   = ->(proj) { proj.map { |x| x >= 0 ? "1" : "0" }.join.to_i(2) }
    popcount = Array.new(65_536) { |i| i.to_s(2).count("1") }
    g_emb    = gallery.map { |g| g["embedding"] }
    g_hash   = gallery.map { |g| to_int.(g["proj16"]) }

    # Cek isometri: cosine mentah harus == cosine setelah rotasi global + tier2
    if queries.any?
      a, b = queries.first["embedding"], g_emb.first
      uk = VectorRotationCipher.generate_user_key
      ta = VectorRotationCipher.tier2_transform(VectorRotationCipher.apply_global_rotation(a), uk)
      tb = VectorRotationCipher.tier2_transform(VectorRotationCipher.apply_global_rotation(b), uk)
      diff = (dot.(a, b) - VectorRotationCipher.cosine_similarity(ta, tb)).abs
      puts "[CEK ISOMETRI] selisih = #{diff}"
      abort "Isometri GAGAL, hentikan." if diff > 1e-9
    end

    out = []
    queries.each_with_index do |q, qi|
      qe   = q["embedding"]
      t    = gidx[key.(q)]
      sims = Array.new(n) { |j| dot.(qe, g_emb[j]) }
      genuine = sims[t]
      impostor_max = -2.0
      sims.each_with_index { |s, j| impostor_max = s if j != t && s > impostor_max }

      qh      = to_int.(q["proj16"])
      d       = Array.new(n) { |j| popcount[qh ^ g_hash[j]] }
      d_true  = d[t]
      rank_lo = d.count { |x| x < d_true } + 1
      rank_hi = d.count { |x| x <= d_true }

      _h, variants = VectorRotationCipher.tier1_hash_and_probes(q["proj16"], near_zero_count: nz)
      vset      = variants.map { |s| s.to_i(2) }.to_set
      probe_idx = (0...n).select { |j| vset.include?(g_hash[j]) }
      probe_j   = probe_idx.max_by { |j| sims[j] }

      # prefix-best sepanjang urutan Hamming (tie-break: urutan galeri, meniru urutan fisik tabel)
      order = (0...n).sort_by { |j| [ d[j], j ] }
      pm_sim = Array.new(n + 1, -2.0)
      pm_idx = Array.new(n + 1, -1)
      order.each_with_index do |j, pos|
        if sims[j] > pm_sim[pos]
          pm_sim[pos + 1] = sims[j]
          pm_idx[pos + 1] = j
        else
          pm_sim[pos + 1] = pm_sim[pos]
          pm_idx[pos + 1] = pm_idx[pos]
        end
      end

      row = {
        "dataset" => q["dataset"], "identity" => q["identity"], "light_angle" => q["light_angle"],
        "brightness" => q["brightness"], "sharpness" => q["sharpness"],
        "genuine_sim" => genuine.round(6), "impostor_max_sim" => impostor_max.round(6),
        "fullscan_correct" => genuine > impostor_max,
        "rank_lo" => rank_lo, "rank_hi" => rank_hi, "hamming_true" => d_true,
        "probe_hit" => vset.include?(g_hash[t]), "probe_n" => probe_idx.size,
        "probe_best_sim" => (probe_j ? sims[probe_j].round(6) : -1.0),
        "probe_best_correct" => (probe_j == t)
      }
      ks.each do |k|
        kk = [ k, n ].min
        row["k#{k}_correct"]  = (pm_idx[kk] == t)
        row["k#{k}_best_sim"] = pm_sim[kk].round(6)
      end
      out << row
      puts "  [#{qi + 1}/#{queries.size}]" if ((qi + 1) % 200).zero?
    end

    csv_path = Rails.root.join("tmp", "calibration_results_#{Time.now.strftime('%Y%m%d_%H%M%S')}.csv")
    CSV.open(csv_path, "w") do |csv|
      csv << out.first.keys
      out.each { |r| csv << r.values }
    end
    puts "\n[SUKSES] #{out.size} baris -> #{csv_path}"

    pct = ->(arr, p) { s = arr.sort; s[((s.size - 1) * p).round] }
    summarize = lambda do |label, rs|
      next if rs.empty?
      m   = rs.size.to_f
      gen = rs.map { |r| r["genuine_sim"] }
      imp = rs.map { |r| r["impostor_max_sim"] }
      puts "\n== #{label} (n=#{rs.size}) =="
      puts format("genuine  p10/p50/p90: %.3f / %.3f / %.3f", pct.(gen, 0.1), pct.(gen, 0.5), pct.(gen, 0.9))
      puts format("impostor p10/p50/p90: %.3f / %.3f / %.3f", pct.(imp, 0.1), pct.(imp, 0.5), pct.(imp, 0.9))
      puts format("FRR@%.2f = %.1f%%   FAR(open-set)@%.2f = %.1f%%", tau, rs.count { |r| r["genuine_sim"] < tau } / m * 100, tau, rs.count { |r| r["impostor_max_sim"] >= tau } / m * 100)
      full = rs.count { |r| r["fullscan_correct"] && [ r["genuine_sim"], r["impostor_max_sim"] ].max >= tau }
      puts format("Full scan sukses     : %.1f%%", full / m * 100)
      puts format("Probe-hit (hash true masuk varian probe): %.1f%%", rs.count { |r| r["probe_hit"] } / m * 100)
      ks.each do |k|
        ok = rs.count do |r|
          if r["probe_best_sim"] >= tau
            r["probe_best_correct"]
          else
            r["k#{k}_correct"] && r["k#{k}_best_sim"] >= tau
          end
        end
        puts format("Sistem (probe -> K=%-4d): %.1f%%", k, ok / m * 100)
      end
    end

    summarize.("SEMUA", out)
    out.group_by { |r| r["dataset"] }.each { |ds, rs| summarize.(ds.upcase, rs) }

    puts "\n== SWEEP THRESHOLD (FRR% / FAR%) =="
    out.group_by { |r| r["dataset"] }.each do |ds, rs|
      m = rs.size.to_f
      line = (50..80).step(5).map do |t|
        th = t / 100.0
        format("%.2f: %.0f/%.0f", th, rs.count { |r| r["genuine_sim"] < th } / m * 100, rs.count { |r| r["impostor_max_sim"] >= th } / m * 100)
      end
      puts "#{ds.upcase}  #{line.join('  ')}"
    end
  end

  desc "Offset median sketch dari galeri cache. ENV: BITS(64)"
  task fit_sketch_offsets: :environment do
    bits = (ENV["BITS"] || 64).to_i
    gal  = File.foreach(CalibrationHelper.cache_path).map { |l| JSON.parse(l) }.select { |r| r["role"] == "gallery" }
    rot  = gal.map { |r| VectorRotationCipher.apply_global_rotation(r["embedding"]) }
    offs = (0...bits).map do |j|
      col = rot.map { |g| g[j] }.sort
      (col[(col.size - 1) / 2] + col[col.size / 2]) / 2.0
    end
    path = Rails.root.join("config", "secrets", "sketch_offsets.json")
    File.write(path, offs.to_json)
    puts "[SUKSES] #{bits} offset dari #{gal.size} galeri -> #{path}"
  end
end