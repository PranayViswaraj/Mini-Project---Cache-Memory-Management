//==============================================================================
// performance_monitor.v
// Hardware cache-performance counters. Every counter is an independent
// saturating counter driven by a SINGLE-CYCLE event pulse from the controller:
//
//  ev_access  : a processor request is ACCEPTED (cpu_valid & cpu_ready)
//               -> exactly one per request, never double counted
//  ev_read/ev_write : accepted request is a read / write
//  ev_hit/ev_miss   : accepted request found its line in the cache / did not
//                     (a write miss with no-write-allocate counts as a miss)
//  ev_refill  : one complete line refill finished
//  ev_replace : a refill overwrote a VALID line (an eviction)
//  ev_stall   : one clock cycle with cpu_valid high and cpu_ready low
//  ev_memrd   : one word read transaction completed on the memory port
//  ev_memwr   : one word write transaction completed on the memory port
//
// Invariants (checked by the testbenches):
//   access = read + write = hit + miss
//   memrd  = refill * WORDS_PER_LINE
//==============================================================================
module performance_monitor #(
    parameter CNT_W = 32
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             cnt_clear,
    input  wire             ev_access, ev_read, ev_write,
    input  wire             ev_hit, ev_miss,
    input  wire             ev_refill, ev_replace,
    input  wire             ev_stall,
    input  wire             ev_memrd, ev_memwr,
    output wire [CNT_W-1:0] cnt_access, cnt_read, cnt_write,
    output wire [CNT_W-1:0] cnt_hit, cnt_miss,
    output wire [CNT_W-1:0] cnt_refill, cnt_replace,
    output wire [CNT_W-1:0] cnt_stall,
    output wire [CNT_W-1:0] cnt_memrd, cnt_memwr,
    output wire             any_saturated
);
    wire [9:0] sat;

    sat_counter #(CNT_W) c_acc (clk, rst_n, cnt_clear, ev_access,  cnt_access,  sat[0]);
    sat_counter #(CNT_W) c_rd  (clk, rst_n, cnt_clear, ev_read,    cnt_read,    sat[1]);
    sat_counter #(CNT_W) c_wr  (clk, rst_n, cnt_clear, ev_write,   cnt_write,   sat[2]);
    sat_counter #(CNT_W) c_hit (clk, rst_n, cnt_clear, ev_hit,     cnt_hit,     sat[3]);
    sat_counter #(CNT_W) c_mis (clk, rst_n, cnt_clear, ev_miss,    cnt_miss,    sat[4]);
    sat_counter #(CNT_W) c_rf  (clk, rst_n, cnt_clear, ev_refill,  cnt_refill,  sat[5]);
    sat_counter #(CNT_W) c_rep (clk, rst_n, cnt_clear, ev_replace, cnt_replace, sat[6]);
    sat_counter #(CNT_W) c_stl (clk, rst_n, cnt_clear, ev_stall,   cnt_stall,   sat[7]);
    sat_counter #(CNT_W) c_mrd (clk, rst_n, cnt_clear, ev_memrd,   cnt_memrd,   sat[8]);
    sat_counter #(CNT_W) c_mwr (clk, rst_n, cnt_clear, ev_memwr,   cnt_memwr,   sat[9]);

    assign any_saturated = |sat;
endmodule
