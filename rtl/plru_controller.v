//==============================================================================
// plru_controller.v  -- tree Pseudo-LRU for 4-way caches (3 bits per set)
//
//            b0                 b0 = 0 : victim is in the LEFT  pair (ways 0,1)
//          /    \               b0 = 1 : victim is in the RIGHT pair (ways 2,3)
//        b1      b2             b1 / b2 select the victim inside a pair
//       /  \    /  \            (0 -> lower way, 1 -> upper way)
//      w0  w1  w2  w3
//
// On an access to way w = {w1,w0}: point every node on the path AWAY from w:
//      b0 <= ~w1 ;  (w1==0) ? b1 <= ~w0 : b2 <= ~w0
// Reset: all zero (victim = way0). For 2-way caches PLRU degenerates to LRU, so
// this module is only instantiated when WAYS == 4.
//==============================================================================
module plru_controller #(
    parameter SETS    = 64,
    parameter INDEX_W = 6
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire [INDEX_W-1:0] lk_index,
    output wire [1:0]         victim,
    input  wire               upd_en,
    input  wire [INDEX_W-1:0] upd_index,
    input  wire [1:0]         upd_way
);
    // one 3-bit register per set (generate loop) + flat read bus: tool-independent reset
    wire [3*SETS-1:0] tree_flat;
    reg  [2:0] tn;                      // declared before first use (portable across tools)
    genvar gs;
    generate
        for (gs = 0; gs < SETS; gs = gs + 1) begin : per_set
            localparam [INDEX_W-1:0] ME = gs;
            reg [2:0] t;
            always @(posedge clk) begin
                if (!rst_n)                              t <= 3'b000;
                else if (upd_en && (upd_index == ME))    t <= tn;
            end
            assign tree_flat[3*gs +: 3] = t;
        end
    endgenerate

    wire [2:0] t  = tree_flat[3*lk_index +: 3];
    assign victim = (t[0] == 1'b0) ? {1'b0, t[1]} : {1'b1, t[2]};

    wire [2:0] tu = tree_flat[3*upd_index +: 3];
    always @* begin
        tn    = tu;
        tn[0] = ~upd_way[1];
        if (upd_way[1] == 1'b0) tn[1] = ~upd_way[0];
        else                    tn[2] = ~upd_way[0];
    end
endmodule
