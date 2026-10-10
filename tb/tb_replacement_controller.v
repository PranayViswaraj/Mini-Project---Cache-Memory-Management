`timescale 1ns/1ps
`include "tb_common.vh"
module tb_replacement_controller;
    integer checks = 0, errors = 0, i, pp;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [1:0] policy = 0; reg [2:0] lk_index = 0, upd_index = 0; reg [3:0] lk_valid = 4'b1111;
    reg adv = 0, upd_en = 0; reg [1:0] upd_way = 0;
    wire [1:0] v4;  wire [0:0] v2;
    replacement_controller #(.WAYS(4), .SETS(8), .INDEX_W(3)) d4 (.clk(clk), .rst_n(rst_n), .policy(policy), .lk_index(lk_index), .lk_valid(lk_valid), .victim_adv(adv), .victim(v4), .upd_en(upd_en), .upd_index(upd_index), .upd_way(upd_way));
    replacement_controller #(.WAYS(2), .SETS(8), .INDEX_W(3)) d2 (.clk(clk), .rst_n(rst_n), .policy(policy), .lk_index(lk_index), .lk_valid(lk_valid[1:0]), .victim_adv(adv), .victim(v2), .upd_en(upd_en), .upd_index(upd_index), .upd_way(upd_way[0]));

    task touch(input [2:0] s, input [1:0] w);
        begin @(negedge clk); upd_en = 1; upd_index = s; upd_way = w; @(negedge clk); upd_en = 0; end
    endtask
    initial begin
        repeat (3) @(posedge clk); @(negedge clk); rst_n = 1;
        lk_index = 1;
        // ---- invalid way first, for every policy
        for (pp = 0; pp < 4; pp = pp + 1) begin
            policy = pp[1:0];
            lk_valid = 4'b1110; #1; `CHECK(v4 == 0, "4-way: only way0 invalid -> way0")
            lk_valid = 4'b1011; #1; `CHECK(v4 == 2, "4-way: only way2 invalid -> way2")
            lk_valid = 4'b0110; #1; `CHECK(v4 == 0, "4-way: lowest invalid way wins")
            lk_valid = 4'b1101; #1; `CHECK(v4 == 1, "4-way: way1 invalid -> way1")
            lk_valid[1:0] = 2'b01; #1; `CHECK(v2 == 1, "2-way: way1 invalid -> way1")
        end
        lk_valid = 4'b1111;
        // ---- state is updated for ALL policies regardless of the selected one:
        // touch 0,1,2,3 then 0 while Random is selected, then switch to LRU/PLRU
        policy = 0; touch(1,0); touch(1,1); touch(1,2); touch(1,3); touch(1,0);
        policy = 1; #1; `CHECK(v4 == 1, "LRU state kept up to date while Random was selected")
        policy = 2; #1; `CHECK(v4 == 2, "PLRU state kept up to date while Random was selected")
        policy = 3; #1; `CHECK(v4 == 1, "reserved policy 11 falls back to LRU")
        // ---- 2-way: PLRU aliases LRU (no distinct policy exists at 2 ways)
        policy = 1; #1; begin : al reg a; a = v2; policy = 2; #1; `CHECK(v2 == a, "2-way: policy 10 aliases LRU") end
        // ---- Random policy follows the LFSR and only advances with victim_adv
        policy = 0; #1;
        `CHECK(v4 == d4.u_rnd.lfsr[1:0], "random victim = LFSR low bits")
        begin : rr reg [15:0] prev_l; prev_l = d4.u_rnd.lfsr;
            @(negedge clk); adv = 1; @(negedge clk); adv = 0; #1;
            `CHECK(d4.u_rnd.lfsr != prev_l, "LFSR advances when a victim is selected")
            prev_l = d4.u_rnd.lfsr; repeat (5) @(negedge clk); #1;
            `CHECK(d4.u_rnd.lfsr == prev_l, "LFSR frozen without victim_adv")
        end
        `TB_REPORT("replacement_controller")
        $finish;
    end
endmodule
