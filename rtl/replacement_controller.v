//==============================================================================
// replacement_controller.v
// Holds Random, LRU and (4-way) PLRU state IN PARALLEL and selects the victim
// according to `policy`:
//     00 -> Random      01 -> LRU      10 -> Pseudo-LRU (aliases LRU if 2-way)
//     11 -> reserved for Phase-2 "Adaptive"; falls back to LRU (never undefined)
// All policies' state is updated on every access regardless of which policy is
// selected, so the policy can be changed at run time with no warm-up penalty.
// An INVALID way is always chosen first (lowest-numbered invalid way).
//==============================================================================
module replacement_controller #(
    parameter WAYS    = 2,
    parameter SETS    = 64,
    parameter INDEX_W = 6
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire [1:0]               policy,
    input  wire [INDEX_W-1:0]       lk_index,
    input  wire [WAYS-1:0]          lk_valid,
    input  wire                     victim_adv,      // LFSR advance (victim chosen)
    output wire [$clog2(WAYS)-1:0]  victim,
    input  wire                     upd_en,
    input  wire [INDEX_W-1:0]       upd_index,
    input  wire [$clog2(WAYS)-1:0]  upd_way
);
    localparam WAYS_W = $clog2(WAYS);

    wire [WAYS_W-1:0] rnd_v, lru_v, plru_v;

    random_replacement #(.WAYS(WAYS)) u_rnd (
        .clk(clk), .rst_n(rst_n), .advance(victim_adv), .victim(rnd_v));

    lru_controller #(.WAYS(WAYS), .SETS(SETS), .INDEX_W(INDEX_W)) u_lru (
        .clk(clk), .rst_n(rst_n), .lk_index(lk_index), .victim(lru_v),
        .upd_en(upd_en), .upd_index(upd_index), .upd_way(upd_way));

    generate
        if (WAYS == 4) begin : g_plru
            plru_controller #(.SETS(SETS), .INDEX_W(INDEX_W)) u_plru (
                .clk(clk), .rst_n(rst_n), .lk_index(lk_index), .victim(plru_v),
                .upd_en(upd_en), .upd_index(upd_index), .upd_way(upd_way));
        end else begin : g_noplru
            assign plru_v = lru_v;          // 2-way: PLRU == LRU
        end
    endgenerate

    reg [WAYS_W-1:0] pol_v;
    always @* begin
        case (policy)
            2'b00:   pol_v = rnd_v;
            2'b10:   pol_v = plru_v;
            default: pol_v = lru_v;         // 01 = LRU, 11 = reserved -> LRU
        endcase
    end

    // invalid-way-first allocation
    reg               any_inv;
    reg [WAYS_W-1:0]  first_inv;
    integer i;
    always @* begin
        any_inv   = 1'b0;
        first_inv = {WAYS_W{1'b0}};
        for (i = WAYS-1; i >= 0; i = i - 1)
            if (!lk_valid[i]) begin any_inv = 1'b1; first_inv = i[WAYS_W-1:0]; end
    end

    assign victim = any_inv ? first_inv : pol_v;
endmodule
