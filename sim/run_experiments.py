#!/usr/bin/env python3
"""
run_experiments.py -- reproducible experiment campaign on the RTL (Verilator build of the
same RTL that passed regression). Every run is ALSO checked against the Python reference
model (counters + stall cycles); the CSV records the match flag.

  --baseline : sizes 1,2,4,8,16 KB x {2,4}-way x 10 workloads x policies
               (2-way: Random, LRU, Adaptive ; 4-way: Random, LRU, PLRU, Adaptive)
               memory latency LAT = 10 cycles/word  -> miss penalty 1 + 8*10 = 81 cycles
  --ablation : adaptive-controller study at 4 KB (2- and 4-way)
               (a) hysteresis variants   (b) observation-window size
Fair-comparison rule (master prompt Sec.47): within a row-group only cfg_policy changes.
"""
import os, sys, csv, time
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import run_regression as RR
import gen_traces as G
from ref_model import CacheModel, parse_stat

ROOT, RES, TRC = RR.ROOT, RR.RES, RR.TRC
LAT = 10
POL_NAME = {0: "Random", 1: "LRU", 2: "PLRU", 3: "Adaptive"}
SIZES = [1024, 2048, 4096, 8192, 16384]
WLS = list(G.WORKLOADS.keys())

def run_one(exe, cache, ways, wl, pol, lat, ad=1, adp=None, tag=""):
    path, reqs = RR.make_trace(wl, cache, ways)
    rc, txt = RR.sh("%s +TRACE=%s +POLICY=%d +LAT=%d" % (exe, path, pol, lat), timeout=600)
    line = next((l for l in txt.splitlines() if l.startswith("STAT")), None)
    if line is None or "RESULT PASS" not in txt: raise RuntimeError("run failed %s: %s" % (tag, txt[-300:]))
    hw = parse_stat(line)
    kw = dict(adaptive_en=bool(ad), lat=lat); kw.update(adp or {})
    m = CacheModel(cache, ways, policy=pol, **kw); _, ms = m.run(reqs)
    match = all(hw[k] == ms[k] for k in ("access", "hit", "miss", "refill", "replace", "stall", "cycles", "switch", "window"))
    return hw, match

def row(cache, ways, wl, pol, hw, match, extra=None):
    a = hw["access"]
    d = dict(cache_bytes=cache, ways=ways, workload=wl, policy=POL_NAME[pol], accesses=a, reads=hw["read"], writes=hw["write"],
             hits=hw["hit"], misses=hw["miss"], hit_rate=hw["hit"] / a, miss_rate=hw["miss"] / a,
             refills=hw["refill"], replacements=hw["replace"], stall_cycles=hw["stall"], exec_cycles=hw["cycles"],
             amat_cycles=hw["cycles"] / a, mem_reads=hw["memrd"], mem_writes=hw["memwr"],
             switches=hw["switch"], windows=hw["window"], final_policy=hw["active"], model_match=int(match))
    if extra: d.update(extra)
    return d

def baseline():
    out = []; t0 = time.time()
    for cache in SIZES:
        for ways in (2, 4):
            exe = RR.compile_verilator(cache, ways, 1)
            pols = (0, 1, 3) if ways == 2 else (0, 1, 2, 3)
            for wl in WLS:
                for pol in pols:
                    hw, ok = run_one(exe, cache, ways, wl, pol, LAT, tag="%d/%d/%s/%d" % (cache, ways, wl, pol))
                    out.append(row(cache, ways, wl, pol, hw, ok))
            print("  baseline %5dB %d-way done (%.0fs)  rows=%d  all_match=%s" % (cache, ways, time.time() - t0, len(out),
                  all(r["model_match"] for r in out)), flush=True)
    write(os.path.join(RES, "baseline_results.csv"), out)

HYST = {"none (M0,C1,H0)": (0, 1, 0), "margin only (M4,C1,H0)": (4, 1, 0), "confirm only (M0,C2,H0)": (0, 2, 0),
        "default (M4,C2,H1)": (4, 2, 1), "strong (M8,C3,H2)": (8, 3, 2)}
