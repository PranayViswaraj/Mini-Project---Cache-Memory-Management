`timescale 1ns/1ps
`include "tb_common.vh"
// Unit test of the Phase-2 adaptive controller with hand-derived expectations.
//   WIN=64 accesses, SAMPLE_N=4, MARGIN=2, MIN_HOLD=1, CONF_THRESH=2
//   INDEX_W=5 (32 sets, stride 16): leader sets  g0(Random): idx 0,16  g1(LRU): idx 4,20
//                                                 g2(PLRU)  : idx 8,24 (4-way only)
// Two DUTs share the stimulus: dut4 (4-way, 3 candidates) and dut2 (2-way, 2 candidates).
module tb_adaptive_controller;
    integer checks = 0, errors = 0, i, j;
    reg clk = 0, rst_n = 0, enable = 1;
    always #5 clk = ~clk;
    reg [4:0] idx = 0; reg ev_access = 0, ev_miss = 0;
    wire [1:0] sel4, act4, sel2, act2; wire [31:0] sw4, wn4, sw2, wn2;

    adaptive_controller #(.WAYS(4), .INDEX_W(5), .WIN_ACCESSES(64), .SAMPLE_N(4), .MARGIN(2), .MIN_HOLD(1), .CONF_THRESH(2)) dut4 (
        .clk(clk), .rst_n(rst_n), .enable(enable), .lk_index(idx), .ev_access(ev_access), .ev_miss(ev_miss),
        .policy_sel(sel4), .active_policy(act4), .cnt_switch(sw4), .cnt_window(wn4));
    adaptive_controller #(.WAYS(2), .INDEX_W(5), .WIN_ACCESSES(64), .SAMPLE_N(4), .MARGIN(2), .MIN_HOLD(1), .CONF_THRESH(2)) dut2 (
        .clk(clk), .rst_n(rst_n), .enable(enable), .lk_index(idx), .ev_access(ev_access), .ev_miss(ev_miss),
        .policy_sel(sel2), .active_policy(act2), .cnt_switch(sw2), .cnt_window(wn2));

    task acc(input [4:0] ix, input miss);
        begin @(negedge clk); idx = ix; ev_access = 1; ev_miss = miss; @(negedge clk); ev_access = 0; ev_miss = 0; end
    endtask

    // one 64-access window: n_g leader samples per group, the first m_g of them are misses
    task window(input integer m0, input integer m1, input integer m2,
                input integer n0, input integer n1, input integer n2);
        integer used;
        begin
            used = 0;
            for (j = 0; j < n0; j = j + 1) begin acc((j % 2) ? 5'd16 : 5'd0, j < m0); used = used + 1; end
            for (j = 0; j < n1; j = j + 1) begin acc((j % 2) ? 5'd20 : 5'd4, j < m1); used = used + 1; end
            for (j = 0; j < n2; j = j + 1) begin acc((j % 2) ? 5'd24 : 5'd8, j < m2); used = used + 1; end
            while (used < 64) begin acc(5'd1, 1'b0); used = used + 1; end   // follower filler
        end
    endtask

    task expect_state(input [1:0] a4, input integer s4, input [1:0] a2, input integer s2, input integer win, input [255:0] msg);
        begin
            #1;
            `CHECK(act4 === a4 && sw4 === s4, {"4-way ", msg})
            `CHECK(act2 === a2 && sw2 === s2, {"2-way ", msg})
            `CHECK(wn4 === win && wn2 === win, {"window count ", msg})
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); @(negedge clk); rst_n = 1;
        `CHECK(act4 == 2'd1 && act2 == 2'd1 && sw4 == 0 && wn4 == 0, "reset: active policy = LRU, counters 0")
        // leader-set policy mapping
        idx = 0;  #1; `CHECK(sel4 == 0 && sel2 == 0, "idx0 leader -> Random")
        idx = 16; #1; `CHECK(sel4 == 0, "idx16 leader -> Random")
        idx = 4;  #1; `CHECK(sel4 == 1 && sel2 == 1, "idx4 leader -> LRU")
        idx = 8;  #1; `CHECK(sel4 == 2, "idx8 leader -> PLRU (4-way)")
        `CHECK(sel2 == act2, "idx8 is a follower in 2-way")
        idx = 1;  #1; `CHECK(sel4 == act4 && sel2 == act2, "follower set uses active policy")

        window(0,4,4, 4,4,4); expect_state(1,0, 1,0, 1, "W1 first win: confidence 1, no switch");
        window(0,4,4, 4,4,4); expect_state(0,1, 0,1, 2, "W2 second consecutive win: switch to Random");
        window(4,0,4, 4,4,4); expect_state(0,1, 0,1, 3, "W3 min-hold blocks switch");
        window(4,0,4, 4,4,4); expect_state(0,1, 0,1, 4, "W4 first win for LRU: confidence 1");
        window(4,4,0, 4,4,4); expect_state(0,1, 0,1, 5, "W5 different winner resets confidence (4-way) / tie keeps (2-way)");
        window(4,4,0, 4,4,4); expect_state(2,2, 0,1, 6, "W6 PLRU wins twice: 4-way switches; 2-way has no PLRU candidate");
        window(0,4,4, 4,4,4); expect_state(2,2, 0,1, 7, "W7 hold blocks switch");
        window(0,0,4, 2,4,4); expect_state(2,2, 0,1, 8, "W8 insufficient samples in group0: retain");
        window(4,2,3, 4,4,4); expect_state(2,2, 0,1, 9, "W9 margin: gain below MARGIN (4-way) / meets MARGIN, conf=1 (2-way)");
        window(4,2,3, 4,4,4); expect_state(2,2, 1,2, 10, "W10 2-way: second win -> switch to LRU");
        // extra samples beyond SAMPLE_N must be ignored (group 1 delivers 6 samples, only the first 4 count)
        window(4,0,4, 4,6,4); #1;
        // enable=0 : events are ignored, state frozen
        enable = 0;
        for (i = 0; i < 70; i = i + 1) acc(5'd2, 1'b1);
        #1; `CHECK(wn4 == 11 && act4 == 2'd2 && sw4 == 2, "disabled: no window progress, policy frozen (4-way)")
        `CHECK(sel4 == act4, "disabled: leader override off")
        enable = 1;
        // synchronous reset
        @(negedge clk); rst_n = 0; @(negedge clk); rst_n = 1; #1;
        `CHECK(act4 == 2'd1 && sw4 == 0 && wn4 == 0, "reset restores LRU and clears counters")
        `TB_REPORT("adaptive_controller")
        $finish;
    end
endmodule
