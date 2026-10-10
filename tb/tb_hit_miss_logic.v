`timescale 1ns/1ps
`include "tb_common.vh"
module tb_hit_miss_logic;
    integer checks = 0, errors = 0, i;
    // 2-way
    reg  [2*21-1:0] tags2; reg [1:0] val2; reg [20:0] rt;
    wire hit2; wire [0:0] way2; wire [1:0] oh2;
    hit_miss_logic #(.WAYS(2), .TAG_W(21)) d2 (.rd_tags(tags2), .rd_valid(val2), .req_tag(rt), .hit(hit2), .hit_way(way2), .hit_onehot(oh2));
    // 4-way
    reg  [4*21-1:0] tags4; reg [3:0] val4;
    wire hit4; wire [1:0] way4; wire [3:0] oh4;
    hit_miss_logic #(.WAYS(4), .TAG_W(21)) d4 (.rd_tags(tags4), .rd_valid(val4), .req_tag(rt), .hit(hit4), .hit_way(way4), .hit_onehot(oh4));

    integer w; reg exp_hit; integer exp_way;
    initial begin
        // ---- directed 2-way: equal/different tags x valid/invalid
        tags2 = {21'h00ABC, 21'h00123}; rt = 21'h00123; val2 = 2'b11; #1;       // way0 matches
        `CHECK(hit2 && way2 == 0 && oh2 == 2'b01, "2-way hit way0")
        rt = 21'h00ABC; #1;
        `CHECK(hit2 && way2 == 1 && oh2 == 2'b10, "2-way hit way1")
        rt = 21'h00FFF; #1;
        `CHECK(!hit2 && oh2 == 2'b00, "2-way miss (different tag)")
        rt = 21'h00123; val2 = 2'b10; #1;                                       // tag equal but way0 invalid
        `CHECK(!hit2, "2-way equal tag but INVALID => miss")
        val2 = 2'b00; #1;
        `CHECK(!hit2, "2-way both invalid => miss")
        // ---- directed 4-way
        tags4 = {21'd4, 21'd3, 21'd2, 21'd1}; val4 = 4'b1111;
        for (w = 0; w < 4; w = w + 1) begin
            rt = w + 1; #1;
            `CHECK(hit4 && way4 == w && oh4 == (4'b0001 << w), "4-way hit each way")
        end
        val4 = 4'b1011; rt = 21'd3; #1;                                         // way2 holds tag 3 but invalid
        `CHECK(!hit4, "4-way match on invalid way ignored")
        // ---- randomized vs. behavioural expectation
        for (i = 0; i < 5000; i = i + 1) begin
            tags4 = {$random, $random, $random};  val4 = $random;
            rt = tags4[21*(i%4) +: 21];                       // force a possible match
            if (i % 3 == 0) rt = $random;
            #1;
            exp_hit = 0; exp_way = 0;
            for (w = 3; w >= 0; w = w - 1)
                if (val4[w] && tags4[21*w +: 21] == rt) begin exp_hit = 1; exp_way = w; end
            `CHECK(hit4 == exp_hit, "random 4-way hit")
            if (exp_hit) `CHECK(way4 == exp_way, "random 4-way way (lowest match)")
        end
        `TB_REPORT("hit_miss_logic")
        $finish;
    end
endmodule
