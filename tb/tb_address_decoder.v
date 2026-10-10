`timescale 1ns/1ps
`include "tb_common.vh"
module tb_address_decoder;
    integer checks = 0, errors = 0, i;
    // baseline: 4KB / 2-way / 32B  -> tag 21, index 6, offset 5
    reg  [31:0] addr;
    wire [20:0] tag;  wire [5:0] index;  wire [4:0] offset;
    address_decoder #(.ADDR_W(32), .OFFSET_W(5), .INDEX_W(6)) dut (.addr(addr), .tag(tag), .index(index), .offset(offset));
    // 16KB / 2-way -> index 8, tag 19
    wire [18:0] tag2; wire [7:0] index2; wire [4:0] offset2;
    address_decoder #(.ADDR_W(32), .OFFSET_W(5), .INDEX_W(8)) dut2 (.addr(addr), .tag(tag2), .index(index2), .offset(offset2));

    task chk(input [31:0] a);
        begin
            addr = a; #1;
            `CHECK(offset == a[4:0],            "offset field")
            `CHECK(index  == a[10:5],           "index field")
            `CHECK(tag    == a[31:11],          "tag field")
            `CHECK({tag, index, offset} == a,   "fields reassemble to the address (4KB)")
            `CHECK({tag2, index2, offset2} == a,"fields reassemble to the address (16KB)")
            `CHECK(index2 == a[12:5] && tag2 == a[31:13], "16KB split")
        end
    endtask
    initial begin
        chk(32'h0000_0000);               // first line
        chk(32'hFFFF_FFFF);               // all ones
        chk(32'h0000_001F);               // last byte of line 0
        chk(32'h0000_0020);               // first byte of line 1 (index 1)
        chk(32'h0000_07E0);               // last set (index 63), offset 0
        chk(32'h0000_07FF);               // last set, last byte
        chk(32'h0000_0800);               // wraps to index 0, tag 1
        chk(32'h8000_0000);               // MSB only
        for (i = 0; i < 2000; i = i + 1) chk($random);
        // numeric check of the documented example: 0x1234_5678
        addr = 32'h1234_5678; #1;
        `CHECK(offset == 5'h18 && index == 6'h33 && tag == 21'h02468A, "worked example 0x12345678")
        `TB_REPORT("address_decoder")
        $finish;
    end
endmodule
