//==============================================================================
// tag_array.v
// Tag storage: WAYS x SETS entries of TAG_W bits. No reset (validity is held
// in valid_array, so stale tags are never matched). Combinational read of all
// ways for one set; one write port.
//==============================================================================
module tag_array #(
    parameter WAYS    = 2,
    parameter SETS    = 64,
    parameter INDEX_W = 6,
    parameter TAG_W   = 21
)(
    input  wire                     clk,
    input  wire [INDEX_W-1:0]       rd_index,
    output wire [WAYS*TAG_W-1:0]    rd_tags,
    input  wire                     wr_en,
    input  wire [$clog2(WAYS)-1:0]  wr_way,
    input  wire [INDEX_W-1:0]       wr_index,
    input  wire [TAG_W-1:0]         wr_tag
);
    reg [TAG_W-1:0] mem [0:WAYS*SETS-1];

    localparam WAYS_W = $clog2(WAYS);

    always @(posedge clk)
        if (wr_en) mem[{wr_way, wr_index}] <= wr_tag;     // SETS is a power of two

    genvar g;
    generate
        for (g = 0; g < WAYS; g = g + 1) begin : rd
            localparam [WAYS_W-1:0] GW = g;
            assign rd_tags[g*TAG_W +: TAG_W] = mem[{GW, rd_index}];
        end
    endgenerate
endmodule
