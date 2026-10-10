`timescale 1ns/1ps
`include "tb_common.vh"
//==============================================================================
// tb_cache_directed.v -- cache-level directed + corner-case verification
// Parameters allow the same suite to run on 2-way / 4-way and Phase-1 / Phase-2 builds.
// Expected values are derived by hand from the architecture spec:
//   read hit         : 0 stall cycles
//   read miss        : 1 + 8*LAT stall cycles, 1 refill, 8 memory reads
//   write (hit/miss) : 1 + LAT  stall cycles, 1 memory write, write-through
//==============================================================================
module tb_cache_directed;
    parameter CACHE_BYTES = 4096;
    parameter WAYS        = 2;
    parameter ADAPTIVE_EN = 1;
    localparam SETS = CACHE_BYTES / 32 / WAYS;
    localparam TAGW = 32 - 5 - $clog2(SETS);       // 21 for 4KB/2-way, 22 for 4KB/4-way
    localparam WSZ  = CACHE_BYTES / WAYS;          // bytes per way = distance between same-set lines

    integer checks = 0, errors = 0, i, k, L;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0, mem_rst_n = 0;
    reg cpu_valid = 0, cpu_we = 0; reg [31:0] cpu_addr = 0, cpu_wdata = 0; reg [3:0] cpu_be = 4'hF;
    wire cpu_ready; wire [31:0] cpu_rdata;
    wire mem_valid, mem_we, mem_ready; wire [31:0] mem_addr, mem_wdata, mem_rdata; wire [3:0] mem_be;
    reg [1:0] cfg_policy = 1; reg cnt_clear = 0;
    wire [1:0] policy_active;
    wire [31:0] c_acc, c_rd, c_wr, c_hit, c_mis, c_rf, c_rep, c_stl, c_mrd, c_mwr, c_sw, c_win; wire c_sat;

    cache_top #(.CACHE_BYTES(CACHE_BYTES), .WAYS(WAYS), .ADAPTIVE_EN(ADAPTIVE_EN)) dut (
        .clk(clk), .rst_n(rst_n), .cpu_valid(cpu_valid), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_be(cpu_be), .cpu_ready(cpu_ready), .cpu_rdata(cpu_rdata),
        .mem_valid(mem_valid), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_ready(mem_ready), .mem_rdata(mem_rdata), .cfg_policy(cfg_policy), .cnt_clear(cnt_clear),
        .policy_active(policy_active), .cnt_access(c_acc), .cnt_read(c_rd), .cnt_write(c_wr), .cnt_hit(c_hit),
        .cnt_miss(c_mis), .cnt_refill(c_rf), .cnt_replace(c_rep), .cnt_stall(c_stl), .cnt_memrd(c_mrd),
        .cnt_memwr(c_mwr), .cnt_saturated(c_sat), .cnt_switch(c_sw), .cnt_window(c_win));
    mem_model #(.AW(18)) mem (.clk(clk), .rst_n(mem_rst_n), .mem_valid(mem_valid), .mem_we(mem_we),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be), .mem_ready(mem_ready), .mem_rdata(mem_rdata));

    // ---------------------------------------------------------------- driver
    reg [31:0] rd, got;
    integer cyc;                                   // cycles spent in the last request
    task req(input we, input [31:0] a, input [31:0] d, input [3:0] be, input hold);
        reg done;
        begin
            @(negedge clk);
            cpu_valid = 1; cpu_we = we; cpu_addr = a; cpu_wdata = d; cpu_be = be;
            done = 0; cyc = 0;
            while (!done) begin
                @(posedge clk); cyc = cyc + 1;
                if (cpu_ready) begin done = 1; rd = cpu_rdata; end
            end
            if (!we) `CHECK(rd === mem.mem[a[19:2]], "read data == memory content (write-through coherence)")
            if (!hold) begin @(negedge clk); cpu_valid = 0; end
        end
    endtask
    task RD(input [31:0] a);                req(0, a, 0, 4'hF, 0); endtask
    task WR(input [31:0] a, input [31:0] d, input [3:0] be); req(1, a, d, be, 0); endtask

    // counter snapshot / delta
    integer s_acc, s_rd, s_wr, s_hit, s_mis, s_rf, s_rep, s_stl, s_mrd, s_mwr;
    task snap; begin s_acc=c_acc; s_rd=c_rd; s_wr=c_wr; s_hit=c_hit; s_mis=c_mis; s_rf=c_rf; s_rep=c_rep; s_stl=c_stl; s_mrd=c_mrd; s_mwr=c_mwr; end endtask
    function integer way_of(input [31:0] a);       // way currently holding address a, -1 if none
        integer w; reg [31:0] ix; reg [31:0] tg;
        begin
            ix = (a >> 5) & (SETS-1); tg = a >> (5 + $clog2(SETS)); way_of = -1;
            for (w = 0; w < WAYS; w = w + 1)
                if (dut.u_valid.vbits[w][ix] && dut.u_tag.mem[w*SETS + ix] == tg[TAGW-1:0]) way_of = w;
        end
    endfunction
    function integer present(input [31:0] a); begin present = (way_of(a) >= 0); end endfunction

    reg [31:0] A0, A1, A2, A3, A4, T;
    integer w, exp_v, hits_before;
    reg [31:0] lfsr_v;

    initial begin
        if (!$value$plusargs("LAT=%d", L)) L = 10;
        repeat (4) @(posedge clk); @(negedge clk); mem_rst_n = 1; rst_n = 1; repeat (2) @(posedge clk);

        // ================= T1 reset state =================
        for (w = 0; w < WAYS; w = w + 1) `CHECK(dut.u_valid.vbits[w] == {SETS{1'b0}}, "T1 all valid bits 0 after reset")
        `CHECK(c_acc == 0 && c_hit == 0 && c_mis == 0 && c_stl == 0 && c_rf == 0, "T1 counters 0 after reset")
        `CHECK(cpu_ready == 0 && mem_valid == 0, "T1 idle: no ready, no memory request")
        `CHECK(dut.u_ctrl.state == 2'd0, "T1 FSM in IDLE")
        `CHECK(policy_active == 2'd1, "T1 default policy shown = LRU")

        // ================= T2 first read: miss, refill, allocate =================
        A0 = 32'h0000_1000;                                        // set 0 (4KB/2w) , tag 2
        snap; RD(A0);
        `CHECK(c_acc - s_acc == 1 && c_rd - s_rd == 1, "T2 one read accepted")
        `CHECK(c_mis - s_mis == 1 && c_hit - s_hit == 0, "T2 first access is a miss")
        `CHECK(c_rf - s_rf == 1 && c_mrd - s_mrd == 8 && c_rep - s_rep == 0, "T2 1 refill, 8 words, no eviction (invalid way used)")
        `CHECK(c_stl - s_stl == 1 + 8*L, "T2 miss stall cycles = 1 + 8*LAT")
        `CHECK(way_of(A0) == 0, "T2 line allocated in way0 (lowest invalid way); valid+tag written")
        // A0 sits in way0 / set0, so its words are data_array entries 0..7
        for (k = 0; k < 8; k = k + 1) `CHECK(dut.u_data.mem[k] === mem.mem[(A0>>2)+k], "T2 data array holds the refilled line")

        // ================= T3 read hit, other word of the same line =================
        snap; RD(A0 + 32'h1C);
        `CHECK(c_hit - s_hit == 1 && c_stl - s_stl == 0 && c_rf - s_rf == 0 && c_mrd - s_mrd == 0, "T3 read hit: 0 stalls, no memory traffic")
        `CHECK(cyc == 1, "T3 hit time is 1 cycle")

        // ================= T4 write hit (write-through) =================
        snap; WR(A0 + 4, 32'hDEAD_BEEF, 4'hF);
        `CHECK(c_wr - s_wr == 1 && c_hit - s_hit == 1 && c_mwr - s_mwr == 1, "T4 write hit counted; one memory write")
        `CHECK(c_stl - s_stl == 1 + L, "T4 write stall cycles = 1 + LAT")
        `CHECK(mem.mem[(A0+4)>>2] == 32'hDEAD_BEEF, "T4 memory updated (write-through)")
        `CHECK(dut.u_data.mem[1] === 32'hDEAD_BEEF, "T4 cache copy updated on write hit (way0,set0,word1)")
        snap; RD(A0 + 4);
        `CHECK(rd == 32'hDEAD_BEEF && c_hit - s_hit == 1 && c_stl - s_stl == 0, "T4 read-back hits and returns the written data")

        // ================= T5 byte enables =================
        snap; WR(A0 + 4, 32'h1122_3344, 4'b0101);
        RD(A0 + 4);
        `CHECK(rd == 32'hDE22_BE44, "T5 byte enables 0101 merge bytes 0 and 2 only")
        `CHECK(mem.mem[(A0+4)>>2] == 32'hDE22_BE44, "T5 memory merged identically")

        // ================= T6 write miss: no write-allocate =================
        T = 32'h0000_9020;                                         // different set (1)
        snap; WR(T, 32'hCAFE_F00D, 4'hF);
        `CHECK(c_mis - s_mis == 1 && c_rf - s_rf == 0 && c_mwr - s_mwr == 1, "T6 write miss: memory write only, no refill")
        `CHECK(c_stl - s_stl == 1 + L, "T6 write miss stall = 1 + LAT")
        `CHECK(!present(T), "T6 line NOT allocated on write miss")
        `CHECK(mem.mem[T>>2] == 32'hCAFE_F00D, "T6 memory updated")
        snap; RD(T);
        `CHECK(c_mis - s_mis == 1 && c_rf - s_rf == 1 && rd == 32'hCAFE_F00D, "T6 subsequent read is a miss and returns the written data")
        `CHECK(present(T), "T6 now allocated")

        // ================= T7 true-LRU behaviour (2-way) =================
        if (WAYS == 2) begin
            cfg_policy = 1;
            A0 = 32'h0000_00A0; A1 = A0 + WSZ; A2 = A0 + 2*WSZ;      // 3 lines, same set (5)
            RD(A0); RD(A1);
            `CHECK(way_of(A0) == 0 && way_of(A1) == 1, "T7 two lines fill both ways")
            snap; RD(A0);                                            // A0 becomes MRU -> A1 is LRU
            `CHECK(c_hit - s_hit == 1, "T7 touch A0 (hit)")
            snap; RD(A2);
            `CHECK(c_rep - s_rep == 1 && c_mis - s_mis == 1, "T7 third line evicts a valid line")
            `CHECK(dut.u_ctrl.vway == 1 && way_of(A2) == 1, "T7 LRU victim was way1 (A1)")
            snap; RD(A0); `CHECK(c_hit - s_hit == 1, "T7 A0 survived (hit)")
            snap; RD(A1); `CHECK(c_mis - s_mis == 1, "T7 A1 was evicted (miss)")
        end

        // ================= T8 random policy follows the LFSR =================
        cfg_policy = 0;
        A0 = 32'h0000_00C0;                                            // set 6
        for (k = 0; k < WAYS; k = k + 1) RD(A0 + k*WSZ);
        for (i = 0; i < 6; i = i + 1) begin
            lfsr_v = dut.u_repl.u_rnd.lfsr;
            exp_v  = lfsr_v & (WAYS-1);
            RD(A0 + (WAYS + i) * WSZ);
            `CHECK(dut.u_ctrl.vway == exp_v, "T8 random victim == LFSR low bits at selection time")
        end

        // ================= T9 reserved / adaptive encoding is safe =================
        cfg_policy = 3; A0 = 32'h0000_00E0;                          // set 7 (follower set)
        RD(A0); RD(A0 + WSZ);
        if (WAYS == 2) begin
            RD(A0);                                                  // A0 -> MRU
            snap; RD(A0 + 2*WSZ); `CHECK(dut.u_ctrl.vway == 1 && way_of(A0) == 0, "T9 cfg=11 on follower set behaves as LRU initially")
        end
        `CHECK(policy_active == 2'd1, "T9 active policy is LRU (fallback in Phase 1 / initial in Phase 2)")

        // ================= T10 boundary addresses =================
        cfg_policy = 1;
        for (k = 0; k < 8; k = k + 1) RD(32'h0000_0000 + 4*k);          // first line, all words
        for (k = 0; k < 8; k = k + 1) RD(32'hFFFF_FFE0 + 4*k);          // last line of the address space (set SETS-1)
        `CHECK(present(32'h0000_0000) && present(32'hFFFF_FFE0), "T10 first and last line cached")
        snap; RD(32'h0000_001C); RD(32'hFFFF_FFFC);
        `CHECK(c_hit - s_hit == 2, "T10 last word of each line hits")
        // same index, different tags
        A0 = 32'h0000_0140; A1 = A0 + WSZ; snap; RD(A0); RD(A1); `CHECK(c_mis - s_mis == 2 && way_of(A0) != way_of(A1), "T10 same index, different tags -> distinct ways")

        // ================= T11 back-to-back hits =================
        A0 = 32'h0000_0600; RD(A0);
        snap; k = 0;
        @(negedge clk); begin : b2b
            integer t0c; t0c = 0;
            for (k = 0; k < 8; k = k + 1) begin
                cpu_valid = 1; cpu_we = 0; cpu_addr = A0 + 4*k; cpu_be = 4'hF;
                @(posedge clk); t0c = t0c + 1;
                `CHECK(cpu_ready && cpu_rdata === mem.mem[(A0>>2)+k], "T11 back-to-back hit ready every cycle with correct data")
                @(negedge clk);
            end
            cpu_valid = 0;
            `CHECK(t0c == 8, "T11 8 hits in 8 cycles")
        end
        `CHECK(c_hit - s_hit == 8 && c_stl - s_stl == 0, "T11 8 hits, 0 stall cycles")

        // ================= T12 PLRU vs LRU (4-way) =================
        if (WAYS == 4) begin
            // PLRU on set 9, LRU on set 10 : A,B,C,D, A, E, then probe B
            cfg_policy = 2; A0 = 32'h0000_0120;
            for (k = 0; k < 4; k = k + 1) RD(A0 + k*WSZ);
            RD(A0); RD(A0 + 4*WSZ);                                  // E replaces PLRU victim = way2 (C)
            `CHECK(dut.u_ctrl.vway == 2, "T12 PLRU victim after A,B,C,D,A is way2")
            snap; RD(A0 + 1*WSZ); `CHECK(c_hit - s_hit == 1, "T12 PLRU: B still cached")
            snap; RD(A0 + 2*WSZ); `CHECK(c_mis - s_mis == 1, "T12 PLRU: C was evicted")
            cfg_policy = 1; A0 = 32'h0000_0140;
            for (k = 0; k < 4; k = k + 1) RD(A0 + k*WSZ);
            RD(A0); RD(A0 + 4*WSZ);
            `CHECK(dut.u_ctrl.vway == 1, "T12 LRU victim after A,B,C,D,A is way1")
            snap; RD(A0 + 1*WSZ); `CHECK(c_mis - s_mis == 1, "T12 LRU: B was evicted (differs from PLRU)")
        end

        // ================= T13 invariants + counter clear =================
        `CHECK(c_hit + c_mis == c_acc && c_rd + c_wr == c_acc, "T13 hit+miss = read+write = access")
        `CHECK(c_mrd == c_rf * 8, "T13 memory reads = refills * 8")
        @(negedge clk); cnt_clear = 1; @(negedge clk); cnt_clear = 0; #1;
        `CHECK(c_acc == 0 && c_hit == 0 && c_stl == 0 && c_mwr == 0, "T13 cnt_clear zeroes all counters")
        `CHECK(present(32'h0000_0000), "T13 clearing counters does not touch cache contents")

        // ================= T14 runtime policy switching under random traffic =================
        for (i = 0; i < 3000; i = i + 1) begin
            if ((i % 7) == 0) cfg_policy = $random;
            T = ($random & 32'h0000_7FFC);
            if (($random & 7) == 0) WR(T, $random, 4'hF); else RD(T);
        end
        `CHECK(c_hit + c_mis == c_acc, "T14 invariant holds after random traffic with policy switching")
        `CHECK(c_sat == 0, "T14 no counter saturation")

        // ================= T15 reset during a refill =================
        cfg_policy = 1;
        @(negedge clk); cpu_valid = 1; cpu_we = 0; cpu_addr = 32'h0003_7740;
        repeat (L + 3) @(posedge clk);                                // in the middle of the refill
        `CHECK(dut.u_ctrl.state == 2'd1, "T15 FSM is in REFILL")
        @(negedge clk); cpu_valid = 0; rst_n = 0; mem_rst_n = 0;
        repeat (2) @(posedge clk); @(negedge clk); rst_n = 1; mem_rst_n = 1; repeat (2) @(posedge clk); #1;
        `CHECK(dut.u_ctrl.state == 2'd0 && mem_valid == 0, "T15 reset aborts refill: FSM idle, memory port idle")
        for (w = 0; w < WAYS; w = w + 1) `CHECK(dut.u_valid.vbits[w] == {SETS{1'b0}}, "T15 valid bits cleared")
        `CHECK(c_acc == 0 && c_stl == 0, "T15 counters cleared")
        snap; RD(32'h0003_7740);
        `CHECK(c_mis - s_mis == 1 && c_rf - s_rf == 1 && c_stl - s_stl == 1 + 8*L, "T15 cache restarts cold; first access misses normally")
        // reset while idle
        @(negedge clk); rst_n = 0; @(negedge clk); rst_n = 1; #1;
        `CHECK(dut.u_ctrl.state == 2'd0 && c_acc == 0, "T15 reset while idle")

        // ================= T16 no state loss on withdrawal / gaps =================
        RD(32'h0000_0800); repeat (5) @(posedge clk); RD(32'h0000_0800);
        `CHECK(c_hit == 1, "T16 request after idle gap hits")

        `TB_REPORT("cache_directed")
        $finish;
    end
    initial begin #500000000; $display("TBRESULT cache_directed FAIL watchdog"); $finish; end
endmodule
