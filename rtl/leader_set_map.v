//==============================================================================
// leader_set_map.v   (Phase 2)
// Static, combinational classification of a set index as a "leader" set.
// Leader sets are PERMANENTLY run with one fixed candidate policy so their miss
// counts can be compared concurrently (the idea is inspired by "set dueling").
// All other sets are "follower" sets and use the currently selected policy.
//
//   STRIDE = min(16, SETS);  low = index mod STRIDE
//   group 0 (Random): low == 0
//   group 1 (LRU)   : low == STRIDE/4
//   group 2 (PLRU)  : low == STRIDE/2        (only when WAYS == 4)
//   group number == policy code (0 Random, 1 LRU, 2 PLRU)
// Leader fraction per group = 1/STRIDE (6.25 % for >=16 sets).
//==============================================================================
/* verilator lint_off UNUSEDSIGNAL */   // upper index bits are intentionally not used
module leader_set_map #(
    parameter WAYS    = 4,
    parameter INDEX_W = 5
)(
    input  wire [INDEX_W-1:0] index,
    output wire               is_leader,
    output wire [1:0]         grp,
    output wire [1:0]         pol
);
    localparam SETS   = (1 << INDEX_W);
    localparam STRIDE = (SETS < 16) ? SETS : 16;
    localparam SW     = $clog2(STRIDE);

    localparam [SW-1:0] L0 = {SW{1'b0}};
    localparam [31:0]   L1_32 = STRIDE/4;
    localparam [31:0]   L2_32 = STRIDE/2;
    localparam [SW-1:0] L1 = L1_32[SW-1:0];
    localparam [SW-1:0] L2 = L2_32[SW-1:0];

    wire [SW-1:0] low = index[SW-1:0];
    wire g0 = (low == L0);
    wire g1 = (low == L1);
    wire g2 = (WAYS == 4) && (low == L2);

    assign is_leader = g0 | g1 | g2;
    assign grp       = g0 ? 2'd0 : (g1 ? 2'd1 : 2'd2);
    assign pol       = grp;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
