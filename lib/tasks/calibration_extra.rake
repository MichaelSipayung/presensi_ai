namespace :calibration do
  desc "Evaluasi kebijakan akhir. ENV: BITS(64) SAMPLE KSEL(100) TAU(0.65)"
  task system_eval: :environment do
    bits = (ENV["BITS"] || 64).to_i
    ksel = (ENV["KSEL"] || 100).to_i
    tau0 = (ENV["TAU"] || 0.65).to_f
    ks   = [ 50, 100, 200, 500 ]
    taus = [ 0.55, 0.60, 0.65 ]
    abort "KSEL harus salah satu dari #{ks}" unless ks.include?(ksel)
    abort "BITS harus kelipatan 16" unless (bits % 16).zero?

    rows = File.foreach(CalibrationHelper.cache_path).map { |l| JSON.parse(l) }
    key  = ->(r) { "#{r['dataset']}:#{r['identity']}" }
    gal  = rows.select { |r| r["role"] == "gallery" }
    gidx = {}
    gal.each_with_index { |g, j| gidx[key.(g)] = j }
    qs = rows.select { |r| r["role"] == "query" && gidx.key?(key.(r)) }
    qs = qs.sample(ENV["SAMPLE"].to_i, random: Random.new(1)) if ENV["SAMPLE"]
    n  = gal.size
    puts "[INFO] galeri=#{n} query=#{qs.size} sketch=#{bits} bit"

    rot   = ->(r) { VectorRotationCipher.apply_global_rotation(r["embedding"]) }
    g_rot = gal.map(&rot)
    q_rot = qs.map(&rot)
    offs  = (0...bits).map do |j|
      col = g_rot.map { |g| g[j] }.sort
      (col[(n - 1) / 2] + col[n / 2]) / 2.0
    end
    pop = Array.new(65_536) { |i| i.to_s(2).count("1") }
    nc  = bits / 16
    chunks = lambda do |g|
      (0...nc).map do |c|
        v = 0
        16.times { |i| v = (v << 1) | ((g[c * 16 + i] - offs[c * 16 + i]) >= 0 ? 1 : 0) }
        v
      end
    end
    g_ch  = g_rot.map(&chunks)
    g_emb = gal.map { |g| g["embedding"] }
    dot = lambda do |a, b|
      s = 0.0
      i = 0
      while i < 128
        s += a[i] * b[i]
        i += 1
      end
      s
    end

    kmax = ks.max
    res  = []
    qs.each_with_index do |q, qi|
      qe = q["embedding"]
      t  = gidx[key.(q)]
      qc = chunks.(q_rot[qi])
      dist = Array.new(n) do |j|
        s = 0
        gj = g_ch[j]
        c = 0
        while c < nc
          s += pop[qc[c] ^ gj[c]]
          c += 1
        end
        s
      end
      order  = (0...n).sort_by { |j| dist[j] * n + j }.first(kmax)
      byk    = {}
      best_i = -1
      best_s = -2.0
      order.each_with_index do |j, pos|
        s = dot.(qe, g_emb[j])
        if s > best_s
          best_s = s
          best_i = j
        end
        byk[pos + 1] = [ best_i, best_s ] if ks.include?(pos + 1)
      end
      fi = -1
      fs = -2.0
      n.times do |j|
        s = dot.(qe, g_emb[j])
        if s > fs
          fs = s
          fi = j
        end
      end
      res << { ds: q["dataset"], ang: q["light_angle"], t: t, full: [ fi, fs ], byk: byk }
      puts "  [#{qi + 1}/#{qs.size}]" if ((qi + 1) % 300).zero?
    end

    outcome = lambda do |r, policy, tau|
      i, s = (policy == :full ? r[:full] : r[:byk][policy])
      next :reject if s < tau
      i == r[:t] ? :ok : :misid
    end

    res.group_by { |r| r[:ds] }.each do |ds, rs|
      puts "\n== #{ds.upcase} (n=#{rs.size}, hanya gambar yang wajahnya terdeteksi) =="
      puts format("%-14s %-5s %8s %9s %8s", "kebijakan", "tau", "benar", "salah-id", "ditolak")
      (ks + [ :full ]).each do |pol|
        taus.each do |tau|
          c = rs.map { |r| outcome.(r, pol, tau) }.tally
          m = rs.size.to_f
          puts format("%-14s %-5.2f %7.1f%% %8.1f%% %7.1f%%",
                      (pol == :full ? "full scan" : "sketch K=#{pol}"), tau,
                      (c[:ok] || 0) / m * 100, (c[:misid] || 0) / m * 100, (c[:reject] || 0) / m * 100)
        end
      end
    end

    plan_q = CalibrationHelper.plan.select { |e| e[:dataset] == "yale" && e[:role] == "query" }
    bin    = ->(a) { (a / 20).floor * 20 }
    elig   = plan_q.group_by { |e| bin.(e[:light_angle]) }
    got    = res.select { |r| r[:ds] == "yale" }.group_by { |r| bin.(r[:ang].to_f) }
    puts "\n== YALE end-to-end per sudut cahaya (tau=#{tau0}); FTA = wajah tidak terdeteksi =="
    puts format("%-9s %6s %7s %11s %16s", "sudut", "total", "FTA", "full scan", "sketch K=#{ksel}")
    elig.sort.each do |b, es|
      rs  = got[b] || []
      fta = (1 - rs.size.to_f / es.size) * 100
      okf = rs.count { |r| outcome.(r, :full, tau0) == :ok }
      okk = rs.count { |r| outcome.(r, ksel, tau0) == :ok }
      puts format("%3d-%3d°  %6d %6.1f%% %10.1f%% %15.1f%%", b, b + 19, es.size, fta, okf * 100.0 / es.size, okk * 100.0 / es.size)
    end
  end

   desc "Recall sketch pada K tetap vs ukuran galeri (subsampling dari cache). ENV: BITS(64)"
  task recall_vs_gallery_size: :environment do
    bits = (ENV["BITS"] || 64).to_i
    rows = File.foreach(CalibrationHelper.cache_path).map { |l| JSON.parse(l) }
    key  = ->(r) { "#{r['dataset']}:#{r['identity']}" }
    gal  = rows.select { |r| r["role"] == "gallery" }
    gidx = {}
    gal.each_with_index { |g, j| gidx[key.(g)] = j }
    qs = rows.select { |r| r["role"] == "query" && gidx.key?(key.(r)) }
    n  = gal.size
    nc = bits / 16
    sizes = [ 500, 1000, 2000, 4000, n ]
    ks    = [ 50, 100, 200, 500 ]
    puts "[INFO] galeri=#{n} query=#{qs.size} sketch=#{bits} bit"

    rot   = ->(r) { VectorRotationCipher.apply_global_rotation(r["embedding"]) }
    g_rot = gal.map(&rot)
    q_rot = qs.map(&rot)
    offs  = (0...bits).map do |j|
      col = g_rot.map { |g| g[j] }.sort
      (col[(n - 1) / 2] + col[n / 2]) / 2.0
    end
    pop = Array.new(65_536) { |i| i.to_s(2).count("1") }
    chunks = lambda do |g|
      (0...nc).map do |c|
        v = 0
        16.times { |i| v = (v << 1) | ((g[c * 16 + i] - offs[c * 16 + i]) >= 0 ? 1 : 0) }
        v
      end
    end
    g_ch = g_rot.map(&chunks)

    perm_pos = Array.new(n)
    (0...n).to_a.shuffle(random: Random.new(3)).each_with_index { |j, pos| perm_pos[j] = pos }

    results = Hash.new { |h, ds| h[ds] = Hash.new { |h2, sz| h2[sz] = [] } }
    qs.each_with_index do |q, qi|
      t  = gidx[key.(q)]
      qc = chunks.(q_rot[qi])
      dist = Array.new(n) do |j|
        s = 0
        gj = g_ch[j]
        c = 0
        while c < nc
          s += pop[qc[c] ^ gj[c]]
          c += 1
        end
        s
      end
      dt = dist[t]
      sizes.each do |sz|
        r = 1
        j = 0
        while j < n
          r += 1 if j != t && perm_pos[j] < sz && dist[j] <= dt
          j += 1
        end
        results[q["dataset"]][sz] << r
      end
      puts "  [#{qi + 1}/#{qs.size}]" if ((qi + 1) % 500).zero?
    end

    pct = ->(a, p) { s = a.sort; s[((s.size - 1) * p).round] }
    results.each do |ds, by_size|
      puts "\n== #{ds.upcase} (n=#{by_size[sizes.last].size}) | recall@K sketch #{bits}-bit vs ukuran galeri =="
      puts format("%-7s %8s %8s %8s %8s %9s", "N", *ks.map { |k| "@#{k}" }, "rank p95")
      sizes.each do |sz|
        r = by_size[sz]
        m = r.size.to_f
        puts format("%-7d %7.1f%% %7.1f%% %7.1f%% %7.1f%% %9d", sz, *ks.map { |k| r.count { |x| x <= k } / m * 100 }, pct.(r, 0.95))
      end
    end
  end
  
end