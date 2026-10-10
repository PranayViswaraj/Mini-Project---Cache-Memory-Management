//==============================================================================
// valid_array.v
// One valid bit per (way,set). Synchronous active-low reset clears all bits.
// Combinational read of all ways for a given set index; one-bit write port.
//==============================================================================
module valid_array #(
    parameter WAYS    = 2,
    parameter SETS    = 64,
    parameter INDEX_W = 6
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire [INDEX_W-1:0]       rd_index,
    output wire [WAYS-1:0]          rd_valid,
    input  wire                     wr_en,
    input  wire [$clog2(WAYS)-1:0]  wr_way,
    input  wire [INDEX_W-1:0]       wr_index,
    input  wire                     wr_val
);
    reg [SETS-1:0] vbits [0:WAYS-1];
    integer w;

    always @(posedge clk) begin
        if (!rst_n) begin
            for (w = 0; w < WAYS; w = w + 1) vbits[w] <= {SETS{1'b0}};
        end else if (wr_en) begin
            vbits[wr_way][wr_index] <= wr_val;
        end
    end

    genvar g;
    generate
        for (g = 0; g < WAYS; g = g + 1) begin : rd
            assign rd_valid[g] = vbits[g][rd_index];
        end
    endgenerate
endmodule
