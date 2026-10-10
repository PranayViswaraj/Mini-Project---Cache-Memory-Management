//==============================================================================
// random_replacement.v
// Pseudo-random victim selection using a 16-bit Fibonacci LFSR.
//   Polynomial : x^16 + x^14 + x^13 + x^11 + 1  (maximal length, period 65535)
//   Shift      : right;  feedback = b0 ^ b2 ^ b3 ^ b5  -> inserted at b15
//   Reset value: 16'hACE1 (non-zero; the all-zero state is a lock-up state)
//   Update     : advances once per replacement-victim selection event
//                (NOT every clock) so behaviour is independent of timing and
//                exactly reproducible by the software reference model.
//   Victim     : low log2(WAYS) bits of the LFSR.
// This is pseudo-random, not true-random.
//==============================================================================
module random_replacement #(
    parameter WAYS = 2,
    parameter [15:0] SEED = 16'hACE1
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     advance,
    output wire [$clog2(WAYS)-1:0]  victim
);
    reg  [15:0] lfsr;
    wire        fb = lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5];

    always @(posedge clk) begin
        if (!rst_n)       lfsr <= SEED;
        else if (advance) lfsr <= {fb, lfsr[15:1]};
    end

    assign victim = lfsr[$clog2(WAYS)-1:0];
endmodule
