#!/usr/bin/env bash
# Build and run the waveform scenarios with Icarus Verilog -> sim_live/waves/*.vcd
set -e
cd "$(dirname "$0")"
export PATH="/c/Users/vpran/tools/iverilog/bin:$PATH"
RTL=$(ls ../rtl/*.v)
mkdir -p waves build
for W in 2 4; do
  iverilog -g2012 -I../tb -o build/dir_${W}w.vvp -s tb_cache_directed -s wave_dump_directed \
    -Ptb_cache_directed.WAYS=$W -Ptb_cache_directed.ADAPTIVE_EN=1 $RTL ../tb/mem_model.v ../tb/tb_cache_directed.v wave_dump_directed.v
  vvp -n build/dir_${W}w.vvp +LAT=4 +VCD=waves/directed_${W}way.vcd | tee waves/directed_${W}way.log
done
python gen_phase_trace.py
iverilog -g2012 -I../tb -o build/sys_phase.vvp -s tb_cache_system -s wave_dump_system \
  -Ptb_cache_system.WAYS=2 -Ptb_cache_system.ADAPTIVE_EN=1 $RTL ../tb/mem_model.v ../tb/tb_cache_system.v wave_dump_system.v
vvp -n build/sys_phase.vvp +TRACE=phase_4096_2.hex +POLICY=3 +LAT=4 +VCD=waves/adaptive_phase.vcd | tee waves/adaptive_phase.log
ls -la waves
