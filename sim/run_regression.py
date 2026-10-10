#!/usr/bin/env python3
"""
run_regression.py -- complete verification regression.

  --module    10 module-level self-checking testbenches
  --directed  cache-level directed/corner suite on 4 builds (2/4-way x Phase1/Phase2) x 2 latencies
  --system    trace-driven lock-step comparison RTL <-> Python reference model:
                every request: hit/miss, victim way, read data, active policy
                whole run     : every counter incl. stall cycles, switch/window counts
              + Phase-1 build vs Phase-2 build equivalence for fixed policies
  --all       everything

Writes results/regression_*.csv and results/regression_summary.md
"""
import os, sys, subprocess, csv, time, random, re
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import gen_traces as G
from ref_model import CacheModel, parse_stat, parse_log

RTL = sorted(os.path.join(ROOT, "rtl", f) for f in os.listdir(os.path.join(ROOT, "rtl")) if f.endswith(".v"))
TB  = os.path.join(ROOT, "tb")
BLD = os.path.join(ROOT, "build")
RES = os.path.join(ROOT, "results")
TRC = os.path.join(ROOT, "traces")
for d in (BLD, RES, TRC): os.makedirs(d, exist_ok=True)

def sh(cmd, timeout=600):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout + r.stderr

def compile_tb(top, srcs, params=None, out=None):
    out = out or os.path.join(BLD, top + ".vvp")
    pf = " ".join("-P%s.%s=%s" % (top, k, v) for k, v in (params or {}).items())
    rc, txt = sh("iverilog -g2012 -I%s -o %s -s %s %s %s" % (TB, out, top, pf, " ".join(srcs)))
    if rc != 0: raise RuntimeError("compile failed for %s:\n%s" % (top, txt))
    return out


def compile_verilator(cache, ways, ad, extra_g=""):
    """Fast 2-state build of tb_cache_system (used for long trace runs). Cross-checked
    against Icarus: per-request logs are bit-identical."""
    name = "sys_%d_%d_%d" % (cache, ways, ad)
    mdir = os.path.join(BLD, "vl_" + name)
    exe = os.path.join(mdir, name)
    if os.path.exists(exe) and not extra_g: return exe
    cmd = ("verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -O3 --x-assign fast --x-initial fast "
           "--top-module tb_cache_system -GWAYS=%d -GCACHE_BYTES=%d -GADAPTIVE_EN=%d %s -I%s %s %s %s --Mdir %s -o %s"
           % (ways, cache, ad, extra_g, TB, " ".join(RTL), os.path.join(TB, "mem_model.v"),
              os.path.join(TB, "tb_cache_system.v"), mdir, name))
    rc, txt = sh(cmd, timeout=600)
    if rc != 0 or not os.path.exists(exe): raise RuntimeError("verilator build failed:\n" + txt[-1500:])
    return exe

# --------------------------------------------------------------------------- module level
MODULE_TESTS = [
    ("address_decoder",        ["address_decoder.v"]),
    ("hit_miss_logic",         ["hit_miss_logic.v"]),
    ("arrays",                 ["tag_array.v", "valid_array.v", "data_array.v"]),
    ("random_replacement",     ["random_replacement.v"]),
    ("lru_controller",         ["lru_controller.v"]),
    ("plru_controller",        ["plru_controller.v"]),
    ("replacement_controller", ["random_replacement.v", "lru_controller.v", "plru_controller.v", "replacement_controller.v"]),
    ("perf_monitor",           ["sat_counter.v", "performance_monitor.v"]),
    ("memory_interface",       ["memory_interface.v"]),
    ("adaptive_controller",    ["leader_set_map.v", "adaptive_controller.v"]),
]
def run_module():
    rows = []
    for name, files in MODULE_TESTS:
        srcs = [os.path.join(ROOT, "rtl", f) for f in files]
        if name == "memory_interface": srcs.append(os.path.join(TB, "mem_model.v"))
        srcs.append(os.path.join(TB, "tb_%s.v" % name))
        vvp = compile_tb("tb_" + name, srcs)
        rc, txt = sh("vvp -n %s +LAT=3" % vvp, timeout=120)
        m = re.search(r"TBRESULT (\S+) (PASS|FAIL) checks=(\d+)", txt)
        status, checks = (m.group(2), int(m.group(3))) if m else ("FAIL", 0)
        rows.append(("module", name, status, checks, ""))
        print("  [module] %-24s %s  checks=%d" % (name, status, checks), flush=True)
    return rows

