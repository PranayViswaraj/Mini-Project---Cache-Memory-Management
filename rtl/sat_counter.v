//==============================================================================
// sat_counter.v
// W-bit SATURATING event counter.
//   Reset value : 0
//   Increment   : +1 on every clock where `inc` is high
//   Overflow    : saturates at all-ones (never wraps); `saturated` flags it
//   Clear       : synchronous `clear` has priority over `inc` (an event that
//                 coincides with a clear is dropped - documented behaviour)
//==============================================================================
module sat_counter #(
    parameter W = 32
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,
    input  wire         inc,
    output reg  [W-1:0] count,
    output wire         saturated
);
    assign saturated = &count;

    always @(posedge clk) begin
        if (!rst_n || clear)            count <= {W{1'b0}};
        else if (inc && !(&count))      count <= count + 1'b1;
    end
endmodule
