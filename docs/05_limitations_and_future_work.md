# 05 — Limitations, Phase-2 Handoff Checklist and Future Work

## 1. Phase-1 exit checklist (what exists in this package)
| Item | Status |
|---|---|
| Frozen architecture spec + write policy decision | done (`01_architecture_spec.md`) |
| Synthesizable Verilog, parameterised (1–16 KB, 2/4-way) | done, Verilator-lint clean on 6 configs |
| Random / LRU / PLRU(4-way) | done, each verified against an independently coded model |
| Hardware performance counters (10, saturating) | done, invariants checked in every system run |
| Module, cache, system verification + reference model | done (see `02_verification_report.md`) |
| ASIC-style synthesis: area, cell/flop count, critical-path *estimate* | done with open-source flow |
| Commercial-tool (DC/Genus) synthesis, power, STA slack | **scripts only — not executed** |
| Baseline performance dataset | done (`results/baseline_results.csv`, 350 rows) |
| FPGA | **excluded from Phase 1 by the project definition; not done** |
| Literature survey / research-gap evidence | **template only** (`09_literature_worksheet.md`) — must be completed by you |

## 2. Phase-2 items
Observation windows, leader-set comparative selection, hysteresis (margin / confirmation / hold), runtime reconfiguration (`cfg_policy=11`), switch/window counters, extended verification (adaptive unit test, adaptive lock-step vs model, Phase-1≡Phase-2 equivalence), re-synthesis, baseline-vs-adaptive study, ablation: **done**. Optional FPGA validation: **not done** (it was optional).

## 3. Known limitations (state these in the paper)
1. Fixed-latency behavioural memory; no DRAM, bank, bus or write-buffer effects; single outstanding request; word-aligned accesses.
2. Write-through/no-write-allocate makes every write costly (policy-independent). Absolute AMAT is therefore pessimistic for write-heavy code.
3. Traces are generated address streams (some inspired by matrix, FIR, image kernels) — not processor execution, not SPEC.
4. Several workloads are intentionally adversarial to LRU; Random's frequent wins reflect that choice.
5. Arrays are flip-flops in synthesis (no SRAM); timing is an ABC estimate without wires/clock; no power numbers.
6. **Adaptive rule limitation (diagnosed):** requiring every candidate leader group to have `SAMPLE_N` samples starves the unit when a workload concentrates on few sets (4-way `conflict`: +129 % vs best fixed).
7. **Adaptive timing cost:** combinational window decision lengthens the estimated critical path by 72–86 %.
8. Adaptive pays an exploration cost where LRU is already best (up to +8.9 %).
9. Leader sets are static (index-based); address patterns aliasing with the leader stride bias the samples.
10. Single deterministic run per configuration.

## 4. Suggested next steps (ordered by value)
1. Relax the sample-validity rule (model what-if already shows the benefit) → RTL change → re-verify.
2. Register adaptive inputs (timing) and re-measure with a real STA tool.
3. Run DC/Genus with SRAM macros to obtain power and realistic area ratios.
4. Add real traces (e.g. instruction-set-simulator memory traces of embedded kernels).
5. Optional FPGA demo (policy indicator, counters on LEDs/UART) as the Phase-2 extension.
6. Rotating or randomised leader sets; per-set or per-region statistics.
