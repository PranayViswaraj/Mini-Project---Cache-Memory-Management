`timescale 1ns/1ps
`include "tb_common.vh"
// Verifies 4-way tree PLRU against an independent tree-walk model and checks the
// documented PLRU-vs-LRU difference.
module tb_plru_controller;
    integer checks = 0, errors = 0, i, s;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [2:0] lk_index = 0, upd_index = 0;
    reg       upd_en = 0;
    reg [1:0] upd_way = 0;
    wire [1:0] vic;
    plru_controller #(.SETS(8), .INDEX_W(3)) dut (.clk(clk), .rst_n(rst_n), .lk_index(lk_index), .victim(vic), .upd_en(upd_en), .upd_index(upd_index), .upd_way(upd_way));

    // reference: explicit node array  node[0]=root node[1]=left node[2]=right ; value 1 = "go right"
    reg [2:0] refnode [0:7];
    function [1:0] ref_victim(input [2:0] set);
        reg [2:0] n;
        begin n = refnode[set];
            if (n[0] == 0) ref_victim = {1'b0, n[1]}; else ref_victim = {1'b1, n[2]};
        end
    endfunction
    task touch(input [2:0] set, input [1:0] way);
        begin
            @(negedge clk); upd_en = 1; upd_index = set; upd_way = way;
            @(negedge clk); upd_en = 0;
            // pointing AWAY from the touched way
            refnode[set][0] = ~way[1];
            if (way[1] == 0) refnode[set][1] = ~way[0]; else refnode[set][2] = ~way[0];
        end
    endtask

    initial begin
        for (s = 0; s < 8; s = s + 1) refnode[s] = 3'b000;
        repeat (3) @(posedge clk); @(negedge clk); rst_n = 1;
        for (s = 0; s < 8; s = s + 1) begin lk_index = s; #1; `CHECK(vic == 0, "reset: victim way0") end
        // documented sequence: A,B,C,D (ways 0..3) then A  => PLRU evicts way2, true LRU would evict way1
        touch(1,0); touch(1,1); touch(1,2); touch(1,3); lk_index = 1; #1;
        `CHECK(vic == 0, "after 0,1,2,3 the victim is way0")
        touch(1,0); #1;
        `CHECK(vic == 2, "after 0,1,2,3,0 PLRU victim is way2 (true LRU would pick way1)")
        `CHECK(vic != 1, "PLRU differs from true LRU on this sequence")
        // the just-touched way is never the immediate victim
        for (i = 0; i < 4000; i = i + 1) begin
            s = $random & 7;
            touch(s, $random & 3);
            lk_index = s; #1;
            `CHECK(vic != upd_way, "victim is never the most-recently-touched way")
            `CHECK(vic == ref_victim(s), "PLRU victim == tree-walk model")
        end
        `TB_REPORT("plru_controller")
        $finish;
    end
endmodule
