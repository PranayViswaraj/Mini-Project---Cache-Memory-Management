//==============================================================================
// tb_cache_system.v -- trace-driven, SELF-CHECKING system testbench
//
// Plusargs: +TRACE=<hex file>  +LOG=<per-request log>  +POLICY=<0..3>
//           +LAT=<cycles/word>  +GAP=<idle cycles between requests>  +RGAP=1
// Trace line (72 bits, hex): {op[3:0], be[3:0], addr[31:0], data[31:0]}
//           op 0 = read, 1 = write, F = end of trace
//
// Checks performed by the testbench itself (independent of the Python model):
//   1. every read returns the value held by an independent shadow memory
//   2. performance counters == testbench tallies (access/read/write/stall)
//   3. hits + misses == accesses ; reads + writes == accesses
//   4. memory reads == refills * words-per-line ; memory writes == writes
//   5. memory-model transaction counts == DUT memory counters
// The per-request log (hit, way, data, active policy) is compared with the
// Python reference model by sim/run_regression.py.
//==============================================================================
`timescale 1ns/1ps
module tb_cache_system;
    parameter CACHE_BYTES  = 4096;
    parameter LINE_BYTES   = 32;
    parameter WAYS         = 2;
    parameter ADAPTIVE_EN  = 1;
    parameter WIN_ACCESSES = 2048;
    parameter SAMPLE_N     = 64;
    parameter MARGIN       = 4;
    parameter MIN_HOLD     = 1;
    parameter CONF_THRESH  = 2;
    parameter MEM_AW       = 18;
    parameter MAX_REQ      = 65536;

    localparam WPL = LINE_BYTES/4;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    reg         cpu_valid = 0, cpu_we = 0;
    reg  [31:0] cpu_addr = 0, cpu_wdata = 0;
    reg  [3:0]  cpu_be = 4'hF;
    wire        cpu_ready;
    wire [31:0] cpu_rdata;
    wire        mem_valid, mem_we, mem_ready;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [3:0]  mem_be;
    reg  [1:0]  cfg_policy = 0;
    reg         cnt_clear = 0;
    wire [1:0]  policy_active;
    wire [31:0] cnt_access, cnt_read, cnt_write, cnt_hit, cnt_miss;
    wire [31:0] cnt_refill, cnt_replace, cnt_stall, cnt_memrd, cnt_memwr;
    wire [31:0] cnt_switch, cnt_window;
    wire        cnt_saturated;

    cache_top #(.CACHE_BYTES(CACHE_BYTES), .LINE_BYTES(LINE_BYTES), .WAYS(WAYS),
                .ADAPTIVE_EN(ADAPTIVE_EN), .WIN_ACCESSES(WIN_ACCESSES),
                .SAMPLE_N(SAMPLE_N), .MARGIN(MARGIN), .MIN_HOLD(MIN_HOLD),
                .CONF_THRESH(CONF_THRESH)) dut (
        .clk(clk), .rst_n(rst_n),
        .cpu_valid(cpu_valid), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_be(cpu_be), .cpu_ready(cpu_ready), .cpu_rdata(cpu_rdata),
        .mem_valid(mem_valid), .mem_we(mem_we), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_be(mem_be), .mem_ready(mem_ready), .mem_rdata(mem_rdata),
        .cfg_policy(cfg_policy), .cnt_clear(cnt_clear), .policy_active(policy_active),
        .cnt_access(cnt_access), .cnt_read(cnt_read), .cnt_write(cnt_write),
        .cnt_hit(cnt_hit), .cnt_miss(cnt_miss), .cnt_refill(cnt_refill),
        .cnt_replace(cnt_replace), .cnt_stall(cnt_stall),
        .cnt_memrd(cnt_memrd), .cnt_memwr(cnt_memwr), .cnt_saturated(cnt_saturated),
        .cnt_switch(cnt_switch), .cnt_window(cnt_window));

    mem_model #(.AW(MEM_AW)) mem (
        .clk(clk), .rst_n(rst_n), .mem_valid(mem_valid), .mem_we(mem_we),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_ready(mem_ready), .mem_rdata(mem_rdata));

    // -------------------------------------------------------------- shadow memory
    reg [31:0] shadow [0:(1<<MEM_AW)-1];
    reg [71:0] trace  [0:MAX_REQ-1];

    reg [8*256-1:0] trace_file, log_file;
    integer fd, POLICY, GAP, RGAP;
    integer i, b, errors, tb_acc, tb_rd, tb_wr, tb_stall, tb_cycles, k;
    reg [3:0]  op, be;
    reg [31:0] addr, data, exp, got;
    reg        done, s_hit;
    reg [31:0] s_way;
    reg [31:0] rseed;

    initial begin
        trace_file = "trace.hex"; log_file = "";
        POLICY = 1; GAP = 0; RGAP = 0;
        if ($value$plusargs("TRACE=%s", trace_file)) ;
        if ($value$plusargs("LOG=%s",   log_file))   ;
        if ($value$plusargs("POLICY=%d", POLICY))    ;
        if ($value$plusargs("GAP=%d",   GAP))        ;
        if ($value$plusargs("RGAP=%d",  RGAP))       ;
        for (k = 0; k < (1<<MEM_AW); k = k + 1) shadow[k] = (k * 32'h9E3779B1) ^ 32'hA5A5A5A5;
        for (k = 0; k < MAX_REQ; k = k + 1) trace[k] = {4'hF, 68'h0};
        $readmemh(trace_file, trace);
        rseed = 32'h1234_5678;
        errors = 0; tb_acc = 0; tb_rd = 0; tb_wr = 0; tb_stall = 0; tb_cycles = 0;

        // reset
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (2) @(posedge clk);
        @(negedge clk); cfg_policy = POLICY[1:0];
        if (log_file != "") fd = $fopen(log_file, "w"); else fd = 0;

        i = 0;
        while (trace[i][71:68] != 4'hF) begin
            op = trace[i][71:68]; be = trace[i][67:64];
            addr = trace[i][63:32]; data = trace[i][31:0];
            @(negedge clk);
            cpu_valid = 1; cpu_we = (op == 4'h1); cpu_addr = addr;
            cpu_wdata = data; cpu_be = (op == 4'h1) ? be : 4'hF;
            done = 0;
            while (!done) begin
                @(posedge clk);
                tb_cycles = tb_cycles + 1;
                if (cpu_ready) begin
                    done  = 1;
                    s_hit = dut.ev_hit;
                    s_way = dut.cur_way;
                    got   = cpu_rdata;
                    if (op == 4'h0) begin
                        exp = shadow[addr[MEM_AW+1:2]];
                        if (got !== exp) begin
                            errors = errors + 1;
                            if (errors < 10) $display("ERROR req %0d: read %h got %h exp %h", i, addr, got, exp);
                        end
                        tb_rd = tb_rd + 1;
                    end else begin
                        for (b = 0; b < 4; b = b + 1)
                            if (be[b]) shadow[addr[MEM_AW+1:2]][8*b +: 8] = data[8*b +: 8];
                        tb_wr = tb_wr + 1;
                    end
                    tb_acc = tb_acc + 1;
                    if (fd != 0) begin
                        if (op == 4'h0)
                            $fdisplay(fd, "%0d %0d %h %0d %0d %h %0d", i, op, addr, s_hit, s_way, got, policy_active);
                        else    // writes: no victim way reported, no read data
                            $fdisplay(fd, "%0d %0d %h %0d -1 00000000 %0d", i, op, addr, s_hit, policy_active);
                    end
                end else begin
                    tb_stall = tb_stall + 1;
                end
            end
            if (GAP > 0 || RGAP != 0) begin
                @(negedge clk); cpu_valid = 0;
                if (RGAP != 0) begin
                    rseed = rseed * 1103515245 + 12345;
                    repeat (rseed[18:16] % 4) @(posedge clk);
                end
                repeat (GAP) @(posedge clk);
            end
            i = i + 1;
        end
        @(negedge clk); cpu_valid = 0;
        repeat (4) @(posedge clk);

        // ---------------------------------------------------- end-of-run checks
        if (cnt_access !== tb_acc) begin errors = errors + 1; $display("ERROR cnt_access %0d != tb %0d", cnt_access, tb_acc); end
        if (cnt_read   !== tb_rd ) begin errors = errors + 1; $display("ERROR cnt_read %0d != tb %0d",   cnt_read,   tb_rd ); end
        if (cnt_write  !== tb_wr ) begin errors = errors + 1; $display("ERROR cnt_write %0d != tb %0d",  cnt_write,  tb_wr ); end
        if (cnt_stall  !== tb_stall) begin errors = errors + 1; $display("ERROR cnt_stall %0d != tb %0d", cnt_stall, tb_stall); end
        if (cnt_hit + cnt_miss !== cnt_access) begin errors = errors + 1; $display("ERROR hit+miss != access"); end
        if (cnt_read + cnt_write !== cnt_access) begin errors = errors + 1; $display("ERROR read+write != access"); end
        if (cnt_memrd !== cnt_refill * WPL) begin errors = errors + 1; $display("ERROR memrd != refill*WPL"); end
        if (cnt_memwr !== cnt_write) begin errors = errors + 1; $display("ERROR memwr != writes"); end
        if (mem.rd_count !== cnt_memrd || mem.wr_count !== cnt_memwr) begin errors = errors + 1; $display("ERROR memory-model count mismatch"); end
        if (cnt_saturated) begin errors = errors + 1; $display("ERROR unexpected counter saturation"); end

        $display("STAT access=%0d read=%0d write=%0d hit=%0d miss=%0d refill=%0d replace=%0d stall=%0d memrd=%0d memwr=%0d switch=%0d window=%0d cycles=%0d active=%0d",
                 cnt_access, cnt_read, cnt_write, cnt_hit, cnt_miss, cnt_refill, cnt_replace,
                 cnt_stall, cnt_memrd, cnt_memwr, cnt_switch, cnt_window, tb_cycles, policy_active);
        if (errors == 0) $display("RESULT PASS errors=0");
        else             $display("RESULT FAIL errors=%0d", errors);
        if (fd != 0) $fclose(fd);
        $finish;
    end

    // watchdog
    initial begin
        #2000000000;
        $display("RESULT FAIL watchdog timeout");
        $finish;
    end
endmodule
