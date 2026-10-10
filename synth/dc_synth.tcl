# =============================================================================
# dc_synth.tcl -- Synopsys Design Compiler flow  (PROVIDED, NOT EXECUTED here:
# no commercial licence in the authoring environment).
# Usage:  dc_shell -f synth/dc_synth.tcl   with env vars  LIB_DB  WAYS  ADAPTIVE_EN
# =============================================================================
set LIB_DB  $env(LIB_DB)             ;# e.g. NangateOpenCellLibrary_typical.db or your PDK
set WAYS    [expr {[info exists env(WAYS)]        ? $env(WAYS)        : 2}]
set ADAPT   [expr {[info exists env(ADAPTIVE_EN)] ? $env(ADAPTIVE_EN) : 0}]
set TOP     cache_top
set OUTDIR  results/dc_w${WAYS}_a${ADAPT}
file mkdir $OUTDIR

set target_library $LIB_DB
set link_library   [list * $LIB_DB]

# ---- RTL + elaboration
set rtl [glob rtl/*.v]
analyze -format verilog $rtl
elaborate $TOP -parameters "WAYS=$WAYS,ADAPTIVE_EN=$ADAPT"
current_design $TOP
link
check_design > $OUTDIR/check_design.rpt

# ---- constraints
source synth/constraints.sdc

# ---- optimisation / technology mapping
compile_ultra
# (optional, for per-module area:  compile_ultra -no_autoungroup)

# ---- reports
report_area      -hierarchy        > $OUTDIR/area.rpt
report_cell                       > $OUTDIR/cells.rpt
report_timing    -max_paths 5 -nworst 1 > $OUTDIR/timing.rpt
report_timing    -delay_type min   > $OUTDIR/hold.rpt
report_qor                         > $OUTDIR/qor.rpt
report_power     -hierarchy        > $OUTDIR/power.rpt     ;# vectorless unless a SAIF is read
# SAIF flow:  read_saif -input sim.saif -instance tb_cache_system/dut  before report_power
write -format verilog -hierarchy -output $OUTDIR/cache_top_netlist.v
write_sdc $OUTDIR/cache_top.sdc
exit
