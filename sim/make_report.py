#!/usr/bin/env python3
"""make_report.py -- builds figures + markdown tables from results/*.csv and results/synth/*.json.
Nothing here is typed in by hand: every number comes from a measured file."""
import os, sys, csv, json, glob, collections
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "results"); FIG = os.path.join(RES, "figures"); os.makedirs(FIG, exist_ok=True)

def load(p):
    rows = list(csv.DictReader(open(p)))
    for r in rows:
        for k, v in r.items():
            try: r[k] = float(v) if ("." in v or "e" in v.lower()) else int(v)
            except (ValueError, AttributeError): pass
    return rows

WL_ORDER = ["seq", "rand", "stride", "conflict", "loop", "scanhot", "matmul", "fir", "image", "phase"]
COL = {"Random": "#d62728", "LRU": "#1f77b4", "PLRU": "#2ca02c", "Adaptive": "#000000"}
MK  = {"Random": "s", "LRU": "o", "PLRU": "^", "Adaptive": "D"}

def baseline():
    R = load(os.path.join(RES, "baseline_results.csv"))
    T = {(r["cache_bytes"], r["ways"], r["workload"], r["policy"]): r for r in R}
    out = ["# Generated baseline tables", "", "model_match (RTL == reference model on every run): %d / %d" % (sum(r["model_match"] for r in R), len(R)), ""]
    # ---- per-config tables at 4 KB
    for ways in (2, 4):
        pols = ["Random", "LRU", "Adaptive"] if ways == 2 else ["Random", "LRU", "PLRU", "Adaptive"]
        out += ["## 4 KB, %d-way (LAT=10)  — hit rate / stall cycles / measured AMAT" % ways, "",
                "| Workload | " + " | ".join(pols) + " | best fixed | Adaptive vs best fixed (stall) | Adaptive vs LRU (stall) |",
                "|---|" + "---:|" * len(pols) + "---|---:|---:|"]
        for wl in WL_ORDER:
            cells, fixed = [], {}
            for p in pols:
                r = T[(4096, ways, wl, p)]
                cells.append("%.1f%% / %d / %.2f" % (100 * r["hit_rate"], r["stall_cycles"], r["amat_cycles"]))
                if p != "Adaptive": fixed[p] = r["stall_cycles"]
            bf = min(fixed, key=fixed.get); a = T[(4096, ways, wl, "Adaptive")]["stall_cycles"]
            out.append("| %s | %s | %s | %+.1f%% | %+.1f%% |" % (wl, " | ".join(cells), bf, 100 * (a - fixed[bf]) / fixed[bf], 100 * (a - fixed["LRU"]) / fixed["LRU"]))
        out.append("")
    # ---- campaign-wide summary
    summ = collections.defaultdict(list)
    for (c, w, wl, p), r in T.items():
        if p != "Adaptive": continue
        fx = {q: T[(c, w, wl, q)]["stall_cycles"] for q in (["Random", "LRU"] if w == 2 else ["Random", "LRU", "PLRU"])}
        bf = min(fx.values()); worst = max(fx.values())
        summ[w].append(dict(c=c, wl=wl, a=r["stall_cycles"], bf=bf, lru=fx["LRU"], worst=worst, sw=r["switches"]))
    out += ["## Campaign-wide Adaptive summary (stall cycles; 5 sizes x 10 workloads per associativity)", "",
            "| Ways | cases | within 1% of best fixed | better than LRU by >1% | worse than LRU by >1% | worse than best fixed by >5% | worst gap vs best fixed | best gain vs LRU |", "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for w, L in summ.items():
        n = len(L)
        out.append("| %d | %d | %d | %d | %d | %d | %+.1f%% | %+.1f%% |" % (w, n,
            sum(1 for x in L if x["a"] <= 1.01 * x["bf"]),
            sum(1 for x in L if x["a"] < 0.99 * x["lru"]),
            sum(1 for x in L if x["a"] > 1.01 * x["lru"]),
            sum(1 for x in L if x["a"] > 1.05 * x["bf"]),
            100 * max((x["a"] - x["bf"]) / x["bf"] for x in L),
            100 * min((x["a"] - x["lru"]) / x["lru"] for x in L)))
    out.append("")
    open(os.path.join(RES, "tables_baseline.md"), "w").write("\n".join(out))
    # ---- figures
    for ways in (2, 4):
        pols = ["Random", "LRU", "Adaptive"] if ways == 2 else ["Random", "LRU", "PLRU", "Adaptive"]
        fig, axs = plt.subplots(2, 5, figsize=(20, 7), sharex=True)
        for ax, wl in zip(axs.flat, WL_ORDER):
            for p in pols:
                xs = sorted({k[0] for k in T if k[1] == ways})
                ax.plot([x // 1024 for x in xs], [100 * T[(x, ways, wl, p)]["hit_rate"] for x in xs], marker=MK[p], color=COL[p], label=p, ms=5, lw=1.3)
            ax.set_title(wl); ax.set_xscale("log", base=2); ax.set_xticks([1, 2, 4, 8, 16]); ax.set_xticklabels(["1", "2", "4", "8", "16"]); ax.grid(alpha=.3)
        for ax in axs[:, 0]: ax.set_ylabel("hit rate (%)")
        for ax in axs[1]: ax.set_xlabel("cache size (KB)")
        axs[0, 0].legend(fontsize=8)
        fig.suptitle("Hit rate vs cache size, %d-way (RTL-measured, LAT=10)" % ways); fig.tight_layout()
        fig.savefig(os.path.join(FIG, "hitrate_vs_size_%dway.png" % ways), dpi=110); plt.close(fig)
        # normalised stall at 4KB
        fig, ax = plt.subplots(figsize=(11, 4.5)); bw = 0.8 / len(pols)
        for i, p in enumerate(pols):
            vals = [T[(4096, ways, wl, p)]["stall_cycles"] / T[(4096, ways, wl, "LRU")]["stall_cycles"] for wl in WL_ORDER]
            ax.bar([j + i * bw for j in range(len(WL_ORDER))], vals, bw, label=p, color=COL[p])
        ax.axhline(1, color="gray", lw=.8); ax.set_xticks([j + 0.4 - bw / 2 for j in range(len(WL_ORDER))]); ax.set_xticklabels(WL_ORDER)
        ax.set_ylabel("stall cycles / LRU stall cycles"); ax.set_title("4 KB %d-way: stall cycles normalised to LRU (lower is better)" % ways); ax.legend(); ax.grid(axis="y", alpha=.3)
        fig.tight_layout(); fig.savefig(os.path.join(FIG, "stall_norm_4KB_%dway.png" % ways), dpi=110); plt.close(fig)
        # AMAT vs size for two policy-sensitive workloads
        fig, axs = plt.subplots(1, 3, figsize=(15, 4))
        for ax, wl in zip(axs, ["conflict", "scanhot", "phase"]):
            for p in pols:
                xs = sorted({k[0] for k in T if k[1] == ways})
                ax.plot([x // 1024 for x in xs], [T[(x, ways, wl, p)]["amat_cycles"] for x in xs], marker=MK[p], color=COL[p], label=p)
            ax.set_title(wl); ax.set_xscale("log", base=2); ax.set_xticks([1, 2, 4, 8, 16]); ax.set_xticklabels(["1", "2", "4", "8", "16"]); ax.set_xlabel("cache size (KB)"); ax.set_ylabel("measured AMAT (cycles)"); ax.grid(alpha=.3)
        axs[0].legend(); fig.tight_layout(); fig.savefig(os.path.join(FIG, "amat_vs_size_%dway.png" % ways), dpi=110); plt.close(fig)

def ablation():
    p = os.path.join(RES, "ablation_results.csv")
    if not os.path.exists(p): return
    R = load(p); out = ["# Generated ablation tables", "", "model_match: %d / %d" % (sum(r["model_match"] for r in R), len(R)), ""]
    wls = ["phase", "conflict", "scanhot", "loop", "rand", "matmul"]
    for ways in (2, 4):
        ref = {(r["workload"], r["policy"]): r["stall_cycles"] for r in R if r["study"] == "reference" and r["ways"] == ways}
        pols = ["Random", "LRU"] + (["PLRU"] if ways == 4 else [])
        for study, title in (("hysteresis", "Hysteresis variants (WIN=2048)"), ("window", "Observation-window size (SAMPLE_N=WIN/32)")):
            out += ["## 4 KB %d-way — %s: stall cycles (switches)" % (ways, title), "",
                    "| Variant | " + " | ".join(wls) + " |", "|---|" + "---:|" * len(wls)]
            out.append("| *best fixed* | " + " | ".join(str(min(ref[(w, q)] for q in pols)) for w in wls) + " |")
            out.append("| *LRU* | " + " | ".join(str(ref[(w, "LRU")]) for w in wls) + " |")
            variants = []
            for r in R:
                if r["study"] == study and r["ways"] == ways and r["variant"] not in variants: variants.append(r["variant"])
            for v in variants:
                cells = []
                for w in wls:
                    r = next(x for x in R if x["study"] == study and x["ways"] == ways and x["variant"] == v and x["workload"] == w)
                    cells.append("%d (%d)" % (r["stall_cycles"], r["switches"]))
                out.append("| %s | %s |" % (v, " | ".join(cells)))
            out.append("")
    open(os.path.join(RES, "tables_ablation.md"), "w").write("\n".join(out))
    fig, axs = plt.subplots(1, 2, figsize=(13, 4.2))
    for ax, ways in zip(axs, (2, 4)):
        names = ["none (M0,C1,H0)", "margin only (M4,C1,H0)", "confirm only (M0,C2,H0)", "default (M4,C2,H1)", "strong (M8,C3,H2)"]
        ax.bar(range(5), [sum(r["switches"] for r in R if r["study"] == "hysteresis" and r["ways"] == ways and r["variant"] == n) for n in names], color="#4c72b0")
        ax.set_xticks(range(5)); ax.set_xticklabels(["none", "margin", "confirm", "default", "strong"], rotation=15)
        ax.set_ylabel("total policy switches (6 workloads)"); ax.set_title("4 KB %d-way: switches vs hysteresis" % ways); ax.grid(axis="y", alpha=.3)
    fig.tight_layout(); fig.savefig(os.path.join(FIG, "ablation_switches.png"), dpi=110); plt.close(fig)

def synthesis():
    files = sorted(glob.glob(os.path.join(RES, "synth", "*.json")))
    if not files: return
    D = {json.load(open(f))["tag"]: json.load(open(f)) for f in files}
    out = ["# Generated synthesis tables (Yosys + ABC + Nangate45, um^2)", ""]
    out += ["## Total area and sequential/combinational split (hierarchical runs)", "", "| Config | Total area (um2) | Cells | Flip-flops |", "|---|---:|---:|---:|"]
    for t, d in D.items():
        if not d["flat"]: out.append("| %dB %d-way Phase %d | %.0f | %d | %d |" % (d["cache"], d["ways"], 2 if d["adaptive"] else 1, d["total"], d["cells"], d["flops"]))
    out += ["", "## Per-module area contribution (um2, including instance multiplicity)", ""]
    mods = ["data_array", "tag_array", "valid_array", "cache_controller", "hit_miss_logic", "address_decoder", "memory_interface",
            "random_replacement", "lru_controller", "plru_controller", "replacement_controller", "sat_counter", "performance_monitor", "adaptive_controller", "leader_set_map", "cache_top"]
    hier = [(t, d) for t, d in D.items() if not d["flat"]]
    out += ["| Module | " + " | ".join("%dB %dw P%d" % (d["cache"], d["ways"], 2 if d["adaptive"] else 1) for t, d in hier) + " |", "|---|" + "---:|" * len(hier)]
    for m in mods:
        out.append("| %s | %s |" % (m, " | ".join("%.0f" % d["contrib"].get(m, 0) for t, d in hier)))
    out.append("| **sum of modules** | %s |" % " | ".join("%.0f" % sum(d["contrib"].values()) for t, d in hier))
    out.append("| **reported total** | %s |" % " | ".join("%.0f" % d["total"] for t, d in hier))
    out += ["", "## Phase 2 overhead vs Phase 1 (same geometry)", "", "| Geometry | Phase 1 (um2) | Phase 2 (um2) | Added (um2) | Added (%) | Added flops | Added cells |", "|---|---:|---:|---:|---:|---:|---:|"]
    for w in (2, 4):
        a, b = D.get("hier_4096B_%dw_p1" % w), D.get("hier_4096B_%dw_p2" % w)
        if a and b: out.append("| 4 KB %d-way | %.0f | %.0f | %.0f | %.2f%% | %d | %d |" % (w, a["total"], b["total"], b["total"] - a["total"], 100 * (b["total"] - a["total"]) / a["total"], b["flops"] - a["flops"], b["cells"] - a["cells"]))
    flat = [(t, d) for t, d in D.items() if d["flat"]]
    if flat:
        out += ["", "## ABC critical-path estimate (flattened, combinational, NO wire load; target period 5000 ps)", "", "| Config | Delay (ps) | Implied f (MHz) | Area (um2) |", "|---|---:|---:|---:|"]
        for t, d in flat:
            dl = d["delay_ps"]; out.append("| %dB %d-way Phase %d | %s | %s | %.0f |" % (d["cache"], d["ways"], 2 if d["adaptive"] else 1, "%.0f" % dl if dl else "n/a", "%.0f" % (1e6 / dl) if dl else "n/a", d["total"]))
    open(os.path.join(RES, "tables_synthesis.md"), "w").write("\n".join(out) + "\n")
    # figure: stacked area (excluding big arrays) + overhead
    fig, axs = plt.subplots(1, 2, figsize=(14, 4.8))
    names = [("data_array", "#9ecae1"), ("tag_array", "#6baed6"), ("valid_array", "#3182bd")]
    labs = ["%dw P%d" % (d["ways"], 2 if d["adaptive"] else 1) for t, d in hier]
    bot = [0] * len(hier)
    for m, c in names:
        v = [d["contrib"].get(m, 0) for t, d in hier]; axs[0].bar(labs, v, bottom=bot, color=c, label=m); bot = [a + b for a, b in zip(bot, v)]
    rest = [d["total"] - b for (t, d), b in zip(hier, bot)]
    axs[0].bar(labs, rest, bottom=bot, color="#e6550d", label="all control / policy logic"); axs[0].legend(fontsize=8)
    axs[0].set_ylabel("area (um2)"); axs[0].set_title("4 KB: storage (flop arrays) vs control logic"); axs[0].grid(axis="y", alpha=.3)
    ctl = ["cache_controller", "hit_miss_logic", "memory_interface", "random_replacement", "lru_controller", "plru_controller", "replacement_controller", "performance_monitor", "sat_counter", "adaptive_controller", "leader_set_map", "address_decoder", "cache_top"]
    cols = plt.cm.tab20.colors; bot = [0] * len(hier)
    for i, m in enumerate(ctl):
        v = [d["contrib"].get(m, 0) for t, d in hier]
        if sum(v) > 0: axs[1].bar(labs, v, bottom=bot, color=cols[i % 20], label=m); bot = [a + b for a, b in zip(bot, v)]
    axs[1].legend(fontsize=7, ncol=2); axs[1].set_ylabel("area (um2)"); axs[1].set_title("Control-logic breakdown (arrays excluded)"); axs[1].grid(axis="y", alpha=.3)
    fig.tight_layout(); fig.savefig(os.path.join(FIG, "synthesis_area.png"), dpi=110); plt.close(fig)

if __name__ == "__main__":
    for f in (baseline, ablation, synthesis):
        try: f()
        except FileNotFoundError as e: print("skip", f.__name__, e)
    print("report built")
