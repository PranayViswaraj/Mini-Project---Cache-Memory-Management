`timescale 1ns/1ps
`include "tb_common.vh"
module tb_arrays;
    integer checks = 0, errors = 0, i, w, s, b;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    // 2 ways x 8 sets, tag 6 bits, 8-word lines
    reg [2:0] rd_index = 0, wr_index = 0; reg [0:0] wr_way = 0;
    reg  tw_en = 0, vw_en = 0, dw_en = 0; reg [5:0] wr_tag = 0; reg vval = 1;
    reg [2:0] rd_word = 0, wr_word = 0; reg [31:0] wr_data = 0; reg [3:0] wr_be = 4'hF;
    wire [11:0] rd_tags; wire [1:0] rd_valid; wire [63:0] rd_data;
    tag_array   #(.WAYS(2), .SETS(8), .INDEX_W(3), .TAG_W(6)) ut (.clk(clk), .rd_index(rd_index), .rd_tags(rd_tags), .wr_en(tw_en), .wr_way(wr_way), .wr_index(wr_index), .wr_tag(wr_tag));
    valid_array #(.WAYS(2), .SETS(8), .INDEX_W(3)) uv (.clk(clk), .rst_n(rst_n), .rd_index(rd_index), .rd_valid(rd_valid), .wr_en(vw_en), .wr_way(wr_way), .wr_index(wr_index), .wr_val(vval));
    data_array  #(.WAYS(2), .SETS(8), .INDEX_W(3), .WORD_W(3), .DATA_W(32)) ud (.clk(clk), .rd_index(rd_index), .rd_word(rd_word), .rd_data(rd_data), .wr_en(dw_en), .wr_way(wr_way), .wr_index(wr_index), .wr_word(wr_word), .wr_data(wr_data), .wr_be(wr_be));

    reg [5:0]  mt [0:1][0:7]; reg mv [0:1][0:7]; reg [31:0] md [0:1][0:7][0:7];
    reg [31:0] e;
    initial begin
        repeat (3) @(posedge clk);
        `CHECK(1, "start")
        @(negedge clk); rst_n = 1;
        for (w = 0; w < 2; w = w + 1) for (s = 0; s < 8; s = s + 1) begin rd_index = s; #1; `CHECK(rd_valid[w] == 0, "valid cleared by reset") end
        for (w = 0; w < 2; w = w + 1) for (s = 0; s < 8; s = s + 1) mv[w][s] = 0;
        // random operations vs. behavioural model
        for (i = 0; i < 6000; i = i + 1) begin
            @(negedge clk);
            tw_en = 0; vw_en = 0; dw_en = 0;
            wr_way = $random; wr_index = $random; wr_word = $random; wr_tag = $random; wr_data = $random; wr_be = $random; vval = $random;
            case ($random & 3)
              0: begin tw_en = 1; mt[wr_way][wr_index] = wr_tag; end
              1: begin vw_en = 1; mv[wr_way][wr_index] = vval; end
              2: begin dw_en = 1;
                    e = md[wr_way][wr_index][wr_word];
                    for (b = 0; b < 4; b = b + 1) if (wr_be[b]) e[8*b +: 8] = wr_data[8*b +: 8];
                    md[wr_way][wr_index][wr_word] = e; end
              default: ;
            endcase
            @(posedge clk); #1;
            rd_index = $random; rd_word = $random; #1;
            for (w = 0; w < 2; w = w + 1) begin
                if (mv[w][rd_index] !== 1'bx) `CHECK(rd_valid[w] === mv[w][rd_index], "valid read == model")
                if (mt[w][rd_index] !== 6'bx)  `CHECK(rd_tags[6*w +: 6] === mt[w][rd_index], "tag read == model")
                if (md[w][rd_index][rd_word] !== 32'bx && ud.mem[{w[0], rd_index, rd_word}] !== 32'bx)
                    `CHECK(rd_data[32*w +: 32] === md[w][rd_index][rd_word], "data read == model (byte enables)")
            end
        end
        `TB_REPORT("arrays")
        $finish;
    end
endmodule
