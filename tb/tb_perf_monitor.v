`timescale 1ns/1ps
`include "tb_common.vh"
module tb_perf_monitor;
    integer checks = 0, errors = 0, i;
    reg clk = 0, rst_n = 0, clr = 0;
    always #5 clk = ~clk;
    reg ev_access=0, ev_read=0, ev_write=0, ev_hit=0, ev_miss=0, ev_refill=0, ev_replace=0, ev_stall=0, ev_memrd=0, ev_memwr=0;
    wire [31:0] c_acc, c_rd, c_wr, c_hit, c_mis, c_rf, c_rep, c_stl, c_mrd, c_mwr; wire sat;
    performance_monitor #(.CNT_W(32)) dut (.clk(clk), .rst_n(rst_n), .cnt_clear(clr),
        .ev_access(ev_access), .ev_read(ev_read), .ev_write(ev_write), .ev_hit(ev_hit), .ev_miss(ev_miss),
        .ev_refill(ev_refill), .ev_replace(ev_replace), .ev_stall(ev_stall), .ev_memrd(ev_memrd), .ev_memwr(ev_memwr),
        .cnt_access(c_acc), .cnt_read(c_rd), .cnt_write(c_wr), .cnt_hit(c_hit), .cnt_miss(c_mis),
        .cnt_refill(c_rf), .cnt_replace(c_rep), .cnt_stall(c_stl), .cnt_memrd(c_mrd), .cnt_memwr(c_mwr), .any_saturated(sat));
    // tiny 4-bit counter instance for overflow behaviour
    reg inc4 = 0, clr4 = 0; wire [3:0] c4; wire s4;
    sat_counter #(.W(4)) u_small4 (.clk(clk), .rst_n(rst_n), .clear(clr4), .inc(inc4), .count(c4), .saturated(s4));

    task pulse(input [9:0] ev);        // {access,read,write,hit,miss,refill,replace,stall,memrd,memwr}
        begin @(negedge clk); {ev_access,ev_read,ev_write,ev_hit,ev_miss,ev_refill,ev_replace,ev_stall,ev_memrd,ev_memwr} = ev;
              @(negedge clk); {ev_access,ev_read,ev_write,ev_hit,ev_miss,ev_refill,ev_replace,ev_stall,ev_memrd,ev_memwr} = 10'b0; end
    endtask
    initial begin
        repeat (3) @(posedge clk);
        `CHECK(c_acc === 0 && c_stl === 0 && c4 === 0, "reset value 0")
        @(negedge clk); rst_n = 1;
        pulse(10'b1_1_0_1_0_0_0_0_0_0);  #1;   // read hit
        `CHECK(c_acc == 1 && c_rd == 1 && c_hit == 1 && c_mis == 0 && c_wr == 0, "read hit increments access/read/hit only")
        pulse(10'b1_1_0_0_1_1_1_0_1_0);  #1;   // read miss with refill+replace+memrd
        `CHECK(c_acc == 2 && c_rd == 2 && c_mis == 1 && c_rf == 1 && c_rep == 1 && c_mrd == 1, "read miss event group")
        pulse(10'b1_0_1_0_1_0_0_0_0_1);  #1;   // write miss
        `CHECK(c_acc == 3 && c_wr == 1 && c_mis == 2 && c_mwr == 1, "write miss event group")
        // all events simultaneously
        pulse(10'b1111111111); #1;
        `CHECK(c_acc == 4 && c_stl == 1 && c_mrd == 2 && c_mwr == 2, "simultaneous events all counted once")
        // multi-cycle stall: 25 consecutive stall cycles
        @(negedge clk); ev_stall = 1; repeat (25) @(negedge clk); ev_stall = 0; #1;
        `CHECK(c_stl == 26, "stall counts every cycle (1 + 25)")
        // clear has priority over a coincident event
        @(negedge clk); clr = 1; ev_access = 1; @(negedge clk); clr = 0; ev_access = 0; #1;
        `CHECK(c_acc == 0 && c_stl == 0 && c_mwr == 0, "clear zeroes all counters; coincident event dropped")
        // reset clears
        pulse(10'b1_1_0_1_0_0_0_0_0_0); @(negedge clk); rst_n = 0; @(negedge clk); rst_n = 1; #1;
        `CHECK(c_acc == 0, "sync reset clears")
        // --- saturation (4-bit): 20 increments must stop at 15 and flag saturated
        @(negedge clk); inc4 = 1; repeat (20) @(negedge clk); inc4 = 0; #1;
        `CHECK(c4 == 4'hF && s4 == 1, "saturates at all-ones, no wrap-around")
        @(negedge clk); clr4 = 1; @(negedge clk); clr4 = 0; #1;
        `CHECK(c4 == 0 && s4 == 0, "clear releases saturation")
        // random events: counters equal an independent tally
        begin : rnd
            integer ta, tr, tw, th, tm, trf, trp, ts, tmr, tmw; reg [9:0] e;
            ta=0; tr=0; tw=0; th=0; tm=0; trf=0; trp=0; ts=0; tmr=0; tmw=0;
            for (i = 0; i < 3000; i = i + 1) begin
                e = $random;
                @(negedge clk); {ev_access,ev_read,ev_write,ev_hit,ev_miss,ev_refill,ev_replace,ev_stall,ev_memrd,ev_memwr} = e;
                ta=ta+e[9]; tr=tr+e[8]; tw=tw+e[7]; th=th+e[6]; tm=tm+e[5]; trf=trf+e[4]; trp=trp+e[3]; ts=ts+e[2]; tmr=tmr+e[1]; tmw=tmw+e[0];
            end
            @(negedge clk); {ev_access,ev_read,ev_write,ev_hit,ev_miss,ev_refill,ev_replace,ev_stall,ev_memrd,ev_memwr} = 10'b0; #1;
            `CHECK(c_acc==ta && c_rd==tr && c_wr==tw && c_hit==th && c_mis==tm && c_rf==trf && c_rep==trp && c_stl==ts && c_mrd==tmr && c_mwr==tmw, "3000 random events match tally")
        end
        `TB_REPORT("performance_monitor")
        $finish;
    end
endmodule
