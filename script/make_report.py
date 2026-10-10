#!/usr/bin/env python3
"""Laporan hasil untuk manuskrip.
Pemakaian: python3 script/make_report.py [report_queries.csv] [report_plan.csv] [folder_keluaran]
Hanya memakai pustaka standar Python; matplotlib (opsional) dipakai untuk gambar."""
import bisect
import csv
import math
import os
import sys

Q = sys.argv[1] if len(sys.argv) > 1 else "tmp/report_queries.csv"
P = sys.argv[2] if len(sys.argv) > 2 else "tmp/report_plan.csv"
OUT = sys.argv[3] if len(sys.argv) > 3 else "tmp/laporan"

TAU0, K0 = 0.60, 200            # titik operasi yang dipakai aplikasi
TAUS = [0.55, 0.60, 0.65]
KS = [50, 100, 200, 500]
SIZES = [500, 1000, 2000, 4000]
# Hasil performance:sketch_benchmark (K=200): N, SQL p50, SQL p95, Tier2 p50, Tier2 p95, total p50, total p95 (ms)
LATENCY = [
    (5739, 8.5, 13.1, 21.9, 31.2, 30.7, 42.6),
    (57129, 31.6, 40.8, 19.9, 24.0, 51.9, 65.3),
    (102809, 47.0, 60.1, 21.4, 29.9, 69.6, 86.9),
]
FULLSCAN_P50_MS, FULLSCAN_N = 725.1, 5739   # full scan terukur hanya pada N ini

os.makedirs(OUT, exist_ok=True)


