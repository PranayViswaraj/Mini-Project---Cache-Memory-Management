#!/usr/bin/env python3
"""
ref_model.py -- independent transaction-level reference model of the cache.

Written from the architecture specification (docs/01_architecture_spec.md), NOT by
transliterating the RTL. It models a request stream at transaction level:

    * 4KB..16KB, 2-/4-way set-associative, 32-byte lines
    * WRITE-THROUGH + NO-WRITE-ALLOCATE
    * Random (16-bit LFSR), true LRU, tree PLRU (4-way), Adaptive (Phase 2)
    * invalid-way-first allocation

For every request it predicts: hit/miss, victim way (read misses), read data, and
the policy that was active. For the whole run it predicts all performance counters
and the stall-cycle count from the memory-latency formula
        read miss  : 1 + WPL * LAT   stall cycles
        write      : 1 + LAT         stall cycles (hit or miss; write-through)
        read hit   : 0
"""
import sys
from gen_traces import read_trace

MEM_AW = 18
MEM_MASK = (1 << MEM_AW) - 1

def init_word(idx):
    return ((idx * 0x9E3779B1) & 0xFFFFFFFF) ^ 0xA5A5A5A5

class CacheModel:
    def __init__(self, cache_bytes=4096, ways=2, line=32, policy=1,
                 adaptive_en=True, win=2048, sample_n=64, margin=4, min_hold=1, conf_thresh=2,
                 lat=10, relax_valid=False):
        assert ways in (2, 4)
        self.relax_valid = relax_valid      # MODEL-ONLY what-if: ignore candidates without enough samples
        self.cache, self.ways, self.line, self.policy = cache_bytes, ways, line, policy
        self.wpl = line // 4
        self.sets = cache_bytes // line // ways
        self.offw = line.bit_length() - 1
        self.idxw = self.sets.bit_length() - 1
        self.lat = lat
        self.tags  = [[0] * ways for _ in range(self.sets)]
        self.valid = [[False] * ways for _ in range(self.sets)]
        # replacement state
        self.lfsr = 0xACE1
        if ways == 2: self.lru = [0] * self.sets                       # bit: 1 -> way1 is LRU
        else:         self.lru = [[3, 2, 1, 0] for _ in range(self.sets)]  # rank per way, 3 = LRU
        self.plru = [[0, 0, 0] for _ in range(self.sets)]
        self.mem = {}
        # adaptive
        self.adaptive_en = adaptive_en
        self.win, self.sample_n, self.margin = win, sample_n, margin
        self.min_hold, self.conf_thresh = min_hold, conf_thresh
        self.active = 1
        self.win_cnt = 0
        self.acc = [0, 0, 0]; self.mis = [0, 0, 0]
        self.conf = 0; self.cand_prev = 0; self.hold = 0
        self.ncand = 2 if ways == 2 else 3
        self.stride = min(16, self.sets)
        # stats
        self.s = dict(access=0, read=0, write=0, hit=0, miss=0, refill=0, replace=0,
                      memrd=0, memwr=0, switch=0, window=0, read_miss=0)

    # ---------------------------------------------------------------- memory
    def mem_rd(self, addr):
        i = (addr >> 2) & MEM_MASK
        return self.mem.get(i, init_word(i))
    def mem_wr(self, addr, data, be):
        i = (addr >> 2) & MEM_MASK
        old = self.mem.get(i, init_word(i))
        for b in range(4):
            if (be >> b) & 1:
                old = (old & ~(0xFF << (8 * b))) | (data & (0xFF << (8 * b)))
        self.mem[i] = old

    # ---------------------------------------------------------------- replacement
    def lru_victim(self, st):
        if self.ways == 2: return self.lru[st]
        return self.lru[st].index(3)
    def plru_victim(self, st):
        if self.ways == 2: return self.lru_victim(st)
        b0, b1, b2 = self.plru[st]
        return b1 if b0 == 0 else 2 + b2
    def upd(self, st, way):
        if self.ways == 2:
            self.lru[st] = 1 if way == 0 else 0
        else:
            r = self.lru[st]; ra = r[way]
            for v in range(4):
                if r[v] < ra: r[v] += 1
            r[way] = 0
            t = self.plru[st]
            t[0] = 1 - (way >> 1)
            if (way >> 1) == 0: t[1] = 1 - (way & 1)
            else:               t[2] = 1 - (way & 1)

    # ---------------------------------------------------------------- adaptive
    def leader(self, st):
        """-> policy code if leader set else None"""
        low = st % self.stride
        if low == 0: return 0
        if low == self.stride // 4: return 1
        if self.ways == 4 and low == self.stride // 2: return 2
        return None
    def policy_for(self, st):
        if self.policy == 3 and self.adaptive_en:
            lp = self.leader(st)
            return lp if lp is not None else self.active
        return 1 if self.policy == 3 else self.policy
    def active_shown(self):
        return self.active if (self.policy == 3 and self.adaptive_en) else (1 if self.policy == 3 else self.policy)

    def adaptive_event(self, st, miss):
        if not (self.policy == 3 and self.adaptive_en): return
        lp = self.leader(st)
        nacc, nmis = list(self.acc), list(self.mis)
        if lp is not None and (lp != 2 or self.ncand == 3) and self.acc[lp] < self.sample_n:
            nacc[lp] += 1
            if miss: nmis[lp] += 1
        if self.win_cnt == self.win - 1:                   # window ends with this access
            self.s['window'] += 1
            valid = nacc[0] == self.sample_n and nacc[1] == self.sample_n and \
                    (self.ncand == 2 or nacc[2] == self.sample_n)
            m = [nmis[0], nmis[1], nmis[2] if self.ncand == 3 else nmis[0]]
            if self.relax_valid:             # only compare groups that reached SAMPLE_N; current group must be valid
                ok = [nacc[g] == self.sample_n for g in range(self.ncand)]
                valid = ok[self.active]
                big = 1 << 20
                m = [m[g] if (g < self.ncand and ok[g]) else big for g in range(3)]
            mmin = min(m)
            cur = m[self.active]
            if cur == mmin: best = self.active
            elif m[0] == mmin: best = 0
            elif m[1] == mmin: best = 1
            else: best = 2
            want = valid and best != self.active and cur >= mmin + self.margin
            if self.hold != 0:
                self.hold -= 1; self.conf = 0
            elif want:
                nc = self.conf + 1 if (self.conf != 0 and self.cand_prev == best) else 1
                if nc >= self.conf_thresh:
                    self.active = best; self.hold = self.min_hold; self.conf = 0
                    self.s['switch'] += 1
                else:
                    self.conf = nc; self.cand_prev = best
            else:
                self.conf = 0
            self.win_cnt = 0; self.acc = [0, 0, 0]; self.mis = [0, 0, 0]
        else:
            self.win_cnt += 1; self.acc = nacc; self.mis = nmis

    # ---------------------------------------------------------------- one request
    def access(self, op, be, addr, data):
        """-> (hit, way, rdata, active_policy_shown_before_access)"""
        shown = self.active_shown()
        word_idx = (addr >> 2) & (self.wpl - 1)
        st  = (addr >> self.offw) & (self.sets - 1)
        tag = addr >> (self.offw + self.idxw)
        hitway = None
        for w in range(self.ways):
            if self.valid[st][w] and self.tags[st][w] == tag:
                hitway = w; break
        hit = hitway is not None
        s = self.s
        s['access'] += 1
        way, rdata = -1, 0
        if op == 0:
            s['read'] += 1
            if hit:
                self.upd(st, hitway); way = hitway
            else:
                pol = self.policy_for(st)
                inv = [w for w in range(self.ways) if not self.valid[st][w]]
                if inv:
                    victim = inv[0]
                else:
                    if pol == 0:   victim = self.lfsr & (self.ways - 1)
                    elif pol == 2: victim = self.plru_victim(st)
                    else:          victim = self.lru_victim(st)
                bit = (self.lfsr ^ (self.lfsr >> 2) ^ (self.lfsr >> 3) ^ (self.lfsr >> 5)) & 1
                self.lfsr = (self.lfsr >> 1) | (bit << 15)          # advances on every read miss
                if self.valid[st][victim]: s['replace'] += 1
                self.tags[st][victim] = tag; self.valid[st][victim] = True
                self.upd(st, victim)
                s['refill'] += 1; s['memrd'] += self.wpl; s['read_miss'] += 1
                way = victim
            rdata = self.mem_rd(addr)
        else:
            s['write'] += 1; s['memwr'] += 1
            self.mem_wr(addr, data, be)
            if hit: self.upd(st, hitway)
        s['hit' if hit else 'miss'] += 1
        self.adaptive_event(st, not hit)
        return hit, way, rdata, shown

    def run(self, trace):
        log = []
        for i, (op, be, a, d) in enumerate(trace):
            hit, way, rd, act = self.access(op, be, a, d)
            log.append((i, op, a, int(hit), way, rd if op == 0 else 0, act))
        s = self.s
        s['stall'] = s['read_miss'] * (1 + self.wpl * self.lat) + s['write'] * (1 + self.lat)
        s['cycles'] = s['access'] + s['stall']
        return log, s

def parse_stat(line):
    d = {}
    for tok in line.split()[1:]:
        k, v = tok.split("=")
        d[k] = int(v)
    return d

def parse_log(path):
    out = []
    for line in open(path):
        p = line.split()
        out.append((int(p[0]), int(p[1]), int(p[2], 16), int(p[3]), int(p[4]), int(p[5], 16), int(p[6])))
    return out

if __name__ == "__main__":
    # usage: ref_model.py trace.hex cache_bytes ways policy lat
    tr = read_trace(sys.argv[1])
    m = CacheModel(int(sys.argv[2]), int(sys.argv[3]), policy=int(sys.argv[4]), lat=int(sys.argv[5]))
    _, st = m.run(tr)
    print(st)
