"""Run the module-level and directed regression suites with Icarus Verilog and
write the results to sim_live/ (leaves results/ untouched)."""
import os, sys, csv
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "sim"))
import run_regression as R

rows = R.run_module() + R.run_directed()
with open(os.path.join(HERE, "live_regression.csv"), "w", newline="") as f:
    w = csv.writer(f); w.writerow(["category", "test", "status", "checks"]); w.writerows(r[:4] for r in rows)
p = sum(r[2] == "PASS" for r in rows)
print("TOTAL %d tests, %d passed, %d failed, %d checks" % (len(rows), p, len(rows) - p, sum(r[3] for r in rows)))
