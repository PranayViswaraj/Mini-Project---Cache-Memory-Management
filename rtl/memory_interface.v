//==============================================================================
// memory_interface.v
// Converts the cache controller's two memory operations into the simple
// word-wide request/ready protocol of the main-memory port:
//
//   REFILL : read the 8 words of one cache line, in ascending address order
//   WRITE  : write one word (write-through), with byte enables
//
// Memory port protocol (single outstanding transaction):
//   * master raises mem_valid with stable mem_we/addr/wdata/be
//   * slave raises mem_ready (same cycle as the last wait state) together with
//     mem_rdata (reads); the transaction completes at that clock edge
//   * a word costs exactly LATENCY cycles (LATENCY>=1; 1 = zero wait states)
//
// The refill word counter lives here, so the controller FSM only needs
// "start / wait for refill_done".
//==============================================================================
/* verilator lint_off UNUSEDSIGNAL */   // refill_addr[OFFSET_W-1:0], wr_addr[1:0]: word-aligned by design
module memory_interface #(
    parameter ADDR_W   = 32,
    parameter DATA_W   = 32,
    parameter OFFSET_W = 5
)(
    input  wire                  clk,
    input  wire                  rst_n,
    // controller side
    input  wire                  op_refill,
    input  wire [ADDR_W-1:0]     refill_addr,     // any byte address inside the line
    input  wire                  op_write,
    input  wire [ADDR_W-1:0]     wr_addr,
    input  wire [DATA_W-1:0]     wr_data,
    input  wire [DATA_W/8-1:0]   wr_be,
    output wire                  word_valid,      // one refill word received
    output wire [OFFSET_W-3:0]   word_idx,
    output wire [DATA_W-1:0]     word_data,
    output wire                  refill_done,     // coincides with the last word_valid
    output wire                  wr_done,
    // memory side
    output wire                  mem_valid,
    output wire                  mem_we,
    output wire [ADDR_W-1:0]     mem_addr,
    output wire [DATA_W-1:0]     mem_wdata,
    output wire [DATA_W/8-1:0]   mem_be,
    input  wire                  mem_ready,
    input  wire [DATA_W-1:0]     mem_rdata
);
    localparam WORD_W = OFFSET_W - 2;

    reg  [WORD_W-1:0] wcnt;
    wire last = &wcnt;

    assign mem_valid = op_refill | op_write;
    assign mem_we    = op_write & ~op_refill;
    assign mem_addr  = op_refill ? {refill_addr[ADDR_W-1:OFFSET_W], wcnt, 2'b00}
                                 : {wr_addr[ADDR_W-1:2], 2'b00};
    assign mem_wdata = wr_data;
    assign mem_be    = op_write ? wr_be : {(DATA_W/8){1'b1}};

    assign word_valid  = op_refill & mem_ready;
    assign word_idx    = wcnt;
    assign word_data   = mem_rdata;
    assign refill_done = word_valid & last;
    assign wr_done     = op_write & ~op_refill & mem_ready;

    always @(posedge clk) begin
        if (!rst_n)           wcnt <= {WORD_W{1'b0}};
        else if (word_valid)  wcnt <= wcnt + 1'b1;     // wraps to 0 after last word
    end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
