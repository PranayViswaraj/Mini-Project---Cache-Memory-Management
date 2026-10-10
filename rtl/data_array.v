//==============================================================================
// data_array.v
// Cache-line data storage organised as 32-bit words:
//   depth = WAYS * SETS * WORDS_PER_LINE,  address = {way, index, word}
// Combinational read of the selected word in every way; one write port with
// per-byte write enables. No reset (data is qualified by valid bits).
//==============================================================================
module data_array #(
    parameter WAYS    = 2,
    parameter SETS    = 64,
    parameter INDEX_W = 6,
    parameter WORD_W  = 3,
    parameter DATA_W  = 32
)(
    input  wire                     clk,
    input  wire [INDEX_W-1:0]       rd_index,
    input  wire [WORD_W-1:0]        rd_word,
    output wire [WAYS*DATA_W-1:0]   rd_data,
    input  wire                     wr_en,
    input  wire [$clog2(WAYS)-1:0]  wr_way,
    input  wire [INDEX_W-1:0]       wr_index,
    input  wire [WORD_W-1:0]        wr_word,
    input  wire [DATA_W-1:0]        wr_data,
    input  wire [DATA_W/8-1:0]      wr_be
);
    localparam WAYS_W = $clog2(WAYS);
    localparam DEPTH  = WAYS * SETS * (1 << WORD_W);

    reg [DATA_W-1:0] mem [0:DEPTH-1];
    wire [WAYS_W+INDEX_W+WORD_W-1:0] wa = {wr_way, wr_index, wr_word};

    // byte-merge the write data with the old word (combinational)
    wire [DATA_W-1:0] old_word = mem[wa];
    reg  [DATA_W-1:0] merged;
    integer b;
    always @* begin
        for (b = 0; b < DATA_W/8; b = b + 1)
            merged[8*b +: 8] = wr_be[b] ? wr_data[8*b +: 8] : old_word[8*b +: 8];
    end

    always @(posedge clk)
        if (wr_en) mem[wa] <= merged;

    genvar g;
    generate
        for (g = 0; g < WAYS; g = g + 1) begin : rd
            localparam [WAYS_W-1:0] GW = g;
            assign rd_data[g*DATA_W +: DATA_W] = mem[{GW, rd_index, rd_word}];
        end
    endgenerate
endmodule
