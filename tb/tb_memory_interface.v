`timescale 1ns/1ps
`include "tb_common.vh"
module tb_memory_interface;
    integer checks = 0, errors = 0, i, n, t0, t1, L;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg op_refill = 0, op_write = 0;
    reg [31:0] refill_addr = 0, wr_addr = 0, wr_data = 0; reg [3:0] wr_be = 0;
    wire word_valid, refill_done, wr_done, mem_valid, mem_we, mem_ready;
    wire [2:0] word_idx; wire [31:0] word_data, mem_addr, mem_wdata, mem_rdata; wire [3:0] mem_be;

    memory_interface #(.ADDR_W(32), .DATA_W(32), .OFFSET_W(5)) dut (
        .clk(clk), .rst_n(rst_n), .op_refill(op_refill), .refill_addr(refill_addr),
        .op_write(op_write), .wr_addr(wr_addr), .wr_data(wr_data), .wr_be(wr_be),
        .word_valid(word_valid), .word_idx(word_idx), .word_data(word_data),
        .refill_done(refill_done), .wr_done(wr_done),
        .mem_valid(mem_valid), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_ready(mem_ready), .mem_rdata(mem_rdata));
    mem_model #(.AW(18)) mem (.clk(clk), .rst_n(rst_n), .mem_valid(mem_valid), .mem_we(mem_we),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be), .mem_ready(mem_ready), .mem_rdata(mem_rdata));

    reg [31:0] base, expw;
    reg lastok;
    initial begin
        repeat (3) @(posedge clk); @(negedge clk); rst_n = 1; @(negedge clk);
        L = mem.LAT;
        // ---- refill of the line containing 0x0001_2347  (line base 0x0001_2340)
        base = 32'h0001_2340;
        @(negedge clk); refill_addr = 32'h0001_2347; op_refill = 1;
        n = 0; t0 = 0; t1 = 0;
        lastok = 0;
        while (!refill_done) begin
            @(posedge clk);
            if (refill_done) lastok = word_valid && (word_idx == 3'd7);   // sample at the clock edge
            if (word_valid) begin
                `CHECK(word_idx == n, "words arrive in ascending order")
                `CHECK(mem_addr == base + 4*n, "memory address = line base + 4*word")
                `CHECK(word_data == (((base>>2) + n) * 32'h9E3779B1) ^ 32'hA5A5A5A5, "refill word data")
                `CHECK(mem_we == 0, "refill is a read transaction")
                if (n == 0) t0 = $time; if (n == 1) t1 = $time;
                n = n + 1;
            end
        end
        #1;
        `CHECK(n == 8, "8 words per 32-byte line")
        `CHECK(lastok, "refill_done coincides with the last word (idx 7)")
        `CHECK((t1 - t0) == 10 * L, "each word costs exactly LAT cycles")
        @(negedge clk); op_refill = 0;
        @(posedge clk); #1; `CHECK(dut.wcnt == 0, "word counter returns to 0 after the line")
        // ---- second refill starts from word 0 again
        @(negedge clk); refill_addr = 32'h0002_0000; op_refill = 1;
        @(posedge clk); #1; `CHECK(mem_addr == 32'h0002_0000, "next refill starts at word 0")
        while (!refill_done) @(posedge clk);
        @(negedge clk); op_refill = 0;
        // ---- write with byte enables
        @(negedge clk); wr_addr = 32'h0003_0010; wr_data = 32'hA1B2C3D4; wr_be = 4'b0110; op_write = 1;
        n = 0;
        while (!wr_done) begin @(posedge clk); n = n + 1; end
        #1; `CHECK(mem_we == 1 && mem_be == 4'b0110 && mem_wdata == 32'hA1B2C3D4, "write attributes pass through")
        `CHECK(n == L, "write costs exactly LAT cycles")
        @(negedge clk); op_write = 0; @(posedge clk); @(posedge clk);
        expw = ((32'h0003_0010 >> 2) * 32'h9E3779B1) ^ 32'hA5A5A5A5;
        expw[15:8] = 8'hC3; expw[23:16] = 8'hB2;
        `CHECK(mem.mem[18'h0C004] == expw, "only enabled bytes written")
        `CHECK(!mem_valid && !word_valid && !wr_done, "idle when no operation requested")
        `TB_REPORT("memory_interface")
        $finish;
    end
endmodule
