# 04 — Hardware-Cost Analysis (Phase 1 baseline vs Phase 2 adaptive)

## 1. What was and was not measured (read this first)
| Item | Status |
|---|---|
| Cell area, cell count, flip-flop count | **Measured** — Yosys 0.33 + ABC, Nangate 45 nm Open Cell Library (typical), µm², after technology mapping; no placement or routing |
| Combinational vs sequential split | **Measured** (flip-flop count; per-module area) |
| Critical path | **Estimated** — ABC `stime` on the flattened design, Nangate45 delay tables, **no wire load, no clock tree, no flop setup/clk-to-q** → *not* signoff STA, not a timing-closure claim. Relative comparison Phase 1 vs Phase 2 only |
| Power | **NOT measured** — no open-source power flow in this environment. `synth/dc_synth.tcl` / `genus_synth.tcl` contain `report_power` for your university tools (**scripts provided, never executed here**) |
| Hold/setup slack, max frequency | **Not available** from this flow |
| Commercial synthesis (Design Compiler / Genus) | **Not run** (no licence here) |
Data and tag arrays are synthesised to **flip-flops + mux trees** (no SRAM macros). In a real flow they would be SRAM macros, so absolute area is dominated by storage and *percentage* overheads below are lower bounds on how small the adaptive logic looks.

## 2. Results
## Total area and sequential/combinational split (hierarchical runs)

| Config | Total area (um2) | Cells | Flip-flops |
|---|---:|---:|---:|
| 4096B 2-way Phase 1 | 302563 | 121985 | 36063 |
| 4096B 2-way Phase 2 | 303729 | 122675 | 36182 |
| 4096B 4-way Phase 1 | 305053 | 127889 | 36480 |
| 4096B 4-way Phase 2 | 306373 | 128675 | 36613 |

## Per-module area contribution (um2, including instance multiplicity)

| Module | 4096B 2w P1 | 4096B 2w P2 | 4096B 4w P1 | 4096B 4w P2 |
|---|---:|---:|---:|---:|
| data_array | 273873 | 273873 | 272460 | 272460 |
| tag_array | 22166 | 22166 | 23417 | 23417 |
| valid_array | 1484 | 1484 | 1398 | 1398 |
| cache_controller | 721 | 721 | 731 | 731 |
| hit_miss_logic | 104 | 104 | 203 | 203 |
| address_decoder | 0 | 0 | 0 | 0 |
| memory_interface | 88 | 88 | 88 | 88 |
| random_replacement | 122 | 122 | 122 | 122 |
| lru_controller | 843 | 843 | 2519 | 2519 |
| plru_controller | 0 | 0 | 975 | 975 |
| replacement_controller | 5 | 5 | 14 | 14 |
| sat_counter | 3019 | 3019 | 2865 | 2865 |
| performance_monitor | 5 | 5 | 5 | 5 |
| adaptive_controller | 0 | 1158 | 0 | 1310 |
| leader_set_map | 0 | 3 | 0 | 4 |
| cache_top | 133 | 139 | 256 | 262 |
| **sum of modules** | 302563 | 303729 | 305053 | 306373 |
| **reported total** | 302563 | 303729 | 305053 | 306373 |

## Phase 2 overhead vs Phase 1 (same geometry)

| Geometry | Phase 1 (um2) | Phase 2 (um2) | Added (um2) | Added (%) | Added flops | Added cells |
|---|---:|---:|---:|---:|---:|---:|
| 4 KB 2-way | 302563 | 303729 | 1166 | 0.39% | 119 | 690 |
| 4 KB 4-way | 305053 | 306373 | 1320 | 0.43% | 133 | 786 |

## ABC critical-path estimate (flattened, combinational, NO wire load; target period 5000 ps)

| Config | Delay (ps) | Implied f (MHz) | Area (um2) |
|---|---:|---:|---:|
| 4096B 2-way Phase 1 | 1327 | 753 | 305037 |
| 4096B 2-way Phase 2 | 2475 | 404 | 305957 |
| 4096B 4-way Phase 1 | 1448 | 690 | 308334 |
| 4096B 4-way Phase 2 | 2484 | 403 | 310038 |

Figure: `results/figures/synthesis_area.png`.

## 3. Analysis
1. **Storage dominates.** Data+tag+valid arrays are **98.3 %** (2-way) / **97.5 %** (4-way) of the 4 KB design. All control, policy and monitoring logic together is only 5 040 µm² (2-way) / 7 778 µm² (4-way).
2. **Policy-state cost (4 KB):** Random 122 µm² (16-bit LFSR); **2-way LRU 843 µm²** (1 bit/set); **4-way true LRU 2 519 µm²** (8 bits/set) vs **4-way PLRU 975 µm²** (3 bits/set) — true LRU costs about **2.6×** PLRU, which is the usual motivation for PLRU and is now measured, not assumed.
3. **Performance monitor is not free:** ten saturating 32-bit counters cost ≈3 019 µm² (2-way) — **60 % of the 2-way control logic** and more than the adaptive controller itself. Counter width is an obvious area knob (counter area is expected to scale roughly with width — *not measured here*) at the price of earlier saturation.
4. **Adaptive overhead (4 KB):** +1 166 µm² (**+0.39 %** total) for 2-way and +1 320 µm² (**+0.43 %**) for 4-way, +119 / +133 flip-flops, +690 / +786 cells. Relative to the *non-array logic* the increase is **+23.1 % (2-way) and +17.0 % (4-way)**. The adaptive controller itself is 1 158 / 1 310 µm²; the leader-set map is ≈3–4 µm² (a few comparators).
5. **Timing penalty — the real cost.** The flattened critical-path estimate rises from 1 327 → 2 475 ps (2-way, **+86 %**) and 1 448 → 2 484 ps (4-way, **+72 %**). *Probable cause (reasoning from the RTL; a per-path report was not produced):* the window decision is evaluated **combinationally in the same cycle** as the hit/miss event (chosen so a switch affects the very next request and the reference model stays transaction-exact), so the decision chain (miss event → next counters → min/compare → policy register) is appended to the hit path.
   *Candidate mitigation (NOT implemented or verified):* register the event inputs and evaluate the window one cycle later; this delays a switch by one request in rare back-to-back cases and requires updating the reference model and re-running the regression.
6. **Trade-off summary.** Adaptive management costs <0.5 % of total area (≈17–23 % of the non-array logic) and — in this implementation — substantially lengthens the combinational critical path. Its benefit (see 03) is large on policy-pathological workloads (up to −24.7 % / −38.7 % stall cycles vs LRU) but absent or slightly negative where LRU is already best (up to +8.9 %). Whether that is "worthwhile" depends on whether the cache sits on the processor's critical path and on how often the target workloads resemble the pathological ones; **the data do not support a blanket claim that adaptive is better**.

## 4. Reproduce
`python3 synth/run_synth.py all` (≈15 min on one core) → `results/synth/*.json|stat|log`; `python3 sim/make_report.py` regenerates the tables.
For commercial tools: `LIB_DB=<lib.db> WAYS=2 ADAPTIVE_EN=1 dc_shell -f synth/dc_synth.tcl`, or `genus -f synth/genus_synth.tcl` (constraints in `synth/constraints.sdc`; period 5 ns is an *assumption*).
