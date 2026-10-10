# 09 — Literature Survey Worksheet (TO BE COMPLETED BY YOU)

I **cannot verify citations** in this environment, so no reference below should be copied into your report
without checking it yourself on IEEE Xplore / ACM DL / the publisher page. Authors, venues, years and titles are
given from memory purely as *search leads*.

## Search leads (verify before citing)
| Topic | Lead (from memory — VERIFY) | Why relevant |
|---|---|---|
| Textbook cache fundamentals | Hennessy & Patterson, *Computer Architecture: A Quantitative Approach* (current edition) | cache organisation, AMAT, write policies |
| Optimal replacement | L. Belady, replacement algorithms for virtual storage, IBM Systems Journal, 1966 | theoretical upper bound |
| Adaptive insertion / set dueling | Qureshi, Jaleel, Patt, Steely, Emer — "Adaptive Insertion Policies for High Performance Caching", ISCA 2007 | leader-set idea this project's adaptive unit is inspired by |
| Re-reference prediction | Jaleel et al. — RRIP, ISCA 2010 | modern low-cost replacement |
| Learning-based replacement | Hawkeye (Jain & Lin, ISCA 2016); perceptron reuse prediction (Teran, Wang, Jiménez, MICRO 2016) | ML context only (not implemented here) |
| FPGA / ASIC cache controllers | search: "configurable cache controller FPGA", "cache controller Verilog replacement policy" | prior hardware implementations |
| Hardware performance counters | search: "cache performance monitoring unit hardware counters" | monitoring infrastructure |

## Survey matrix (fill one row per paper you actually read)
| Ref | Platform (FPGA/ASIC/sim) | Policies | Adaptive? | Hardware cost reported? | Verification shown? | Limitation |
|---|---|---|---|---|---|---|

## Research-gap statement (draft only after the matrix is filled)
State *only* what the matrix supports. Do **not** claim novelty for caches, LRU, Random, PLRU, counters, or adaptive management itself; the contribution here is the **integrated, verified, synthesizable implementation and its measured performance-vs-hardware-cost evaluation**.
