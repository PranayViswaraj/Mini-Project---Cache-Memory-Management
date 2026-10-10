# 06 — 4-to-6-Month Execution Plan (and what is already in this package)

**How to use this package honestly:** the RTL, testbenches, reference model, experiments and analysis in this
repository are a *complete working reference implementation*. For a final-year project you must still
understand, reproduce and be able to defend every part, finish the pieces that need your institution
(literature survey, licensed tools), and write the report. Do not present work you cannot explain.

| Month | Goal | Activities | Evidence / deliverable | In this package? |
|---|---|---|---|---|
| **1** | Foundations + requirements | Learn cache theory (tag/index/offset, write policies, replacement); read the architecture spec; **literature survey** (worksheet in doc 09); define research gap and question | Requirement list, survey matrix, problem statement | Spec ✔ · **survey: you** |
| **2** | Phase-1 RTL | Re-derive and re-implement modules one at a time (decoder → arrays → hit/miss → policies → counters → FSM → top); write module testbenches as you go | RTL + passing module tests | RTL + TBs ✔ (reproduce them yourself) |
| **3** | Phase-1 verification + reference model | Write your own reference model, directed tests (hit/miss/refill/replace/stall/reset), lint, trace-driven lock-step comparison | Verification report with coverage of the test list | ✔ (`02`) |
| **4** | Synthesis + baseline study; **Phase-1 freeze** | Synthesise (DC/Genus at your university; Yosys flow provided), collect area/timing/power; run baseline workloads | Frozen Phase-1 baseline + dataset | Open-source synthesis ✔ · **DC/Genus + power: you** |
| **5** | Phase 2 adaptive | Implement observation window, leader/comparison logic, hysteresis; extend verification; equivalence with Phase 1 | Adaptive RTL + tests | ✔ |
| **6** | Evaluation + writing + viva | Adaptive-vs-baseline experiments, ablation, hardware-cost comparison, limitations, IEEE-style paper, slides, viva rehearsal | Report, paper draft, presentation | Results + draft ✔ · **writing/ownership: you** |

**4-month compression:** merge months 1–2 (survey in parallel with RTL) and months 5–6 (ablation optional).
**6-month extras:** FPGA demonstration of the adaptive unit (optional Phase-2 extension), relaxed-validity rule + timing-pipelined variant (see doc 05), real traces.

## Weekly gates (suggested)
Spec frozen (end wk 3) → module tests green (wk 8) → cache directed tests green (wk 10) → Phase-1 baseline frozen (wk 14) → adaptive unit tests green (wk 18) → experiments final (wk 21) → draft complete (wk 23).

## Risk register
| Risk | Mitigation |
|---|---|
| Licensed tools unavailable | Yosys + Nangate45 flow in `synth/`; state limits (no power) explicitly |
| Scope creep (ML, FPGA, prefetch) | Spec is frozen; extras only after the baseline is stable |
| Results disappoint ("adaptive doesn't win") | That is a valid, publishable finding; the research question is explicitly open (see doc 03) |
| Unverified references | Use the worksheet; verify every citation on IEEE Xplore / ACM DL |
| Test bugs mistaken for RTL bugs | Diagnose first (this project had 10 testbench/stimulus bugs and 2 RTL-portability bugs — see doc 02) |