# --------------------------------------------------------------------------- directed
def run_directed():
    rows = []
    for ways in (2, 4):
        for ad in (0, 1):
            vvp = compile_tb("tb_cache_directed", RTL + [os.path.join(TB, "mem_model.v"), os.path.join(TB, "tb_cache_directed.v")],
                             {"WAYS": ways, "ADAPTIVE_EN": ad}, out=os.path.join(BLD, "dir_%d_%d.vvp" % (ways, ad)))
            for lat in (1, 4, 10):
                rc, txt = sh("vvp -n %s +LAT=%d" % (vvp, lat), timeout=300)
                m = re.search(r"TBRESULT (\S+) (PASS|FAIL) checks=(\d+)", txt)
                status, checks = (m.group(2), int(m.group(3))) if m else ("FAIL", 0)
                name = "cache_directed %d-way %s LAT=%d" % (ways, "Phase2" if ad else "Phase1", lat)
                rows.append(("directed", name, status, checks, ""))
                print("  [directed] %-42s %s checks=%d" % (name, status, checks), flush=True)
    return rows

# --------------------------------------------------------------------------- system
def stress_trace(cache, seed):
    """Heavy conflict + byte enables + pseudo-random UPPER address bits.
    The test memory has 2^18 words and aliases addresses on addr[19:2]. To keep the test
    meaningful, every word index gets exactly ONE full address (upper 12 bits are a fixed
    hash of the word index), so distinct addresses never share a memory word, while the
    tag still takes many different upper-bit values."""
    rng = random.Random(seed)
    region = 2 * cache // 4                     # words
    def full(idx):
        hi = ((idx * 0x9E3779B1) >> 19) & 0xFFF
        return (hi << 20) | (idx << 2)
    out = []
    for _ in range(12000):
        a = full(rng.randrange(region))
        if rng.random() < 0.3: out.append(G.W(a, rng.getrandbits(32), rng.choice([0xF, 0x1, 0x2, 0x4, 0x8, 0x3, 0xC, 0x5, 0xA, 0x0])))
        else:                  out.append(G.R(a))
    return out

def make_trace(wl, cache, ways):
    path = os.path.join(TRC, "%s_%d_%d.hex" % (wl, cache, ways))
    if wl == "stress": reqs = stress_trace(cache, 7 + ways)
    else:              reqs = G.make(wl, cache, ways)
    G.write_trace(path, reqs)
    return path, reqs

def sys_case(vvp, cache, ways, ad, wl, policy, lat, extra="", cmp_cycles=True, tag=""):
    path, reqs = make_trace(wl, cache, ways)
    logf = os.path.join(BLD, "sys.log")
    rc, txt = sh("%s +TRACE=%s +POLICY=%d +LAT=%d +LOG=%s %s" % (vvp, path, policy, lat, logf, extra), timeout=400)
    stat_line = next((l for l in txt.splitlines() if l.startswith("STAT")), None)
    res_ok = "RESULT PASS" in txt
    if stat_line is None: return False, "no STAT line: " + txt[-300:], None
    hw = parse_stat(stat_line)
    m = CacheModel(cache, ways, policy=policy, adaptive_en=bool(ad), lat=lat)
    mlog, ms = m.run(reqs)
    problems = []
    if not res_ok: problems.append("TB self-check failed")
    rlog = parse_log(logf)
    if len(rlog) != len(mlog): problems.append("log length %d != %d" % (len(rlog), len(mlog)))
    else:
        for a, b in zip(rlog, mlog):
            if a != b:
                problems.append("first per-request mismatch: RTL=%s MODEL=%s" % (a, b)); break
    keys = ["access", "read", "write", "hit", "miss", "refill", "replace", "memrd", "memwr", "stall", "switch", "window"]
    if cmp_cycles: keys.append("cycles")
    for k in keys:
        if hw[k] != ms[k]: problems.append("%s RTL=%d MODEL=%d" % (k, hw[k], ms[k]))
    return (not problems), "; ".join(problems), (hw, ms, rlog)

