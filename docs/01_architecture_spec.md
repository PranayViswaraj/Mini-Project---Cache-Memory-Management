# 01 — Architecture Specification (FROZEN)

*Project:* Lightweight Reconfigurable Cache Controller with Conventional Replacement Policies (Phase 1)
and its Runtime-Adaptive Extension (Phase 2), for a 32-bit processor.
*This document is the single source of truth. RTL, testbenches, the Python reference model and all
experiments follow it. Any change must be logged in §12 (what / why / affected RTL / tests /
measurements / effect on Phase 2).*

---

## 1. Frozen configuration

| Item | Frozen value | Why |
|---|---|---|
| Address width | 32 bit (byte address, word-aligned accesses, `addr[1:0]` ignored) | 32-bit processor |
| Data width | 32 bit | 32-bit processor |
| Cache type | Data cache, single level, single outstanding request | simplest correct baseline |
| Baseline size / line / ways | **4 KB / 32 B / 2-way** | assignment baseline |
| Parameter range | size 1–16 KB, ways ∈ {2,4}, power-of-two geometry, ≥ 8 sets | keeps address maths + leader sets valid; illegal values fail elaboration |
| **Write policy** | **Write-through + no-write-allocate** | see §2 |
| Replacement | 00 Random · 01 LRU · 10 Pseudo-LRU · 11 reserved / Adaptive | see §6 |
| Memory protocol | request/ready, one 32-bit word per transaction, fixed latency `LAT` cycles/word | see §4 |
| Reset | synchronous, active-low `rst_n`; clears valid bits, replacement state, counters, FSM | |
| HDL | synthesizable Verilog-2005 | |

## 2. Write-policy decision (frozen)

Candidates: (a) write-through + no-write-allocate, (b) write-through + write-allocate, (c) write-back + write-allocate.

| Criterion | (a) WT+NWA | (b) WT+WA | (c) WB+WA |
|---|---|---|---|
| Dirty bits / write-back path | none | none | needed |
| FSM states | 4 | ≥ 5 | ≥ 6 (evict + refill) |
| Verification effort | low | medium | high (data-loss bugs) |
| Memory-port traffic | every write | every write + refill | fewer writes |
| Policy-comparison cleanliness | write cost identical for every replacement policy | writes allocate → policy interacts with writes | dirty evictions couple policy to write traffic |
| Phase-2 compatibility | excellent | good | good |

