//==============================================================================
// lru_controller.v   -- true LRU replacement state
//   2-way : ONE bit per set.  bit=0 -> way0 is LRU, bit=1 -> way1 is LRU.
//   4-way : recency RANK per way (2 bits each, 8 bits/set); rank 0 = MRU,
//           rank 3 = LRU. On an access to way w, every way whose rank is lower
//           than w's old rank is aged by one and w becomes rank 0.
// Reset state: way0 is LRU (4-way ranks: way0=3, way1=2, way2=1, way3=0).
//==============================================================================
module lru_controller #(
    parameter WAYS    = 2,
    parameter SETS    = 64,
    parameter INDEX_W = 6
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire [INDEX_W-1:0]       lk_index,
    output wire [$clog2(WAYS)-1:0]  victim,
    input  wire                     upd_en,
    input  wire [INDEX_W-1:0]       upd_index,
    input  wire [$clog2(WAYS)-1:0]  upd_way
);
    generate
    if (WAYS == 2) begin : g2
        reg [SETS-1:0] lru_bit;
        always @(posedge clk) begin
            if (!rst_n)      lru_bit <= {SETS{1'b0}};
            else if (upd_en) lru_bit[upd_index] <= ~upd_way[0];
        end
        assign victim = lru_bit[lk_index];
    end else begin : g4
        // one 8-bit register per set (generate loop) + flat read bus: tool-independent reset
        wire [8*SETS-1:0] rank_flat;
        integer v;
        reg [7:0] cur, nxt, lk_cur;       // declared before first use (portable across tools)
        reg [1:0] r_acc;
        reg [1:0] vv;
        genvar gs;
        for (gs = 0; gs < SETS; gs = gs + 1) begin : per_set
            localparam [INDEX_W-1:0] ME = gs;
            reg [7:0] r;
            always @(posedge clk) begin
                if (!rst_n)                              r <= 8'b00_01_10_11;
                else if (upd_en && (upd_index == ME))    r <= nxt;
            end
            assign rank_flat[8*gs +: 8] = r;
        end

        always @* begin                       // next-state for the updated set
            cur   = rank_flat[8*upd_index +: 8];
            r_acc = cur[2*upd_way +: 2];
            nxt   = cur;
            for (v = 0; v < 4; v = v + 1)
                if (cur[2*v +: 2] < r_acc) nxt[2*v +: 2] = cur[2*v +: 2] + 2'd1;
            nxt[2*upd_way +: 2] = 2'd0;
        end

        always @* begin                       // victim = way holding rank 3
            lk_cur = rank_flat[8*lk_index +: 8];
            vv = 2'd0;
            for (v = 0; v < 4; v = v + 1)
                if (lk_cur[2*v +: 2] == 2'd3) vv = v[1:0];
        end
        assign victim = vv;
    end
    endgenerate
endmodule