# ---------------------------------------------------------------- utilitas
def load(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            for k, v in list(r.items()):
                if k in ("dataset", "identity", "role"):
                    continue
                if v is None or v == "":
                    r[k] = None
                else:
                    try:
                        r[k] = float(v)
                    except ValueError:
                        pass
            rows.append(r)
    return rows


def wilson(k, n, z=1.96):
    if n == 0:
        return float("nan"), float("nan"), float("nan")
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return p, max(0.0, c - h), min(1.0, c + h)


def fmt(k, n):
    p, lo, hi = wilson(k, n)
    return f"{100 * p:.1f}% [{100 * lo:.1f}–{100 * hi:.1f}]"


def mcnemar(b, c):
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def ranks(x):
    idx = sorted(range(len(x)), key=lambda i: x[i])
    r = [0.0] * len(x)
    i = 0
    while i < len(x):
        j = i
        while j + 1 < len(x) and x[idx[j + 1]] == x[idx[i]]:
            j += 1
        avg = (i + j) / 2 + 1
        for t in range(i, j + 1):
            r[idx[t]] = avg
        i = j + 1
    return r


def pearson(a, b):
    ma, mb = sum(a) / len(a), sum(b) / len(b)
    sa = math.sqrt(sum((x - ma) ** 2 for x in a))
    sb = math.sqrt(sum((y - mb) ** 2 for y in b))
    if sa == 0 or sb == 0:
        return 0.0
    return sum((x - ma) * (y - mb) for x, y in zip(a, b)) / (sa * sb)


def spearman_ci(x, y):
    rho = pearson(ranks(x), ranks(y))
    n = len(x)
    if n < 10 or abs(rho) > 0.9999:
        return rho, float("nan"), float("nan")
    se = math.sqrt((1 + rho * rho / 2) / (n - 3))      # Bonett & Wright (2000)
    z = math.atanh(rho)
    return rho, math.tanh(z - 1.96 * se), math.tanh(z + 1.96 * se)


def pctl(a, p):
    s = sorted(a)
    return s[round((len(s) - 1) * p)]


def abin(a):
    return int(a // 20) * 20


def outcome(ok, sim, tau):
    if sim < tau:
        return "reject"
    return "ok" if ok else "misid"


def full_outcome(r, tau):
    return outcome(r["genuine"] > r["imp_max"], max(r["genuine"], r["imp_max"]), tau)


def k_outcome(r, k, tau):
    return outcome(r[f"k{k}_ok"] == 1, r[f"k{k}_sim"], tau)


md = []


def H(title, lvl=2):
    md.append("\n" + "#" * lvl + " " + title + "\n")


def T(name, headers, rows, note=None):
    md.append("| " + " | ".join(headers) + " |")
    md.append("|" + "---|" * len(headers))
    for r in rows:
        md.append("| " + " | ".join(str(x) for x in r) + " |")
    md.append("")
    if note:
        md.append(note + "\n")
    with open(os.path.join(OUT, name + ".csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(headers)
        w.writerows(rows)


# ---------------------------------------------------------------- data
qs = load(Q)
plan = load(P)
NG = int(max(r["n_gallery"] for r in qs))
G = {"LFW": [r for r in qs if r["dataset"] == "lfw"], "YALE": [r for r in qs if r["dataset"] == "yale"]}

md.append("# Laporan hasil (dibangkitkan otomatis)\n")
md.append(f"Galeri = {NG} identitas; query = {len(qs)} (LFW {len(G['LFW'])}, Yale B {len(G['YALE'])}). "
          f"Titik operasi: tau = {TAU0}, K = {K0}. Semua interval = Wilson 95% kecuali dinyatakan lain.\n")

# ---------------------------------------------------------------- 1. cakupan + FTA
H("1. Cakupan data dan kegagalan akuisisi (FTA)")
rows_ = []
for ds in ("lfw", "yale"):
    gal = [r for r in plan if r["dataset"] == ds and r["role"] == "gallery"]
    gal_ok = sum(1 for r in gal if r["detected"] == 1)
    el = [r for r in plan if r["dataset"] == ds and r["role"] == "query" and r["gallery_ok"] == 1]
    det = sum(1 for r in el if r["detected"] == 1)
    rows_.append([ds.upper(), len(gal), gal_ok, len(el), det, fmt(len(el) - det, len(el))])
T("t1_cakupan", ["Dataset", "Identitas", "Galeri terdeteksi", "Query layak", "Query terdeteksi", "FTA [CI95]"], rows_,
  "FTA (failure to acquire) = gambar yang wajahnya tidak terdeteksi sama sekali; dilaporkan terpisah dari FRR.")

el_y = [r for r in plan if r["dataset"] == "yale" and r["role"] == "query" and r["gallery_ok"] == 1]
rows_ = []
for b in sorted({abin(r["light_angle"]) for r in el_y}):
    e = [r for r in el_y if abin(r["light_angle"]) == b]
    d = sum(1 for r in e if r["detected"] == 1)
    rows_.append([f"{b}–{b + 19}°", len(e), fmt(len(e) - d, len(e))])
T("t1b_fta_yale", ["Sudut cahaya (Yale B)", "Query", "FTA [CI95]"], rows_)

# ---------------------------------------------------------------- 2. skor
H("2. Pemisahan skor genuine dan impostor")
rows_, sweep = [], []
for ds, rs in G.items():
    gen = [r["genuine"] for r in rs]
    imp = [r["imp_max"] for r in rs]
    mg, mi = sum(gen) / len(gen), sum(imp) / len(imp)
    vg = sum((x - mg) ** 2 for x in gen) / len(gen)
    vi = sum((x - mi) ** 2 for x in imp) / len(imp)
    dprime = (mg - mi) / math.sqrt((vg + vi) / 2)
    gs, is_ = sorted(gen), sorted(imp)
    best = None
    for i in range(1001):
        t = i / 1000
        frr = bisect.bisect_left(gs, t) / len(gs)
        far = (len(is_) - bisect.bisect_left(is_, t)) / len(is_)
        if best is None or abs(frr - far) < best[0]:
            best = (abs(frr - far), t, (frr + far) / 2)
    rows_.append([ds, len(rs),
                  f"{pctl(gen, .5):.3f} [{pctl(gen, .1):.3f}; {pctl(gen, .9):.3f}]",
                  f"{pctl(imp, .5):.3f} [{pctl(imp, .1):.3f}; {pctl(imp, .9):.3f}]",
                  f"{dprime:.2f}", f"{100 * best[2]:.1f}% (tau={best[1]:.3f})"])
    for t in (0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.75):
        kf = bisect.bisect_left(gs, t)
        ka = len(is_) - bisect.bisect_left(is_, t)
        sweep.append([ds, f"{t:.2f}", fmt(kf, len(gs)), fmt(ka, len(is_))])
T("t2_skor", ["Dataset", "n", "Genuine median [p10; p90]", "Impostor terbaik median [p10; p90]", "d'", "EER"], rows_,
  f"Impostor = skor tertinggi ke identitas lain dalam galeri {NG} (proksi FAR identifikasi 1:N, bukan FAR verifikasi 1:1).")
T("t2b_sweep", ["Dataset", "tau", "FRR [CI95]", "FAR 1:N [CI95]"], sweep)

# ---------------------------------------------------------------- 3. korelasi kualitas
H("3. Hubungan kualitas citra dengan skor (Spearman, CI95 Bonett–Wright)")
rows_ = []
for ds, rs in G.items():
    pairs = [("genuine", "brightness"), ("genuine", "sharpness"), ("imp_max", "brightness"), ("imp_max", "sharpness")]
    if ds == "YALE":
        pairs += [("genuine", "light_angle"), ("imp_max", "light_angle"), ("brightness", "light_angle")]
    for a, b in pairs:
        x = [r[a] for r in rs if r[a] is not None and r[b] is not None]
        y = [r[b] for r in rs if r[a] is not None and r[b] is not None]
        rho, lo, hi = spearman_ci(x, y)
        rows_.append([ds, a, b, len(x), f"{rho:+.3f} [{lo:+.3f}; {hi:+.3f}]"])
T("t3_korelasi", ["Dataset", "X", "Y", "n", "rho [CI95]"], rows_,
  "brightness = rata-rata intensitas gambar; sharpness = simpangan baku intensitas (proksi kontras, bukan ketajaman tepi).")

# ---------------------------------------------------------------- 4. FAR vs N
H("4. FAR identifikasi terhadap ukuran galeri")
size_cols = [(s, f"imp_max_n{s}") for s in SIZES] + [(NG, "imp_max")]
rows_ = []
for ds, rs in G.items():
    for tau in TAUS:
        p_full = sum(1 for r in rs if r["imp_max"] >= tau) / len(rs)
        f = 1 - (1 - p_full) ** (1 / (NG - 1)) if 0 < p_full < 1 else 0.0
        for N, col in size_cols:
            k = sum(1 for r in rs if r[col] >= tau)
            model = 1 - (1 - f) ** (N - 1)
            rows_.append([ds, f"{tau:.2f}", N, fmt(k, len(rs)), f"{100 * model:.2f}%", "terukur"])
        if f > 0:
            for N in (10000, 20000, 50000, 100000):
                rows_.append([ds, f"{tau:.2f}", N, "—", f"{100 * (1 - (1 - f) ** (N - 1)):.2f}%", "EKSTRAPOLASI"])
T("t4_far_vs_n", ["Dataset", "tau", "N", "FAR 1:N terukur [CI95]", "FAR model", "Status"], rows_,
  "Model: FAR(N) = 1 - (1 - f)^(N-1), f diestimasi dari N penuh; mengasumsikan skor impostor independen dan "
  "identik. Baris EKSTRAPOLASI bukan hasil pengukuran. Kecocokan model pada N terukur menentukan apakah ekstrapolasi layak dilaporkan.")

# ---------------------------------------------------------------- 5. retrieval
H("5. Retrieval kandidat (Tier 1): recall@K dan peringkat identitas benar")
rows_ = []
for ds, rs in G.items():
    for label, col in (("16 bit, ambang 0 (desain awal)", "rank16"), ("64 bit, ambang median (usulan)", "rank64")):
        for cond, sub in (("semua query", rs), (f"genuine >= {TAU0}", [r for r in rs if r["genuine"] >= TAU0])):
            if not sub:
                continue
            rk = [r[col] for r in sub]
            cells = [fmt(sum(1 for x in rk if x <= K), len(rk)) for K in (10, 50, 100, 200, 500)]
            rows_.append([ds, label, cond, len(sub)] + cells + [int(pctl(rk, .5)), int(pctl(rk, .95))])
T("t5_recall", ["Dataset", "Sketch", "Subset", "n", "@10", "@50", "@100", "@200", "@500", "rank p50", "rank p95"], rows_,
  "Subset 'genuine >= tau' hanya memuat query yang akan diterima jika identitas benar ditemukan; kegagalan retrieval pada query lain "
  "tidak mengubah keputusan akhir karena akan ditolak oleh tau.")

rows_ = []
for ds, rs in G.items():
    for N, col in [(s, f"rank64_n{s}") for s in SIZES] + [(NG, "rank64")]:
        rk = [r[col] for r in rs]
        sub = [r[col] for r in rs if r["genuine"] >= TAU0]
        p95 = pctl(rk, .95)
        rows_.append([ds, N, fmt(sum(1 for x in rk if x <= K0), len(rk)),
                      fmt(sum(1 for x in sub if x <= K0), len(sub)) if sub else "—", int(p95), f"{p95 / N:.3f}"])
T("t5b_recall_vs_n", ["Dataset", "N", f"recall@{K0} (semua)", f"recall@{K0} (genuine >= {TAU0})", "rank p95", "rank p95 / N"], rows_,
  "Jika rank p95 / N konstan, K yang menjamin recall tetap pada query tersulit tumbuh linear terhadap N.")

# ---------------------------------------------------------------- 6. end-to-end
H("6. Keputusan akhir (end-to-end) dan uji berpasangan terhadap full scan")
rows_ = []
for ds, rs in G.items():
    for tau in TAUS:
        full = [full_outcome(r, tau) for r in rs]
        n = len(rs)
        rows_.append([ds, f"{tau:.2f}", "full scan", fmt(full.count("ok"), n),
                      f"{100 * full.count('misid') / n:.1f}%", f"{100 * full.count('reject') / n:.1f}%", "—", "—", "—"])
        for K in KS:
            pol = [k_outcome(r, K, tau) for r in rs]
            b = sum(1 for a, c in zip(full, pol) if a == "ok" and c != "ok")
            c_ = sum(1 for a, c in zip(full, pol) if a != "ok" and c == "ok")
            rows_.append([ds, f"{tau:.2f}", f"sketch K={K}", fmt(pol.count("ok"), n),
                          f"{100 * pol.count('misid') / n:.1f}%", f"{100 * pol.count('reject') / n:.1f}%",
                          b, c_, f"{mcnemar(b, c_):.4f}"])
T("t6_end_to_end", ["Dataset", "tau", "Kebijakan", "Benar [CI95]", "Salah-identitas", "Ditolak",
                    "b (hanya full benar)", "c (hanya sketch benar)", "McNemar exact p"], rows_,
  "Hanya query yang wajahnya terdeteksi. Query yang sama diuji pada semua kebijakan (desain berpasangan).")

rows_ = []
yq = G["YALE"]
for b in sorted({abin(r["light_angle"]) for r in el_y}):
    e = [r for r in el_y if abin(r["light_angle"]) == b]
    d = sum(1 for r in e if r["detected"] == 1)
    qb = [r for r in yq if abin(r["light_angle"]) == b]
    okf = sum(1 for r in qb if full_outcome(r, TAU0) == "ok")
    okk = sum(1 for r in qb if k_outcome(r, K0, TAU0) == "ok")
    rows_.append([f"{b}–{b + 19}°", len(e), fmt(len(e) - d, len(e)), fmt(okf, len(e)), fmt(okk, len(e)),
                  fmt(okk, len(qb)) if qb else "—"])
T("t6b_yale_angle", ["Sudut cahaya", "Query layak", "FTA", f"End-to-end full scan (tau={TAU0})",
                     f"End-to-end sketch K={K0}", "Sketch, hanya yang terdeteksi"], rows_,
  "End-to-end = benar / seluruh query layak, sehingga FTA ikut dihitung sebagai kegagalan.")

# ---------------------------------------------------------------- 7. latensi
H("7. Latensi (K = %d)" % K0)
rows_ = [[N, a, b, c, d, e, f] for N, a, b, c, d, e, f in LATENCY]
T("t7_latensi", ["N", "SQL Hamming p50", "p95", "Tier 2 p50", "p95", "Total p50", "p95"], rows_,
  "Satuan ms. N > 5.739 dibangun dengan menduplikasi baris galeri: sah untuk latensi, tidak untuk akurasi.")

xs = [r[0] for r in LATENCY]
ys = [r[1] for r in LATENCY]
mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
icpt = my - slope * mx
ss_res = sum((y - (icpt + slope * x)) ** 2 for x, y in zip(xs, ys))
ss_tot = sum((y - my) ** 2 for y in ys)
r2 = 1 - ss_res / ss_tot if ss_tot else float("nan")
per_cand = sum(r[3] for r in LATENCY) / len(LATENCY) / K0
per_row_full = FULLSCAN_P50_MS / FULLSCAN_N
md.append(f"- SQL Hamming p50 ≈ {icpt:.1f} + {slope * 1000:.3f} µs x N (R² = {r2:.4f}, hanya {len(xs)} titik).")
md.append(f"- Verifikasi Tier 2 ≈ {per_cand:.3f} ms per kandidat (parse JSON + dekripsi AES + cosine).")
md.append(f"- Full scan ≈ {per_row_full:.3f} ms per baris (terukur pada N = {FULLSCAN_N}).")
rows_ = []
for N, _a, _b, _c, _d, tot, _f in LATENCY:
    if N == FULLSCAN_N:
        rows_.append([N, f"{FULLSCAN_P50_MS:.1f}", f"{tot:.1f}", f"{FULLSCAN_P50_MS / tot:.1f}x", "terukur"])
    else:
        est = per_row_full * N
        rows_.append([N, f"{est:.0f}", f"{tot:.1f}", f"{est / tot:.0f}x", "PERKIRAAN"])
md.append("")
T("t7b_speedup", ["N", "Full scan p50 (ms)", "Sketch total p50 (ms)", "Percepatan", "Status"], rows_)

# ---------------------------------------------------------------- 8. keterbatasan
H("8. Catatan keterbatasan")
md += [
    "- Semua pengukuran pada satu mesin (WSL); sebutkan CPU dan RAM. Klaim 'edge' memerlukan pengukuran pada perangkat edge.",
    "- Galeri 5.710 identitas, satu foto per identitas; query LFW = foto kedua identitas yang sama (bukan kondisi kiosk).",
    "- N > 5.739 pada latensi dibangun dari duplikasi; akurasi pada N besar hanya diekstrapolasi.",
    "- Tier 1 adalah pemindaian linear O(N) di basis data dengan konstanta kecil, bukan pencarian sublinear.",
    "- Transformasi ortogonal bukan enkripsi: irreversibility tidak terpenuhi bila kunci bocor (ISO/IEC 24745).",
    "- Sketch 64 bit menyingkap jarak Hamming antar rekaman kepada siapa pun yang dapat membaca tabel.",
]

# ---------------------------------------------------------------- gambar (opsional)
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    have_plt = True
except Exception:
    have_plt = False
    md.append("\n(matplotlib tidak tersedia: gambar dilewati; gunakan file tabel_*.csv untuk membuat grafik.)")

if have_plt:
    fig, axs = plt.subplots(1, 2, figsize=(10, 3.6))
    for ax, (ds, rs) in zip(axs, G.items()):
        gs = sorted(r["genuine"] for r in rs)
        is_ = sorted(r["imp_max"] for r in rs)
        ts = [i / 200 for i in range(60, 181)]
        ax.plot(ts, [bisect.bisect_left(gs, t) / len(gs) * 100 for t in ts], label="FRR")
        ax.plot(ts, [(len(is_) - bisect.bisect_left(is_, t)) / len(is_) * 100 for t in ts], label="FAR 1:N")
        ax.axvline(TAU0, ls=":", c="gray")
        ax.set_title(ds)
        ax.set_xlabel("tau")
        ax.set_ylabel("%")
        ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "fig_frr_far.png"), dpi=200)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(5.5, 3.6))
    for ds, rs in G.items():
        Ns = [s for s in SIZES] + [NG]
        cols = [f"rank64_n{s}" for s in SIZES] + ["rank64"]
        ax.plot(Ns, [100 * sum(1 for r in rs if r[c] <= K0) / len(rs) for c in cols], marker="o", label=f"{ds} semua")
        sub = [r for r in rs if r["genuine"] >= TAU0]
        if sub:
            ax.plot(Ns, [100 * sum(1 for r in sub if r[c] <= K0) / len(sub) for c in cols], marker="s", ls="--",
                    label=f"{ds} genuine>=tau")
    ax.set_xscale("log")
    ax.set_xlabel("ukuran galeri N")
    ax.set_ylabel(f"recall@{K0} (%)")
    ax.legend(fontsize=7)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "fig_recall_vs_n.png"), dpi=200)
    plt.close(fig)

    bins = sorted({abin(r["light_angle"]) for r in el_y})
    fta_v, e2e_v = [], []
    for b in bins:
        e = [r for r in el_y if abin(r["light_angle"]) == b]
        d = sum(1 for r in e if r["detected"] == 1)
        qb = [r for r in yq if abin(r["light_angle"]) == b]
        fta_v.append(100 * (len(e) - d) / len(e))
        e2e_v.append(100 * sum(1 for r in qb if k_outcome(r, K0, TAU0) == "ok") / len(e))
    fig, ax = plt.subplots(figsize=(6, 3.6))
    ax.plot([b + 10 for b in bins], fta_v, marker="o", label="FTA")
    ax.plot([b + 10 for b in bins], e2e_v, marker="s", label=f"end-to-end (K={K0}, tau={TAU0})")
    ax.set_xlabel("sudut sumber cahaya (derajat)")
    ax.set_ylabel("%")
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "fig_yale_angle.png"), dpi=200)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(5.5, 3.6))
    labels = [str(r[0]) for r in LATENCY]
    ax.bar(labels, [r[1] for r in LATENCY], label="SQL Hamming")
    ax.bar(labels, [r[3] for r in LATENCY], bottom=[r[1] for r in LATENCY], label="verifikasi Tier 2")
    ax.set_xlabel("N")
    ax.set_ylabel("ms (p50)")
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "fig_latensi.png"), dpi=200)
    plt.close(fig)
    md.append("\nGambar: fig_frr_far.png, fig_recall_vs_n.png, fig_yale_angle.png, fig_latensi.png")

with open(os.path.join(OUT, "laporan_hasil.md"), "w", encoding="utf-8") as f:
    f.write("\n".join(md))
print(f"[SELESAI] {OUT}/laporan_hasil.md + tabel *.csv" + (" + gambar" if have_plt else ""))