WINS = [512, 1024, 2048, 4096]
ABL_WL = ["phase", "conflict", "scanhot", "loop", "rand", "matmul"]

def ablation():
    out = []; t0 = time.time()
    cache = 4096
    for ways in (2, 4):
        fixed = RR.compile_verilator(cache, ways, 1)
        # fixed-policy references
        for wl in ABL_WL:
            for pol in ((0, 1) if ways == 2 else (0, 1, 2)):
                hw, ok = run_one(fixed, cache, ways, wl, pol, LAT)
                out.append(row(cache, ways, wl, pol, hw, ok, dict(study="reference", variant="fixed", win=0, sample_n=0, margin=0, conf=0, hold=0)))
        # (a) hysteresis variants at WIN=2048, SAMPLE_N=64
        for name, (mg, cf, hd) in HYST.items():
            g = "-GWIN_ACCESSES=2048 -GSAMPLE_N=64 -GMARGIN=%d -GCONF_THRESH=%d -GMIN_HOLD=%d" % (mg, cf, hd)
            exe = compile_var(cache, ways, g, "h_%d_%d_%d" % (mg, cf, hd))
            for wl in ABL_WL:
                hw, ok = run_one(exe, cache, ways, wl, 3, LAT, adp=dict(win=2048, sample_n=64, margin=mg, conf_thresh=cf, min_hold=hd))
                out.append(row(cache, ways, wl, 3, hw, ok, dict(study="hysteresis", variant=name, win=2048, sample_n=64, margin=mg, conf=cf, hold=hd)))
        # (b) observation window (SAMPLE_N = WIN/32, default hysteresis)
        for win in WINS:
            sn = win // 32
            g = "-GWIN_ACCESSES=%d -GSAMPLE_N=%d -GMARGIN=4 -GCONF_THRESH=2 -GMIN_HOLD=1" % (win, sn)
            exe = compile_var(cache, ways, g, "w_%d" % win)
            for wl in ABL_WL:
                hw, ok = run_one(exe, cache, ways, wl, 3, LAT, adp=dict(win=win, sample_n=sn, margin=4, conf_thresh=2, min_hold=1))
                out.append(row(cache, ways, wl, 3, hw, ok, dict(study="window", variant="WIN=%d" % win, win=win, sample_n=sn, margin=4, conf=2, hold=1)))
        print("  ablation %d-way done (%.0fs) all_match=%s" % (ways, time.time() - t0, all(r["model_match"] for r in out)), flush=True)
    write(os.path.join(RES, "ablation_results.csv"), out)

def compile_var(cache, ways, gflags, suffix):
    name = "sys_%d_%d_%s" % (cache, ways, suffix)
    mdir = os.path.join(RR.BLD, "vl_" + name); exe = os.path.join(mdir, name)
    if os.path.exists(exe): return exe
    cmd = ("verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -O3 --x-assign fast --x-initial fast "
           "--top-module tb_cache_system -GWAYS=%d -GCACHE_BYTES=%d -GADAPTIVE_EN=1 %s -I%s %s %s %s --Mdir %s -o %s"
           % (ways, cache, gflags, RR.TB, " ".join(RR.RTL), os.path.join(RR.TB, "mem_model.v"),
              os.path.join(RR.TB, "tb_cache_system.v"), mdir, name))
    rc, txt = RR.sh(cmd, timeout=900)
    if rc != 0: raise RuntimeError(txt[-1200:])
    return exe

def write(path, rows):
    keys = []
    for r in rows:
        for k in r:
            if k not in keys: keys.append(k)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys); w.writeheader(); w.writerows(rows)
    print("wrote", path, len(rows), "rows")

if __name__ == "__main__":
    a = sys.argv[1:] or ["--baseline", "--ablation"]
    if "--baseline" in a: baseline()
    if "--ablation" in a: ablation()
