//==============================================================================
// hit_miss_logic.v
// Parallel tag comparison. A way matches when it is valid AND its stored tag
// equals the request tag. hit_way is the lowest matching way (at most one way
// can match in a correct cache; the priority only makes the output defined).
//==============================================================================
module hit_miss_logic #(
    parameter WAYS  = 2,
    parameter TAG_W = 21
)(
    input  wire [WAYS*TAG_W-1:0]    rd_tags,
    input  wire [WAYS-1:0]          rd_valid,
    input  wire [TAG_W-1:0]         req_tag,
    output wire                     hit,
    output reg  [$clog2(WAYS)-1:0]  hit_way,
    output wire [WAYS-1:0]          hit_onehot
);
    genvar g;
    generate
        for (g = 0; g < WAYS; g = g + 1) begin : cmp
            assign hit_onehot[g] = rd_valid[g] & (rd_tags[g*TAG_W +: TAG_W] == req_tag);
        end
    endgenerate

    assign hit = |hit_onehot;

    integer i;
    always @* begin
        hit_way = {$clog2(WAYS){1'b0}};
        for (i = WAYS-1; i >= 0; i = i - 1)
            if (hit_onehot[i]) hit_way = i[$clog2(WAYS)-1:0];
    end
endmodule
