require "csv"
require "json"
require "set"

namespace :report do
  desc "Ekspor data per-query dan rencana untuk laporan jurnal. ENV: BITS(64) SAMPLE"
  task export_queries: :environment do
    bits  = (ENV["BITS"] || 64).to_i
    abort "BITS harus kelipatan 16" unless (bits % 16).zero?
    ks    = [ 50, 100, 200, 500 ]
    sizes = [ 500, 1000, 2000, 4000 ]

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
    zeros = Array.new(bits, 0.0)
    pop   = Array.new(65_536) { |i| i.to_s(2).count("1") }
    chunks = lambda do |g, o, nbits|
      (0...(nbits / 16)).map do |c|
        v = 0
        16.times { |i| v = (v << 1) | ((g[c * 16 + i] - o[c * 16 + i]) >= 0 ? 1 : 0) }
        v
      end
    end
    nc    = bits / 16
    g_c64 = g_rot.map { |g| chunks.(g, offs, bits) }
    g_c16 = g_rot.map { |g| chunks.(g, zeros, 16)[0] }   # desain awal: 16 bit, ambang 0
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

    perm_pos = Array.new(n)
    (0...n).to_a.shuffle(random: Random.new(3)).each_with_index { |j, pos| perm_pos[j] = pos }

    head  = %w[dataset identity light_angle brightness sharpness n_gallery genuine imp_max rank16 rank64]
    head += sizes.map { |s| "imp_max_n#{s}" } + sizes.map { |s| "rank64_n#{s}" }
    ks.each { |k| head += [ "k#{k}_ok", "k#{k}_sim" ] }
    kcap = [ ks.max, n ].min

    CSV.open(Rails.root.join("tmp", "report_queries.csv"), "w") do |csv|
      csv << head
      qs.each_with_index do |q, qi|
        qe   = q["embedding"]
        t    = gidx[key.(q)]
        sims = Array.new(n) { |j| dot.(qe, g_emb[j]) }
        genuine = sims[t]
        qc64 = chunks.(q_rot[qi], offs, bits)
        qc16 = chunks.(q_rot[qi], zeros, 16)[0]
        d64 = Array.new(n) do |j|
          s = 0
          gj = g_c64[j]
          c = 0
          while c < nc
            s += pop[qc64[c] ^ gj[c]]
            c += 1
          end
          s
        end
        d16 = Array.new(n) { |j| pop[qc16 ^ g_c16[j]] }
        dt64 = d64[t]
        dt16 = d16[t]

        imp_all = -2.0
        imp_n   = Array.new(sizes.size, -2.0)
        rank16  = 1
        rank64  = 1
        rank_n  = Array.new(sizes.size, 1)
        n.times do |j|
          next if j == t
          s = sims[j]
          imp_all = s if s > imp_all
          rank16 += 1 if d16[j] <= dt16
          hit = d64[j] <= dt64
          rank64 += 1 if hit
          pos = perm_pos[j]
          sizes.each_with_index do |sz, si|
            next unless pos < sz
            imp_n[si] = s if s > imp_n[si]
            rank_n[si] += 1 if hit
          end
        end

        order = (0...n).sort_by { |j| d64[j] * n + j }.first(kcap)
        pm_s = []
        pm_i = []
        best_s = -2.0
        best_i = -1
        order.each do |j|
          if sims[j] > best_s
            best_s = sims[j]
            best_i = j
          end
          pm_s << best_s
          pm_i << best_i
        end

        row  = [ q["dataset"], q["identity"], q["light_angle"], q["brightness"], q["sharpness"], n,
                 genuine.round(6), imp_all.round(6), rank16, rank64 ]
        row += imp_n.map { |x| x.round(6) } + rank_n
        ks.each { |k| row += [ (pm_i[k - 1] == t ? 1 : 0), pm_s[k - 1].round(6) ] }
        csv << row
        puts "  [#{qi + 1}/#{qs.size}]" if ((qi + 1) % 300).zero?
      end
    end

    cached = Set.new(File.foreach(CalibrationHelper.cache_path).map { |l| JSON.parse(l)["path"] })
    plan   = CalibrationHelper.plan
    gal_ok = Set.new(plan.select { |e| e[:role] == "gallery" && cached.include?(e[:path]) }.map { |e| "#{e[:dataset]}:#{e[:identity]}" })
    CSV.open(Rails.root.join("tmp", "report_plan.csv"), "w") do |csv|
      csv << %w[dataset identity role light_angle detected gallery_ok]
      plan.each do |e|
        csv << [ e[:dataset], e[:identity], e[:role], e[:light_angle],
                 (cached.include?(e[:path]) ? 1 : 0), (gal_ok.include?("#{e[:dataset]}:#{e[:identity]}") ? 1 : 0) ]
      end
    end
    puts "[SELESAI] tmp/report_queries.csv dan tmp/report_plan.csv"
  end
end