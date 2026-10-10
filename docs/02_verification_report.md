# 02 — Verification Report

## 1. Strategy
1. **Module level** — each block against an *independently coded* model.
2. **Cache level (directed + corner)** — hand-derived expected values for every scenario in the verification plan.
3. **System level** — trace-driven, self-checking testbench (shadow memory) **plus** lock-step comparison with an independent Python reference model: *every request* (hit/miss, victim way, data, active policy) and *every counter*, including stall cycles and the adaptive unit's switch/window counts.
4. **Equivalence** — the Phase-1 build (`ADAPTIVE_EN=0`) vs the Phase-2 build for fixed policies must be identical.
5. **Robustness** — idle gaps and random gaps between requests must not change behaviour.
6. **Lint** — Verilator `-Wall` clean on six configurations (2/4-way, 1/4/16 KB, Phase 1/2); illegal parameters (e.g. `WAYS=3`) fail at elaboration.
Tools: Icarus Verilog 12 (4-state, module + directed), Verilator 5 (2-state, long traces; per-request logs were cross-checked **bit-identical** to Icarus on a 24 k-request run), Python 3.

## 2. Final regression (run on the final RTL)
| Category | Tests | Passed | Failed | Checks / requests |
|---|---:|---:|---:|---:|
| module | 10 | 10 | 0 | 288785 |
| directed | 12 | 12 | 0 | 32850 |
| system | 168 | 168 | 0 | 3705520 |
| equivalence | 24 | 24 | 0 | 0 |
| robustness | 4 | 4 | 0 | 0 |

**Total: 218 tests, 218 passed, 0 failed**


Reproduce: `python3 sim/run_regression.py --all` (≈10 min on one core).

## 3. What the tests cover (verification-plan mapping)
| Required behaviour | Where verified |
|---|---|
| Reset (valid, counters, FSM, policy state, LFSR seed) | directed T1, T15; module tests |
| Read hit / read miss / write hit / write miss | directed T2–T6; system |
| Refill (8 words ascending, tag/valid/data updated) | directed T2; `tb_memory_interface` |
| Replacement + invalid-way-first | directed T7–T9; `tb_replacement_controller` |
| LRU exactness | `tb_lru_controller` (6 000 random updates vs timestamp model, 2- and 4-way) |
| PLRU vs LRU difference | `tb_plru_controller`, directed T12 |
| LFSR (period 65 535, no lock-up, distribution) | `tb_random_replacement` (131 k checks) |
| Stall cycles and hit time | directed T2–T6, T11; every system run vs formula |
| Byte enables, write-through, no-allocate | directed T4–T6 |
| Counters (invariants, clear priority, saturation) | `tb_perf_monitor`, system invariants |
| Boundary addresses, same-index/different-tag | directed T10; system `stress` (pseudo-random upper address bits) |
| Back-to-back hits | directed T11 |
| Reset in the middle of a refill | directed T15 |
| Runtime policy switching | directed T14, system |
| Adaptive window / hysteresis / min-hold / margin / insufficient samples / enable / 2-way vs 4-way candidates | `tb_adaptive_controller` (hand-derived expectations) + system lock-step |
| Phase-2 does not disturb Phase-1 | equivalence runs |

## 4. Bug log (honest record; each was diagnosed *before* any change)
| # | Symptom | Root cause | Where |
|---|---|---|---|
| 1 | address-decoder worked example failed | my hand-computed index (0x2B) was wrong; true value 0x33 (2 000 random vectors against an independent model passed) | testbench |
| 2 | perf-monitor TB did not compile | instance named `small` — a Verilog keyword | testbench |
| 3 | memory-interface "refill_done" check failed | sampled after the clock edge, when the pulse had already ended | testbench |
| 4–5 | replacement TB syntax errors | identifiers `alias`, `before` are SystemVerilog keywords | testbench |
| 6 | replacement TB hung | 2-bit loop variable can never reach 4 | testbench |
| 7 | directed TB compile error | garbled concatenation expression | testbench |
| 8 | 4-way directed T10 failed | helper hard-coded a 21-bit tag; a 4 KB 4-way cache has a 22-bit tag (the cache was right) | testbench |
| 9 | all write requests mismatched in logs | `-1` printed as unsigned 4294967295 by a mixed-sign ternary | testbench |
| 10 | 16 `stress` runs failed (TB self-check too) | stimulus used high addresses that **alias** in the 2^18-word test memory, so two cached lines legitimately disagree with one shared memory word; stimulus rebuilt so each word has exactly one address | stimulus |
| 11 | Verilator rejected LRU/PLRU reset | nonblocking array reset inside a `for` loop is unsupported for large arrays → restructured to one register per set | **RTL portability** |
| 12 | Yosys rejected the new LRU/PLRU | signal used before declaration (accepted by Icarus/Verilator) → declarations moved | **RTL portability** |
No functional RTL bug was found by the tests; both RTL changes were tool-portability fixes, after which **module, directed and the full 218-test regression were re-run**. A 13th item — the parser bug that dropped parameterised-module areas from the synthesis table — was found by a sum-of-modules ≠ total cross-check and fixed (totals were always correct).

## 5. Limits of this verification
No formal proof; no SystemVerilog assertions/functional-coverage database (directed + randomized lock-step instead); the reference model shares the *author's understanding of the spec* (independent code, not an independent specification); traces are finite and synthetic; Verilator is 2-state (X-checks rely on the Icarus runs).
