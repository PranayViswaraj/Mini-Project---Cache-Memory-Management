#!/usr/bin/env python3
"""
run_synth.py -- open-source ASIC-style synthesis: Yosys + ABC + Nangate 45nm Open Cell Library.

Two flows per configuration
  hier : hierarchy kept  -> per-module AREA breakdown (what does each block cost?)
  flat : design flattened -> ABC critical-path estimate (combinational, flop-to-flop/IO)

HONEST SCOPE (also stated in docs/04):
  * area is the liberty cell area after technology mapping (um^2), no placement/routing
  * timing is ABC's `stime` estimate with Nangate45 delay tables, NO wire load, NO clock tree,
    NO setup/hold of flops => NOT signoff STA, not a "timing closure" claim
  * data/tag arrays are mapped to flip-flops (no SRAM macros) so they dominate area
  * power is NOT estimated (no open-source power flow here); dc_synth.tcl / genus_synth.tcl
    contain the commercial-tool reports
"""
import os, re, sys, subprocess, json, csv, time
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB  = os.path.join(ROOT, "synth", "lib", "nangate45.lib")
OUT  = os.path.join(ROOT, "results", "synth"); os.makedirs(OUT, exist_ok=True)
RTLF = ["address_decoder", "valid_array", "tag_array", "data_array", "hit_miss_logic", "random_replacement",
        "lru_controller", "plru_controller", "replacement_controller", "sat_counter", "performance_monitor",
        "memory_interface", "cache_controller", "leader_set_map", "adaptive_controller", "cache_top"]
PERIOD_PS = 5000
ABC_SCRIPT = "strash; &get -n; &fraig -x; &put; scorr; dc2; dretime; strash; &get -n; &dch -f; &nf {D}; &put; buffer; upsize {D}; dnsize {D}; stime -p"

def ys(cache, ways, ad, flat, tag):
    rd = " ".join(os.path.join(ROOT, "rtl", f + ".v") for f in RTLF)
    scr = ABC_SCRIPT
    lines = ["read_verilog -defer -sv " + rd,
             "hierarchy -check -top cache_top -chparam CACHE_BYTES %d -chparam WAYS %d -chparam ADAPTIVE_EN %d" % (cache, ways, ad),
             "synth -top cache_top" + (" -flatten" if flat else ""),
             "dfflibmap -liberty " + LIB,
             "abc -liberty %s -D %d -script +%s" % (LIB, PERIOD_PS, scr.replace(" ", "\\ ").replace(";", ";") if False else scr.replace("; ", ";").replace(" ", ",")),
             "opt_clean -purge",
             "tee -o %s/%s.stat stat -liberty %s -top cache_top" % (OUT, tag, LIB)]
    p = os.path.join(OUT, tag + ".ys")
    open(p, "w").write("\n".join(lines) + "\n")
    return p

def norm(name):
    segs = name.strip().split("\\")
    for s in segs:
        if re.fullmatch(r"[a-z][a-z_0-9]*", s): return s
    return name

def parse_stat(path):
    txt = open(path).read()
    per = {}
    # module names of parameterised modules contain an apostrophe (WAYS=32'000..) -> match to end of line
    for m in re.finditer(r"Chip area for module '(.+)': ([0-9.]+)\s*$", txt, re.M):
        per[norm(m.group(1))] = float(m.group(2))
    mt = re.search(r"Chip area for top module '[^']+': ([0-9.]+)", txt)
    total = float(mt.group(1)) if mt else per["cache_top"]          # flat netlist: no hierarchy section
    mult, stack = {}, []
    if "=== design hierarchy ===" in txt:
        sec = txt[txt.index("=== design hierarchy ==="):]
        for line in sec.splitlines():
            m = re.match(r"^(\s+)(\S.*?)\s+(\d+)\s*$", line)
            if not m or "Number of" in line or "Chip area" in line: continue
            indent = len(m.group(1)); nm = norm(m.group(2)); cnt = int(m.group(3))
            if nm in ("cache_top",) or nm in per:
                while stack and stack[-1][0] >= indent: stack.pop()
                parent_mult = stack[-1][1] if stack else 1
                tot = parent_mult * cnt
                mult[nm] = mult.get(nm, 0) + tot
                stack.append((indent, tot))
    else:
        sec = txt
    cells = int(re.search(r"Number of cells:\s+(\d+)", sec).group(1))
    flops = sum(int(x) for x in re.findall(r"^\s+(?:DFF\w*)\s+(\d+)\s*$", sec, re.M))
    contrib = {k: per[k] * mult.get(k, 1) for k in per}
    return dict(total=total, per_instance=per, mult=mult, contrib=contrib, cells=cells, flops=flops)

def parse_delay(logpath):
    txt = open(logpath).read()
    ms = re.findall(r"Delay\s*=\s*([0-9.]+)\s*ps", txt)
    return float(ms[-1]) if ms else None

def run(cache, ways, ad, flat):
    tag = "%s_%dB_%dw_p%d" % ("flat" if flat else "hier", cache, ways, 2 if ad else 1)
    p = ys(cache, ways, ad, flat, tag)
    log = os.path.join(OUT, tag + ".log")
    t0 = time.time()
    r = subprocess.run("yosys -q -l %s %s" % (log, p), shell=True, capture_output=True, text=True, timeout=3000)
    if r.returncode != 0: raise RuntimeError(tag + ": " + r.stderr[-800:])
    d = parse_stat(os.path.join(OUT, tag + ".stat"))
    d["delay_ps"] = parse_delay(log) if flat else None
    d.update(tag=tag, cache=cache, ways=ways, adaptive=ad, flat=flat, secs=round(time.time() - t0))
    json.dump(d, open(os.path.join(OUT, tag + ".json"), "w"), indent=1)
    print("%-28s area=%10.1f um2  flops=%6d  cells=%6d  delay=%s  (%ds)" % (tag, d["total"], d["flops"], d["cells"], d["delay_ps"], d["secs"]), flush=True)
    return d

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    cfgs = [(4096, 2, 0), (4096, 2, 1), (4096, 4, 0), (4096, 4, 1)]
    if mode in ("hier", "all"):
        for c in cfgs: run(*c, flat=False)
    if mode in ("flat", "all"):
        for c in cfgs: run(*c, flat=True)
