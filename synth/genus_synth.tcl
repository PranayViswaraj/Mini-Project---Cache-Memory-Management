# =============================================================================
# genus_synth.tcl -- Cadence Genus flow (PROVIDED, NOT EXECUTED here).
# Usage:  genus -f synth/genus_synth.tcl   with env vars  LIB_LIB  WAYS  ADAPTIVE_EN
# =============================================================================
set LIB   $env(LIB_LIB)
set WAYS  [expr {[info exists env(WAYS)]        ? $env(WAYS)        : 2}]
set ADAPT [expr {[info exists env(ADAPTIVE_EN)] ? $env(ADAPTIVE_EN) : 0}]
set OUTDIR results/genus_w${WAYS}_a${ADAPT}
file mkdir $OUTDIR

set_db library $LIB
read_hdl -v2001 [glob rtl/*.v]
elaborate cache_top -parameters [list [list WAYS $WAYS] [list ADAPTIVE_EN $ADAPT]]
read_sdc synth/constraints.sdc
set_db syn_generic_effort medium
set_db syn_map_effort     medium
set_db syn_opt_effort     medium
syn_generic
syn_map
syn_opt

report_area   > $OUTDIR/area.rpt
report_timing > $OUTDIR/timing.rpt
report_power  > $OUTDIR/power.rpt
report_gates  > $OUTDIR/gates.rpt
write_hdl > $OUTDIR/cache_top_netlist.v
write_sdc > $OUTDIR/cache_top.sdc
exit
