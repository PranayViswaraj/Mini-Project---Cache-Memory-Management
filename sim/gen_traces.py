#!/usr/bin/env python3
"""
gen_traces.py -- deterministic, reproducible memory-access workload generator.

A request is a tuple (op, be, addr, data):  op 0 = read, 1 = write.
Trace file format (one line per request, hex, 72 bits):
        {op[3:0], be[3:0], addr[31:0], data[31:0]}      op F = end of trace

Every workload is a pure function of (name, cache_bytes, ways, line, seed), so all
experiments are exactly reproducible. Some workloads depend on the cache
geometry on purpose (e.g. "conflict" must create WAYS+1 competing lines per set).
Addresses stay below 1 MB (the testbench memory is 2^18 words).
"""
import random, sys, os

LINE = 32
TARGET = 24000          # approximate requests per workload

def R(a):            return (0, 0xF, a & 0xFFFFFFFC, 0)
def W(a, d, be=0xF): return (1, be,  a & 0xFFFFFFFC, d & 0xFFFFFFFF)

# --------------------------------------------------------------------------- basic
def seq(cache, ways, rng, n=TARGET):
    """Sequential word reads over a 32 KB region, repeated (pure spatial locality)."""
    region = 32768 // 4
    return [R((i % region) * 4) for i in range(n)]

def rand(cache, ways, rng, n=TARGET):
    """Uniform random word accesses over 32 KB, 85% reads / 15% writes."""
    out = []
    for _ in range(n):
        a = rng.randrange(0, 32768 // 4) * 4
        out.append(R(a) if rng.random() < 0.85 else W(a, rng.getrandbits(32), rng.choice([0xF, 0x3, 0xC, 0x1, 0x8])))
    return out

def stride(cache, ways, rng, n=TARGET):
    """Stride of 128 B (4 lines) over a 32 KB region, repeated."""
    return [R((i * 128) % 32768) for i in range(n)]

def conflict(cache, ways, rng, n=TARGET):
    """Conflict-heavy: WAYS+1 lines mapping to the SAME set, accessed cyclically,
    for 8 different sets. Cyclic pattern of (ways+1) lines defeats true LRU."""
    way_size = cache // ways
    nl, nsets = ways + 1, 8
    out = []
    while len(out) < n:
        for k in range(nl):
            for s in range(nsets):
                out.append(R(s * LINE + k * way_size))
    return out[:n]

def loop(cache, ways, rng, n=TARGET):
    """High temporal locality: 90% of accesses fall in a hot region of 0.75 x cache
    size (random order), 10% to a cold 64 KB region."""
    hot = int(cache * 0.75) // 4
    out = []
    for _ in range(n):
        if rng.random() < 0.90: out.append(R(rng.randrange(hot) * 4))
        else:                   out.append(R(0x10000 + rng.randrange(65536 // 4) * 4))
    return out

def scanhot(cache, ways, rng, n=TARGET):
    """Scan pollution: a hot set (0.5 x cache) is re-read every round, interleaved
    with a one-time streaming scan larger than the cache. LRU is polluted by the
    scan; keeping some hot lines by chance (Random) can win."""
    L = cache // LINE
    hot_lines = max(L // 2, 1)
    scan_lines = L + L // 4
    out, scan_ptr = [], 0
    while len(out) < n:
        for h in range(hot_lines):
            out.append(R(h * LINE))
        for _ in range(scan_lines):
            out.append(R(0x20000 + (scan_ptr % 8192) * LINE))
            scan_ptr += 1
    return out[:n]

# --------------------------------------------------------------------------- application-inspired
def matmul(cache, ways, rng, n=None, N=32, ROWS=12):
    """C[i][j] = sum_k A[i][k]*B[k][j], first ROWS rows of C. A@0x0000 B@0x1000 C@0x2000."""
    A, B, C = 0x0000, 0x1000, 0x2000
    out = []
    for i in range(ROWS):
        for j in range(N):
            for k in range(N):
                out.append(R(A + (i * N + k) * 4))
                out.append(R(B + (k * N + j) * 4))
            out.append(W(C + (i * N + j) * 4, (i * 1000 + j) ^ 0x5A5A))
    return out

def fir(cache, ways, rng, n=None, TAPS=32, NOUT=370):
    """32-tap FIR: y[n] = sum h[k]*x[n-k]. x@0x0000 h@0x4000 y@0x8000."""
    X, H, Y = 0x0000, 0x4000, 0x8000
    out = []
    for t in range(TAPS, TAPS + NOUT):
        for k in range(TAPS):
            out.append(R(H + k * 4))
            out.append(R(X + (t - k) * 4))
        out.append(W(Y + (t - TAPS) * 4, t * 7919))
    return out

def image(cache, ways, rng, n=None, W_=64, ROWS=39):
    """3x3 convolution over a 64-pixel-wide image (4 B/pixel). in@0x0000 out@0x10000."""
    IN, OUT = 0x0000, 0x10000
    out = []
    for r in range(1, ROWS + 1):
        for c in range(1, W_ - 1):
            for dr in (-1, 0, 1):
                for dc in (-1, 0, 1):
                    out.append(R(IN + ((r + dr) * W_ + (c + dc)) * 4))
            out.append(W(OUT + (r * W_ + c) * 4, r * 131 + c))
    return out

def phase(cache, ways, rng, n=TARGET):
    """Phase-changing workload: loop -> conflict -> scanhot -> loop -> conflict -> scanhot.
    Used to study whether run-time adaptation helps when behaviour changes."""
    seg = n // 6
    out = []
    for f in (loop, conflict, scanhot, loop, conflict, scanhot):
        out += f(cache, ways, rng, seg)
    return out

WORKLOADS = {
    "seq": seq, "rand": rand, "stride": stride, "conflict": conflict, "loop": loop,
    "scanhot": scanhot, "matmul": matmul, "fir": fir, "image": image, "phase": phase,
}

def make(name, cache=4096, ways=2, seed=1):
    # stable across Python runs (no use of hash()): seed mixed with name, size and ways
    rng = random.Random(seed * 1000003 + sum(ord(c) * (i + 1) for i, c in enumerate(name)) * 7919 + cache + (ways << 20))
    return WORKLOADS[name](cache, ways, rng)

def write_trace(path, reqs):
    with open(path, "w") as f:
        for op, be, a, d in reqs:
            f.write("%01x%01x%08x%08x\n" % (op, be, a, d))
        f.write("f00000000000000000\n")

def read_trace(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            v = int(line, 16)
            op = (v >> 68) & 0xF
            if op == 0xF: break
            out.append((op, (v >> 64) & 0xF, (v >> 32) & 0xFFFFFFFF, v & 0xFFFFFFFF))
    return out

if __name__ == "__main__":
    outdir = sys.argv[1] if len(sys.argv) > 1 else "traces"
    os.makedirs(outdir, exist_ok=True)
    for name in WORKLOADS:
        reqs = make(name, 4096, 2)
        write_trace(os.path.join(outdir, "%s_4096_2.hex" % name), reqs)
        print("%-9s %6d requests  (%d reads, %d writes)" % (name, len(reqs),
              sum(1 for r in reqs if r[0] == 0), sum(1 for r in reqs if r[0] == 1)))
