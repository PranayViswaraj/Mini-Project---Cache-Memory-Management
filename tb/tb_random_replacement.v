`timescale 1ns/1ps
`include "tb_common.vh"
module tb_random_replacement;
    integer checks = 0, errors = 0, i;
    reg clk = 0, rst_n = 0, adv = 0;
    always #5 clk = ~clk;
    wire [0:0] v2; wire [1:0] v4;
    random_replacement #(.WAYS(2)) d2 (.clk(clk), .rst_n(rst_n), .advance(adv), .victim(v2));
    random_replacement #(.WAYS(4)) d4 (.clk(clk), .rst_n(rst_n), .advance(adv), .victim(v4));

    integer period, cnt00, cnt01, cnt10, cnt11, ones;
    reg [15:0] first, shadow;
    initial begin
        repeat (3) @(posedge clk);
        `CHECK(d2.lfsr === 16'hACE1, "reset value while in reset")
        @(negedge clk); rst_n = 1;
        @(posedge clk); #1;
        `CHECK(d2.lfsr == 16'hACE1, "value after reset release (no advance)")
        `CHECK(v2 == 1'b1 && v4 == 2'b01, "victim = low bits of reset value ACE1 (..0001)")
        // does not move without `advance`
        repeat (10) @(posedge clk); #1;
        `CHECK(d2.lfsr == 16'hACE1, "holds when advance=0")
        // full period: returns to ACE1 first after exactly 65535 advances, never hits 0
        first = d2.lfsr; shadow = 16'hACE1; period = 0; cnt00 = 0; cnt01 = 0; cnt10 = 0; cnt11 = 0; ones = 0;
        adv = 1;
        for (i = 1; i <= 65535; i = i + 1) begin
            @(posedge clk); #1;
            shadow = {shadow[0] ^ shadow[2] ^ shadow[3] ^ shadow[5], shadow[15:1]};
            `CHECK(d2.lfsr == shadow && d4.lfsr == shadow, "LFSR follows x^16+x^14+x^13+x^11+1 step by step")
            `CHECK(v2 == shadow[0] && v4 == shadow[1:0], "victim = low bits of LFSR")
            if (d2.lfsr == 16'h0000) begin `CHECK(0, "LFSR hit all-zero lock-up state") end
            case (v4) 2'd0: cnt00 = cnt00 + 1; 2'd1: cnt01 = cnt01 + 1; 2'd2: cnt10 = cnt10 + 1; 2'd3: cnt11 = cnt11 + 1; endcase
            if (v2 == 1'b1) ones = ones + 1;
            if (d2.lfsr == first && period == 0) period = i;
        end
        adv = 0;
        `CHECK(period == 65535, "maximal-length period = 65535")
        // over one full period the low-2-bit values occur 16383 / 16384 / 16384 / 16384 times
        `CHECK(cnt00 == 16383 && cnt01 == 16384 && cnt10 == 16384 && cnt11 == 16384, "4-way victim distribution over full period")
        `CHECK(ones == 32768, "2-way victim distribution over full period (32768 ones)")
        // mid-run reset restores seed
        adv = 1; repeat (7) @(posedge clk); adv = 0;
        @(negedge clk); rst_n = 0; @(posedge clk); #1;
        `CHECK(d2.lfsr == 16'hACE1, "synchronous reset restores seed")
        `TB_REPORT("random_replacement")
        $finish;
    end
endmodule
