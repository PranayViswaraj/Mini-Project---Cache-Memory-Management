# =============================================================================
# constraints.sdc  -- timing constraints for cache_top (Design Compiler / Genus)
# Adjust CLK_PERIOD_NS to the target. All numbers are ASSUMPTIONS to be
# documented with the results; they are not measured values.
# =============================================================================
set CLK_PERIOD_NS 5.0              ;# 200 MHz target (assumption)
create_clock -name clk -period $CLK_PERIOD_NS [get_ports clk]
set_clock_uncertainty 0.15 [get_clocks clk]
set_clock_transition  0.10 [get_clocks clk]

# processor-side and memory-side interface timing budgets (60% of the period)
set IN_DELAY  [expr {0.6 * $CLK_PERIOD_NS}]
set OUT_DELAY [expr {0.6 * $CLK_PERIOD_NS}]
set data_inputs [remove_from_collection [all_inputs] [get_ports {clk rst_n}]]
set_input_delay  $IN_DELAY  -clock clk $data_inputs
set_input_delay  [expr {0.2 * $CLK_PERIOD_NS}] -clock clk [get_ports rst_n]
set_output_delay $OUT_DELAY -clock clk [all_outputs]

# drive / load assumptions (replace by library-specific cells)
# set_driving_cell -lib_cell BUF_X2 $data_inputs
# set_load 0.02 [all_outputs]
