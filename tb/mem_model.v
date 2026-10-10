//==============================================================================
// mem_model.v  -- deterministic behavioural main memory (TESTBENCH ONLY)
//   * word addressed by addr[AW+1:2]  (2^AW words; higher address bits alias)
//   * initial content of word i :  (i * 32'h9E3779B1) ^ 32'hA5A5A5A5
//   * every word access costs exactly LAT cycles (+LAT=<n>, default 10;
//     LAT=1 means zero wait states). Reads and writes cost the same.
//   * byte-enable writes; counts completed read / write words.
// This is NOT a DRAM model: a fixed-latency memory is used so that cache
// experiments are controlled and reproducible.
//==============================================================================
`timescale 1ns/1ps
module mem_model #(
    parameter AW = 18
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        mem_valid,
    input  wire        mem_we,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_be,
    output wire        mem_ready,
    output wire [31:0] mem_rdata
);
    reg [31:0] mem [0:(1<<AW)-1];
    integer LAT;
    integer cnt;
    integer rd_count, wr_count;
    integer i, b;

    initial begin
        LAT = 10;
        if ($value$plusargs("LAT=%d", LAT)) ;
        if (LAT < 1) LAT = 1;
        rd_count = 0; wr_count = 0; cnt = 0;
        for (i = 0; i < (1<<AW); i = i + 1)
            mem[i] = (i * 32'h9E3779B1) ^ 32'hA5A5A5A5;
    end

    wire [AW-1:0] widx = mem_addr[AW+1:2];
    assign mem_ready = mem_valid && (cnt == LAT-1);
    assign mem_rdata = mem[widx];

    always @(posedge clk) begin
        if (!rst_n) begin
            cnt <= 0;
        end else if (mem_valid) begin
            if (mem_ready) begin
                cnt <= 0;
                if (mem_we) begin
                    for (b = 0; b < 4; b = b + 1)
                        if (mem_be[b]) mem[widx][8*b +: 8] <= mem_wdata[8*b +: 8];
                    wr_count <= wr_count + 1;
                end else begin
                    rd_count <= rd_count + 1;
                end
            end else begin
                cnt <= cnt + 1;
            end
        end else begin
            cnt <= 0;
        end
    end
endmodule
