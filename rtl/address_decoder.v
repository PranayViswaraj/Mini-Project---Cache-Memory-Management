//==============================================================================
// address_decoder.v
// Splits a 32-bit byte address into TAG / INDEX / OFFSET fields.
// Pure combinational. Baseline (4KB, 2-way, 32B line): 21 / 6 / 5 bits.
//==============================================================================
module address_decoder #(
    parameter ADDR_W   = 32,
    parameter OFFSET_W = 5,
    parameter INDEX_W  = 6
)(
    input  wire [ADDR_W-1:0]                  addr,
    output wire [ADDR_W-OFFSET_W-INDEX_W-1:0] tag,
    output wire [INDEX_W-1:0]                 index,
    output wire [OFFSET_W-1:0]                offset
);
    assign offset = addr[OFFSET_W-1:0];
    assign index  = addr[OFFSET_W+INDEX_W-1:OFFSET_W];
    assign tag    = addr[ADDR_W-1:OFFSET_W+INDEX_W];
endmodule