def run_system(quick=False):
    rows = []
    t0 = time.time()
    configs = [(4096, 2), (4096, 4), (1024, 2), (2048, 4), (8192, 2), (16384, 4), (1024, 4)]
    full_wl = list(G.WORKLOADS.keys()) + ["stress"]
    small_wl = ["rand", "conflict", "phase", "stress"]
    builds = {}
    def build(cache, ways, ad):
        k = (cache, ways, ad)
        if k not in builds:
            builds[k] = compile_verilator(cache, ways, ad)
        return builds[k]
    logs_p2 = {}
    for (cache, ways) in configs:
        wls = full_wl if (cache == 4096) else small_wl
        if quick: wls = ["conflict", "stress"]
        vvp = build(cache, ways, 1)
        for wl in wls:
            for pol in (0, 1, 2, 3):
                lat = {0: 6, 1: 10, 2: 1, 3: 4}[pol]
                ok, why, data = sys_case(vvp, cache, ways, 1, wl, pol, lat)
                name = "%dB %d-way %-8s policy=%d LAT=%d" % (cache, ways, wl, pol, lat)
                rows.append(("system", name, "PASS" if ok else "FAIL", len(G.read_trace(os.path.join(TRC, "%s_%d_%d.hex" % (wl, cache, ways)))), why))
                print("  [system] %-48s %s %s" % (name, "PASS" if ok else "FAIL", why[:100]), flush=True)
                if ok and data and pol in (0, 1, 2) and cache == 4096 and wl in ("stress", "phase", "scanhot"):
                    logs_p2[(cache, ways, wl, pol)] = data[2]
    # ---- Phase-1 build (no adaptive hardware) must equal Phase-2 build for fixed policies
    for (cache, ways) in [(4096, 2), (4096, 4)]:
        vvp1 = build(cache, ways, 0)
        for wl in ("stress", "phase", "scanhot"):
            for pol in (0, 1, 2, 3):
                ok, why, data = sys_case(vvp1, cache, ways, 0, wl, pol, 4)
                if ok and pol in (0, 1, 2):
                    same = (data[2] == logs_p2.get((cache, ways, wl, pol)))
                    if not same: ok, why = False, "Phase-1 build differs from Phase-2 build (fixed policy)"
                name = "Phase1-build %dB %d-way %-8s policy=%d (== Phase2 build for fixed policies)" % (cache, ways, wl, pol)
                rows.append(("equivalence", name, "PASS" if ok else "FAIL", 0, why))
                print("  [equiv ] %-70s %s %s" % (name, "PASS" if ok else "FAIL", why[:80]), flush=True)
    # ---- protocol robustness: idle gaps / random gaps must not change behaviour
    vvp = build(4096, 2, 1)
    for extra, nm in (("+GAP=3", "GAP=3"), ("+RGAP=1", "random gaps")):
        for pol in (1, 3):
            ok, why, _ = sys_case(vvp, 4096, 2, 1, "stress", pol, 5, extra=extra, cmp_cycles=False)
            name = "gaps (%s) 4096B 2-way stress policy=%d" % (nm, pol)
            rows.append(("robustness", name, "PASS" if ok else "FAIL", 0, why))
            print("  [robust] %-50s %s %s" % (name, "PASS" if ok else "FAIL", why[:80]), flush=True)
    print("  system regression time: %.0f s" % (time.time() - t0))
    return rows

def write_reports(rows):
    with open(os.path.join(RES, "regression_results.csv"), "w", newline="") as f:
        w = csv.writer(f); w.writerow(["category", "test", "status", "checks_or_requests", "detail"]); w.writerows(rows)
    cats = {}
    for c, n, s, k, d in rows:
        t = cats.setdefault(c, [0, 0, 0]); t[0] += 1; t[1] += (s == "PASS"); t[2] += k
    lines = ["# Regression summary (generated by sim/run_regression.py)", "",
             "| Category | Tests | Passed | Failed | Checks / requests |", "|---|---:|---:|---:|---:|"]
    for c, (n, p, k) in cats.items(): lines.append("| %s | %d | %d | %d | %d |" % (c, n, p, n - p, k))
    tot = sum(v[0] for v in cats.values()); ps = sum(v[1] for v in cats.values())
    lines += ["", "**Total: %d tests, %d passed, %d failed**" % (tot, ps, tot - ps), ""]
    fails = [r for r in rows if r[2] != "PASS"]
    if fails:
        lines += ["## Failures", ""] + ["- %s / %s: %s" % (r[0], r[1], r[4]) for r in fails]
    open(os.path.join(RES, "regression_summary.md"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))

if __name__ == "__main__":
    args = sys.argv[1:] or ["--all"]
    rows = []
    part = os.path.join(RES, "_partial_%s.csv")
    def save_part(name, r):
        with open(part % name, "w", newline="") as f: csv.writer(f).writerows(r)
    def load_part(name):
        p = part % name
        return [tuple(x[:2] + [x[2]] + [int(x[3])] + [x[4]]) for x in csv.reader(open(p))] if os.path.exists(p) else []
    if "--module" in args or "--all" in args:   r = run_module();   save_part("module", r);   rows += r
    if "--directed" in args or "--all" in args: r = run_directed(); save_part("directed", r); rows += r
    if "--system" in args or "--all" in args:   r = run_system("--quick" in args); save_part("system", r); rows += r
    if "--report" in args:
        rows = load_part("module") + load_part("directed") + load_part("system")
    if rows: write_reports(rows)
