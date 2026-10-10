`timescale 1ns/1ps
`include "tb_common.vh"
// Verifies lru_controller against an independent TIMESTAMP-based true-LRU model
// (no rank bits): the victim is the way with the smallest last-use time.
module tb_lru_controller;
    integer checks = 0, errors = 0, i, s, w;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [2:0] lk_index = 0;
    reg       upd_en = 0;
    reg [2:0] upd_index = 0;
    reg [1:0] upd_way4 = 0;
    wire [0:0] vic2; wire [1:0] vic4;
    lru_controller #(.WAYS(2), .SETS(8), .INDEX_W(3)) d2 (.clk(clk), .rst_n(rst_n), .lk_index(lk_index), .victim(vic2), .upd_en(upd_en), .upd_index(upd_index), .upd_way(upd_way4[0]));
    lru_controller #(.WAYS(4), .SETS(8), .INDEX_W(3)) d4 (.clk(clk), .rst_n(rst_n), .lk_index(lk_index), .victim(vic4), .upd_en(upd_en), .upd_index(upd_index), .upd_way(upd_way4));

    // timestamp reference models.  initial order => way0 is LRU, way3 is MRU
    integer ts4 [0:7][0:3];
    integer ts2 [0:7][0:1];
    integer now, best, bw;

    task access(input [2:0] set, input [1:0] way4);
        begin
            @(negedge clk); upd_en = 1; upd_index = set; upd_way4 = way4;
            @(negedge clk); upd_en = 0;
            now = now + 1; ts4[set][way4] = now;
            ts2[set][way4[0]] = now;
        end
    endtask
    function integer lru4(input integer set);
        integer ww, bb, bt;
        begin bt = 1<<30; bb = 0;
            for (ww = 0; ww < 4; ww = ww + 1) if (ts4[set][ww] < bt) begin bt = ts4[set][ww]; bb = ww; end
            lru4 = bb;
        end
    endfunction
    function integer lru2(input integer set);
        begin lru2 = (ts2[set][0] <= ts2[set][1]) ? 0 : 1; end
    endfunction

    initial begin
        now = 0;
        for (s = 0; s < 8; s = s + 1) for (w = 0; w < 4; w = w + 1) ts4[s][w] = w - 10;   // way0 oldest
        for (s = 0; s < 8; s = s + 1) begin ts2[s][0] = -10; ts2[s][1] = -9; end
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;
        // ---- reset state: way0 is LRU everywhere
        for (s = 0; s < 8; s = s + 1) begin lk_index = s; #1;
            `CHECK(vic2 == 0 && vic4 == 0, "reset: way0 is LRU")
        end
        // ---- directed 2-way: 1 bit per set
        access(3, 0); lk_index = 3; #1; `CHECK(vic2 == 1, "2-way: after touching way0, way1 is LRU")
        access(3, 1); #1;               `CHECK(vic2 == 0, "2-way: after touching way1, way0 is LRU")
        access(3, 1); #1;               `CHECK(vic2 == 0, "2-way: touching MRU again leaves state")
        lk_index = 4; #1;               `CHECK(vic2 == 0, "2-way: other sets unaffected")
        // ---- directed 4-way: touch 0,1,2,3 -> LRU is 0; touch 0 -> LRU is 1
        access(5, 0); access(5, 1); access(5, 2); access(5, 3); lk_index = 5; #1;
        `CHECK(vic4 == 0, "4-way: order 0,1,2,3 -> victim 0")
        access(5, 0); #1; `CHECK(vic4 == 1, "4-way: touch 0 -> victim 1 (true LRU, differs from PLRU)")
        access(5, 1); #1; `CHECK(vic4 == 2, "4-way: touch 1 -> victim 2")
        access(5, 2); #1; `CHECK(vic4 == 3, "4-way: touch 2 -> victim 3")
        // ---- randomized vs timestamp model, all sets checked after every update
        for (i = 0; i < 6000; i = i + 1) begin
            access($random & 7, $random & 3);
            for (s = 0; s < 8; s = s + 1) begin
                lk_index = s; #1;
                `CHECK(vic4 == lru4(s), "random 4-way victim == timestamp model")
                `CHECK(vic2 == lru2(s), "random 2-way victim == timestamp model")
            end
        end
        // ---- no update when upd_en = 0
        lk_index = 2; #1; bw = vic4;
        @(negedge clk); upd_index = 2; upd_way4 = 2'd3; upd_en = 0; @(negedge clk); #1;
        `CHECK(vic4 == bw, "no state change without upd_en")
        `TB_REPORT("lru_controller")
        $finish;
    end
endmodule
