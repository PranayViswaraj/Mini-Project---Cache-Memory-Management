"""Write the phase-changing workload trace used for the adaptive-policy waveform."""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "sim"))
import gen_traces as G
reqs = G.make("phase", 4096, 2)
G.write_trace(os.path.join(HERE, "phase_4096_2.hex"), reqs)
print("requests:", len(reqs))
