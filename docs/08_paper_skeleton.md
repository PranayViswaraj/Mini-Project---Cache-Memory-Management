# 08 — IEEE-Style Paper Skeleton (claims limited to what was measured)

**Working title:** A Lightweight Runtime-Adaptive Replacement-Policy Controller for a 32-bit Set-Associative Cache: RTL Implementation, Verification and Performance-versus-Hardware-Cost Evaluation

## Abstract (draft — edit after you re-run everything yourself)
We present a synthesizable Verilog data-cache controller (write-through, no-write-allocate; 1–16 KB, 2- and 4-way) supporting Random, LRU and tree-Pseudo-LRU replacement with hardware performance counters, and a lightweight deterministic adaptive layer that selects among the policies at run time using leader-set miss counts over fixed observation windows with hysteresis, without machine learning. The design is verified against an independent reference model at transaction level (218 regression tests, 3.7 M compared requests). On ten deterministic workloads the best fixed policy differed from the worst by more than 5 % in 53 of 100 geometry/workload cases, with no single policy best everywhere. The adaptive controller reduced stall cycles versus LRU by up to 24.7 % (2-way) and 38.7 % (4-way) but was up to 8.9 % worse where LRU was already best, and in one diagnosed case (4-way conflict-heavy) failed to adapt because a leader group collected no samples. With an open-source 45 nm flow (Yosys/Nangate45) the adaptive layer added 0.39–0.43 % to total area (≈17–23 % of non-array logic) and lengthened the estimated combinational critical path by 72–86 %. We discuss limitations and mitigations.

## Sections
1. Introduction (motivation; research question; contributions — *integration + evaluation, not invention of caches/LRU/adaptive management*)
2. Background and related work (**from your verified survey, doc 09**; ML only as context)
3. Architecture (spec doc 01: geometry, FSM, write policy, policies, counters)
4. Adaptive controller (leader sets, windows, equal-sample comparison, hysteresis)
5. Verification methodology (doc 02)
6. Experimental setup (workloads, LAT, fairness rules, metrics)
7. Results: Phase-1 baseline (doc 03 §2–3); adaptive vs fixed (§4); ablation (§5)
8. Hardware cost (doc 04) — area, estimated timing; state what was *not* measured (power, signoff STA, SRAM)
9. Limitations and future work (doc 05)
10. Conclusion — answer the research question **with the evidence**: lightweight runtime monitoring *can* recover much of the benefit on policy-pathological workloads at <0.5 % area, but in this implementation it does not match the best fixed policy in general, costs critical-path timing, and its leader-set rule has a diagnosed starvation failure.

## Figures/tables to include (all generated)
`results/figures/hitrate_vs_size_*way.png`, `stall_norm_4KB_*way.png`, `ablation_switches.png`, `synthesis_area.png`; tables from `results/tables_*.md`.

## Claim discipline checklist
- [ ] No claim of FPGA/silicon/commercial-tool results · [ ] power stated as not measured · [ ] timing called an *estimate*
- [ ] "Adaptive" never described as universally better · [ ] workloads described as synthetic and partly adversarial to LRU
- [ ] every reference verified by you · [ ] reproducibility: commands, tool versions, seeds (`gen_traces.py`), parameters
