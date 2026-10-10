# 07 — Viva Preparation (answers use this project's actual design and measured numbers)

**Q1. Why write-through + no-write-allocate?** It removes dirty bits, write-back FSM states and eviction write traffic, so the replacement policy is the only thing that changes between experiments, and verification is simpler. Cost: every write stalls (1+LAT cycles) — identical for all policies, so policy comparisons stay fair.

**Q2. Explain the address breakdown for the baseline.** 4 KB / 32 B lines = 128 lines; 2-way → 64 sets. Offset 5 bits (word = bits 4:2), index 6 bits, tag 21 bits (`[31:11]`). 4-way → 32 sets, index 5, tag 22.

**Q3. Hit time and miss penalty?** Hit = 1 cycle (combinational lookup, no stall). Read miss = 1 + 8·LAT stall cycles + the accept cycle; write = 1 + LAT stall. These formulas are checked by the testbench and the reference model on every run.

**Q4. How does LRU work with one bit?** 2-way: bit = which way is LRU; on access to way w set bit = ~w. 4-way true LRU needs recency ranks (8 bits/set).

**Q5. Why is PLRU only meaningful at 4-way?** At 2 ways the tree has one node = exactly LRU. At 4 ways, after A,B,C,D,A the true-LRU victim is B but tree-PLRU evicts C (tested). Measured area: 4-way LRU 2 519 µm² vs PLRU 975 µm² (2.6×).

**Q6. Why can Random beat LRU?** Cyclic access to (ways+1) lines per set makes LRU evict exactly the line needed next → 0 % hits (measured at 4 KB, both associativities), while Random keeps some lines (33 %/60 % hits).

**Q7. What does the adaptive unit do?** Leader sets run fixed policies; at each 2048-access window their equal-sample miss counts are compared; the follower sets switch only after a margin, two consecutive wins and a hold period. No ML, no multipliers.

**Q8. Why hysteresis?** Ablation: total switches over 6 workloads (2-way) fall from 22 (none) to 3 (default) and 1 (strong); the consecutive-confirmation counter is the most effective mechanism. Cost: slower reaction (matmul faster with no hysteresis).

**Q9. Did adaptive win?** Not universally. Versus LRU it was better by >1 % in 16/50 cases per associativity, worse in 6/8; vs the best fixed policy it was within 1 % in about half the cases and up to +129 % worse (4-way `conflict`). Diagnosed cause: PLRU leader sets never sampled → never switches. Fix proposed (model-only what-if +129 % → +37 %).

**Q10. Hardware cost?** +0.39 % / +0.43 % total area (4 KB) but ≈ +23 % / +17 % of non-array logic; estimated critical path +86 % / +72 % (ABC estimate, no wires/clock) because the decision is combinational in the hit-event cycle. Arrays are 97–98 % of area (flop-based, no SRAM).

**Q11. How did you verify it?** Module tests vs independent models (timestamp-LRU, tree-walk PLRU, LFSR period 65 535), 12 directed cache runs, 168 system runs compared request-by-request with a Python reference model, 24 Phase-1≡Phase-2 equivalence runs, gap/robustness runs, lint on six configurations.

**Q12. What bugs did you find?** Mostly testbench/stimulus bugs (diagnosed before fixing): wrong hand-computed expected value; hard-coded 21-bit tag width in a helper (4-way has 22); unsigned `-1` in a log; SystemVerilog keywords as identifiers; an infinite loop on a 2-bit variable; memory-aliasing in a stress trace (two addresses sharing one memory word made cached data legitimately stale). RTL portability bugs found by other tools: Verilator rejected a large nonblocking array reset; Yosys rejected use-before-declaration.

**Q13. What is NOT claimed?** No FPGA/silicon, no commercial-tool results, no power numbers, no DRAM accuracy, no real-processor or SPEC traces, no claim adaptive is universally better.

**Q14. Why not ML?** Hardware cost and complexity; ML appears only as background/future work (literature). The question is whether *lightweight deterministic* hardware suffices.

**Q15. Limitations?** See doc 05 (fixed-latency memory, write-through cost, synthetic traces, flop arrays, timing estimate, starvation rule, static leaders).
