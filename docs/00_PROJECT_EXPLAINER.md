# 00 — What this project is, and what every part does (plain-language guide)

## 1. The idea in one paragraph
A processor is much faster than main memory. A **cache** is a small, fast memory placed between them that
keeps recently used data. When the cache is full, it must decide **which old line to throw away** — the
**replacement policy**. Different programs behave differently, so no policy is best everywhere.
This project (1) builds a complete, verified Verilog cache with three standard policies (**Phase 1**),
then (2) adds a small piece of ordinary digital hardware that watches how the cache is doing and **switches
policy automatically** (**Phase 2**). It then measures honestly whether that was worth the extra hardware.
No machine learning is implemented; ML is only background.

## 2. Cache vocabulary used throughout
| Term | Meaning here |
|---|---|
| Line | 32 bytes (8 words) moved between memory and cache as a unit |
| Set / way | The cache is split into **sets**; each set can hold **2 (or 4) lines** — the "ways". An address can only live in one set, but in any way of that set |
| Tag / index / offset | Address split: **index** picks the set, **tag** identifies which line is stored, **offset** picks the byte/word in the line |
| Hit / miss | Line present / absent. A hit costs 1 cycle; a miss stalls the processor while the line is fetched |
| Refill | Fetching the 8 words of a missing line |
| Replacement (eviction) | Overwriting a valid line to make room |
| Write-through, no-write-allocate | Every write also goes to memory; a write that misses does **not** bring the line into the cache |

## 3. How one request flows (read)
1. The processor presents `cpu_valid, cpu_addr`. `address_decoder` splits the address.
2. `tag_array` and `valid_array` return the tags/valid bits of every way in that set; `hit_miss_logic` compares them with the request tag in parallel.
3. **Hit:** `data_array` returns the word in the same cycle, `cpu_ready` goes high, replacement state is updated. Done in 1 cycle.
4. **Miss:** `replacement_controller` picks a victim (an invalid way first, otherwise by the selected policy). The FSM enters `REFILL`; `memory_interface` fetches 8 words, which are written into the victim way. On the last word the tag and valid bit are written; then `cpu_ready` is raised and the data returned.
5. **Write:** always goes to memory (write-through). If the line is present the cache copy is updated too.
6. `performance_monitor` counts everything (accesses, hits, misses, refills, evictions, stall cycles, memory words).

## 4. The three replacement policies
* **Random** — a 16-bit LFSR (shift register with feedback) gives a *pseudo*-random way. Almost no hardware; immune to nasty access patterns, but ignores history.
* **LRU** — evict the least-recently-used line. 2-way: **one bit per set**. 4-way: a 2-bit recency rank per way. Great for temporal locality, but terrible when a program cycles through *one more line than fit* (it always evicts exactly the line needed next).
* **Pseudo-LRU** — a 3-bit binary tree per set (4-way). Cheaper than true LRU and *different* from it. At 2 ways it would be identical to LRU, so it is only meaningful at 4 ways.
All three keep their state up to date on every access, so switching policy mid-run needs no warm-up.

## 5. Phase 2 — the adaptive idea (no ML)
* A few sets are **leader sets**, permanently assigned *one* policy each (Random / LRU / PLRU). All others are **followers**.
* Execution is cut into **windows** of 2048 accesses. In each window the leaders' **miss counts** are compared — a live, same-workload, same-time comparison of the candidate policies.
* If another policy beats the current one **by a margin**, **for two windows in a row**, and we haven't just switched, the follower sets switch. That is **hysteresis** — it prevents flip-flopping.
* Only counters, comparators and a tiny state machine: no multipliers, no dividers, no neural network.
* Setting `cfg_policy = 11` enables adaptive mode; `00/01/10` give the fixed policies *identical* to Phase 1.

## 6. File-by-file guide
| File | What it does |
|---|---|
| `rtl/cache_top.v` | Top level: wires everything; parameters for size/ways/adaptive |
| `rtl/cache_controller.v` | The FSM (IDLE→REFILL/WRITE→RESPOND), request register, and event pulses |
| `rtl/address_decoder.v` | Splits address into tag/index/offset |
| `rtl/tag_array.v`, `valid_array.v`, `data_array.v` | Storage (valid bits reset to 0) |
| `rtl/hit_miss_logic.v` | Parallel tag comparison → hit and hit way |
| `rtl/replacement_controller.v` | Holds all policy state, invalid-way-first, picks victim by policy code |
| `rtl/random_replacement.v`, `lru_controller.v`, `plru_controller.v` | The three policies |
| `rtl/memory_interface.v` | Refill word counter + word-wide memory port |
| `rtl/performance_monitor.v`, `sat_counter.v` | Ten saturating event counters |
| `rtl/leader_set_map.v`, `adaptive_controller.v` | **Phase 2** adaptive logic |
| `tb/mem_model.v` | Deterministic fixed-latency memory (testbench only) |
| `tb/tb_*.v` | Self-checking testbenches (module, cache-directed, trace-driven system) |
| `sim/ref_model.py` | Independent software cache model (the "golden" reference) |
| `sim/gen_traces.py` | Deterministic workloads (sequential, random, stride, conflict, loop, scan, matmul, FIR, image, phase-change) |
| `sim/run_regression.py` | Runs all tests; compares RTL to the reference model request-by-request |
| `sim/run_experiments.py`, `make_report.py` | Experiment campaign, tables and plots |
| `synth/run_synth.py` | Open-source synthesis (Yosys + Nangate45) |
| `synth/dc_synth.tcl`, `genus_synth.tcl`, `constraints.sdc` | Commercial-tool scripts (**not executed here**) |
| `docs/` | Spec, verification, experiments, hardware cost, viva, paper, timeline |

## 7. How we know it is correct (verification in one page)
1. **Module tests** — each block alone against an *independently coded* model (e.g. LRU vs a timestamp model, PLRU vs a tree-walk model, LFSR period proved = 65 535).
2. **Cache-level directed tests** — hand-derived expectations: miss costs `1+8·LAT` stall cycles, write costs `1+LAT`, byte enables, no-allocate on write miss, back-to-back hits, boundary addresses, reset in the middle of a refill, runtime policy switching.
3. **System tests** — hundreds of runs: the RTL is compared **against the Python model for every single request** (hit/miss, victim way, data, active policy) and for every counter.
4. **Equivalence** — the Phase-1 build and the Phase-2 build produce identical behaviour for the fixed policies.
5. Tests also caught *testbench* mistakes of my own (see `docs/02_verification_report.md`) — each was diagnosed before being fixed.

## 8. What this project does NOT claim
No FPGA implementation or validation in Phase 1; no silicon; no DRAM-accurate timing; no real processor
execution (traces only); no SPEC benchmarks; no claim that adaptive beats fixed policies everywhere — the
results decide that.