**Chosen (a).** It removes dirty-state and write-back complexity so that the *replacement policy* is
the only thing that differs between experiments, which is exactly what the research question needs.
Consequence (stated honestly, also in the paper's limitations): every write stalls for the memory
write, so write-heavy workloads show lower absolute performance than a write-back/write-buffer design.
This cost is *the same for all replacement policies*, so policy comparisons stay fair.

## 3. Address breakdown (all values re-computed by script)

`Lines = Size/Line`, `Sets = Lines/Ways`, `Offset = log2(Line)`, `Index = log2(Sets)`, `Tag = 32 − Offset − Index`.

| Size | Ways | Lines | Sets | Offset | Index | Tag |
|---:|---:|---:|---:|---:|---:|---:|
| 1 KB | 2 | 32 | 16 | 5 | 4 | 23 |
| 2 KB | 2 | 64 | 32 | 5 | 5 | 22 |
| **4 KB** | **2** | **128** | **64** | **5** | **6** | **21** |
| 8 KB | 2 | 256 | 128 | 5 | 7 | 20 |
| 16 KB | 2 | 512 | 256 | 5 | 8 | 19 |
| 1 KB | 4 | 32 | 8 | 5 | 3 | 24 |
| 2 KB | 4 | 64 | 16 | 5 | 4 | 23 |
| 4 KB | 4 | 128 | 32 | 5 | 5 | 22 |
| 8 KB | 4 | 256 | 64 | 5 | 6 | 21 |
| 16 KB | 4 | 512 | 128 | 5 | 7 | 20 |

Baseline field layout: `[31:11] TAG(21) | [10:5] INDEX(6) | [4:0] OFFSET(5)`;
`OFFSET[4:2]` = word within line (8 words per line), `OFFSET[1:0]` unused.
Worked example `0x12345678` → offset `0x18`, index `0x33`, tag `0x2468A` (checked in `tb_address_decoder`).

## 4. Interfaces

### 4.1 Processor side
| Signal | Dir | Meaning |
|---|---|---|
| `cpu_valid` | in | request present; **must stay high with stable fields until `cpu_ready`** |
| `cpu_we` | in | 1 = write, 0 = read |
| `cpu_addr[31:0]` | in | byte address (word aligned) |
| `cpu_wdata[31:0]`, `cpu_be[3:0]` | in | write data and byte enables |
| `cpu_ready` | out | request completes this cycle (`cpu_rdata` valid for reads) |
| `cpu_rdata[31:0]` | out | read data |

*One cache access* = one cycle with `cpu_valid & cpu_ready` (request **acceptance**).
*One stall cycle* = one cycle with `cpu_valid & ~cpu_ready`. Request *presentation* never counts by itself,
so no transaction can be counted twice.

### 4.2 Memory side
`mem_valid, mem_we, mem_addr, mem_wdata, mem_be` (out); `mem_ready, mem_rdata` (in).
Master holds `mem_valid` with stable attributes; the transaction completes on the clock edge where
`mem_valid & mem_ready`. The testbench memory (`tb/mem_model.v`) makes every word cost exactly
`LAT` cycles (`LAT = 1` ⇒ zero wait states). It is a **fixed-latency behavioural model, not DRAM**.
Initial word *i* = `(i·0x9E3779B1) ⊕ 0xA5A5A5A5`; the 2^18-word array aliases addresses on `addr[19:2]`.

### 4.3 Configuration / status
`cfg_policy[1:0]` (change only between requests), `cnt_clear`, `policy_active[1:0]`, performance counters (§7),
`cnt_switch`, `cnt_window` (Phase 2; constant 0 in the Phase-1 build).

## 5. FSM (binary-encoded, 2 bits)

| State | Entry | Outputs / actions | Exit |
|---|---|---|---|
| `S_IDLE` (0) | reset; after `S_RESP` | combinational lookup of `cpu_addr`. **Read hit:** `cpu_ready=1` same cycle, update replacement state, stay. | read miss → `S_RF` (latch request, latch victim, advance LFSR); write hit/miss → `S_WR` (on a hit the cache word is written now) |
| `S_RF` (1) | read miss | `op_refill=1`; every returned word is written into the victim way; **last word:** write tag, set valid, update replacement state, `ev_refill` (+`ev_replace` if victim was valid) | `refill_done` → `S_RESP` |
| `S_WR` (2) | any write | `op_write=1` (write-through) | `wr_done` → `S_RESP` |
| `S_RESP` (3) | memory op finished | `cpu_ready=1`, request accepted, hit/miss counted | → `S_IDLE` |

Timing (cycles): read hit **1**; read miss **1 + 8·LAT stall + 1 accept** (miss penalty beyond hit time = 1 + 8·LAT);
write **1 + LAT stall + 1 accept**. While in `S_RF` no lookup happens, so the half-overwritten victim line is never visible.

## 6. Replacement policies

Policy state for **all** policies is updated on **every** access regardless of the selected policy, so the
policy can change at run time without warm-up. An **invalid way is always allocated first** (lowest index).

| Code | Policy | State | Notes |
|---|---|---|---|
| 00 | Random | 16-bit Fibonacci LFSR, x¹⁶+x¹⁴+x¹³+x¹¹+1, shift right, feedback b0⊕b2⊕b3⊕b5, reset `0xACE1`, period 65 535 (proved by test), advances **once per read-miss victim selection**, victim = low log₂(WAYS) bits | pseudo-random, *not* true random |
| 01 | LRU | 2-way: **1 bit/set** (0 ⇒ way0 is LRU). 4-way: 2-bit recency rank per way (8 bits/set), rank 3 = LRU | exact LRU |
| 10 | Pseudo-LRU | 4-way tree, 3 bits/set; update points every node on the path *away* from the touched way | at 2-way PLRU ≡ LRU, so code 10 aliases LRU (no fabricated difference) |
| 11 | Adaptive (Phase 2) | see §9; in the Phase-1 build it is reserved and **falls back to LRU** | no unsupported value is undefined |

PLRU vs LRU distinguishing sequence (4-way, ways 0–3 filled by A,B,C,D, then A touched, then E missed):
true LRU evicts **B** (way1), tree-PLRU evicts **C** (way2). This is verified in `tb_plru_controller` and `tb_cache_directed` (T12).

## 7. Performance counters (32-bit, **saturating**, synchronous clear)

| Counter | Increment event (single-cycle pulse) |
|---|---|
| `cnt_access` | accepted request |
| `cnt_read` / `cnt_write` | accepted read / write |
| `cnt_hit` / `cnt_miss` | accepted request whose line was / was not in the cache at lookup (a write miss counts as a miss) |
| `cnt_refill` | completed line refill |
| `cnt_replace` | refill that overwrote a **valid** line (eviction) |
| `cnt_stall` | cycle with `cpu_valid & ~cpu_ready` |
| `cnt_memrd` / `cnt_memwr` | completed memory read word / write word |

Reset value 0; overflow = saturate at `2³²−1` (flag `cnt_saturated`); a `cnt_clear` coinciding with an event drops that event.
Invariants verified by every system test: `access = read+write = hit+miss`, `memrd = 8·refill`, `memwr = write`.

Derived metrics (always from raw counters): hit rate = hit/access; miss rate = miss/access;
**measured AMAT = (access + stall)/access cycles** (hit time 1 cycle, back-to-back requests);
theoretical `AMAT = 1 + MR·MP` is reported separately and only where the timing model matches
(read-only workloads: `MP = 1 + 8·LAT`).

## 8. RTL hierarchy

```
cache_top
├── address_decoder          tag/index/offset split
├── tag_array  valid_array  data_array
├── hit_miss_logic           parallel tag compare
├── replacement_controller   (holds all policy state, selects victim)
│     ├── random_replacement     LFSR
│     ├── lru_controller         1-bit (2-way) / rank (4-way)
│     └── plru_controller        tree (4-way only)
├── adaptive_controller      PHASE 2 only (ADAPTIVE_EN=1)
│     └── leader_set_map
├── cache_controller         FSM + request register + event pulses
├── memory_interface         refill word counter + memory port
└── performance_monitor      10 × sat_counter
```

## 9. Phase-2 adaptive algorithm (specification)

Goal: choose among the policies that exist (2-way: Random, LRU; 4-way: Random, LRU, PLRU) using only
counters and comparators — **no ML, no multipliers, no dividers**.

1. **Leader sets** (`leader_set_map`): with `STRIDE = min(16, SETS)`, set index `i` is a leader for
   Random if `i mod STRIDE = 0`, LRU if `= STRIDE/4`, PLRU if `= STRIDE/2` (4-way only). Leaders *always*
   run their fixed policy; all other (follower) sets run the active policy. (Idea inspired by set dueling.)
2. **Observation window**: `WIN_ACCESSES` accepted requests (default 2048).
3. **Equal-sample counting**: each leader group counts misses over its first `SAMPLE_N` (default 64)
   accesses in the window, so raw miss counts are directly comparable without division.
4. **Decision at window end** (evaluated on the next counter values so it takes effect for the very next request):
   - `best` = candidate with the fewest misses (ties keep the current policy);
   - `want` ⇔ all groups have `SAMPLE_N` samples **and** `best ≠ current` **and** `cur_miss ≥ best_miss + MARGIN`;
   - **hysteresis:** `want` must hold for `CONF_THRESH` consecutive windows for the *same* candidate
     (saturating confidence counter), and no switch is allowed for `MIN_HOLD` windows after a switch.
5. Defaults: `MARGIN=4, CONF_THRESH=2, MIN_HOLD=1`; setting `CONF_THRESH=1, MIN_HOLD=0, MARGIN=0` disables hysteresis (ablation).
6. Reset policy = LRU. Counters `cnt_switch`, `cnt_window` are provided.
7. `cfg_policy = 00/01/10` bypass the adaptive unit and behave **bit-for-bit like Phase 1** (verified by regression).

## 10. Phase-1 → Phase-2 handoff (what is reused unchanged)

`cache_top` (one added parameter `ADAPTIVE_EN`), `cache_controller`, `tag/valid/data_array`, `hit_miss_logic`,
`replacement_controller`, `random/lru/plru`, `performance_monitor`, `memory_interface`: **no functional change**.
Added for Phase 2: `adaptive_controller`, `leader_set_map`. The adaptive unit consumes the *same event pulses*
(`ev_access`, `ev_miss`) that feed the performance monitor.

## 11. Known limitations (carried into the paper)

* Fixed-latency behavioural memory, not DRAM; no write buffer; single outstanding request; word-aligned access only.
* Traces are memory-address traces, not processor execution.
* Data/tag arrays are modelled as flip-flop arrays in synthesis (no SRAM macros), which dominates area numbers.
* The adaptive unit is evaluated with a transaction-level reference model **and** RTL, but on synthetic/application-inspired traces, not SPEC.

## 12. Change log

| # | What changed | Why | Affected RTL / tests / measurements | Effect on Phase 2 |
|---|---|---|---|---|
| — | *(none since freeze)* | | | |
