//==============================================================================
// cache_controller.v  -- main cache FSM + request register
//
// WRITE POLICY (frozen for Phase 1 and Phase 2):  WRITE-THROUGH + NO-WRITE-ALLOCATE
//   * read hit   : data returned in the SAME cycle the request is presented
//                  (hit time = 1 cycle, zero stall)
//   * read miss  : victim chosen, line refilled word-by-word, data returned
//   * write hit  : cache word updated AND written to memory (processor stalls
//                  until the memory write completes)
//   * write miss : memory write only; the line is NOT allocated
//   => no dirty bits and no write-back path are needed.
//
// FSM (binary encoded, 2 bits)
//   S_IDLE : combinational lookup of cpu_addr. Decides next state:
//              read hit            -> stay IDLE (cpu_ready=1 this cycle)
//              read miss           -> latch request + victim, go S_RF
//              write hit / miss    -> latch request, go S_WR (cache updated now on hit)
//   S_RF   : op_refill=1. Each memory word is written into the victim way.
//            On the last word: write tag, set valid, update replacement state.
//   S_WR   : op_write=1 until the memory acknowledges.
//   S_RESP : cpu_ready=1 for one cycle, request is accepted, back to IDLE.
//
// Processor protocol: cpu_valid must be held, with stable request fields,
// until cpu_ready is seen. A request is ACCEPTED on a cycle with
// cpu_valid & cpu_ready. A STALL CYCLE is a cycle with cpu_valid & ~cpu_ready.
//==============================================================================
module cache_controller #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter WAYS   = 2
)(
    input  wire                     clk,
    input  wire                     rst_n,
    // processor side
    input  wire                     cpu_valid,
    input  wire                     cpu_we,
    input  wire [ADDR_W-1:0]        cpu_addr,
    input  wire [DATA_W-1:0]        cpu_wdata,
    input  wire [DATA_W/8-1:0]      cpu_be,
    output wire                     cpu_ready,
    // lookup results (combinational, from arrays for cur_addr)
    input  wire                     lk_hit,
    input  wire [$clog2(WAYS)-1:0]  lk_hit_way,
    input  wire [$clog2(WAYS)-1:0]  repl_victim,
    input  wire                     repl_victim_valid,
    // request view used by the datapath
    output wire [ADDR_W-1:0]        cur_addr,
    output wire [DATA_W-1:0]        cur_wdata,
    output wire [DATA_W/8-1:0]      cur_be,
    output wire [$clog2(WAYS)-1:0]  cur_way,
    // array write controls
    output wire                     tag_wr_en,
    output wire                     valid_wr_en,
    output wire                     dwr_en,
    output wire                     dwr_refill,
    // replacement controls
    output wire                     victim_adv,
    output wire                     repl_upd_en,
    // memory interface controls
    output wire                     op_refill,
    output wire                     op_write,
    input  wire                     word_valid,
    input  wire                     refill_done,
    input  wire                     wr_done,
    // event pulses
    output wire                     ev_access, ev_read, ev_write,
    output wire                     ev_hit, ev_miss,
    output wire                     ev_refill, ev_replace,
    output wire                     ev_stall,
    output wire                     ev_memrd, ev_memwr
);
    localparam WAYS_W = $clog2(WAYS);
    localparam [1:0] S_IDLE = 2'd0, S_RF = 2'd1, S_WR = 2'd2, S_RESP = 2'd3;

    reg [1:0]          state, next;
    reg [ADDR_W-1:0]   rq_addr;
    reg                rq_we;
    reg [DATA_W-1:0]   rq_wdata;
    reg [DATA_W/8-1:0] rq_be;
    reg                rq_hit;          // lookup result of the latched request
    reg [WAYS_W-1:0]   vway;            // victim way of the latched read miss
    reg                rq_vvalid;       // victim line was valid (-> eviction)

    wire idle = (state == S_IDLE);
    wire rf   = (state == S_RF);
    wire wr   = (state == S_WR);
    wire resp = (state == S_RESP);

    wire idle_req    = idle & cpu_valid;
    wire rd_hit_now  = idle_req &  lk_hit & ~cpu_we;
    wire wr_hit_now  = idle_req &  lk_hit &  cpu_we;
    wire rd_miss_now = idle_req & ~lk_hit & ~cpu_we;
    wire wr_miss_now = idle_req & ~lk_hit &  cpu_we;

    assign cpu_ready = rd_hit_now | resp;
    wire accept      = cpu_valid & cpu_ready;

    assign cur_addr  = idle ? cpu_addr  : rq_addr;
    assign cur_wdata = idle ? cpu_wdata : rq_wdata;
    assign cur_be    = idle ? cpu_be    : rq_be;
    assign cur_way   = idle ? lk_hit_way : vway;

    // next-state logic
    always @* begin
        next = state;
        case (state)
            S_IDLE: if (rd_miss_now)                  next = S_RF;
                    else if (wr_hit_now | wr_miss_now) next = S_WR;
            S_RF:   if (refill_done)                  next = S_RESP;
            S_WR:   if (wr_done)                      next = S_RESP;
            S_RESP:                                   next = S_IDLE;
            default:                                  next = S_IDLE;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            rq_addr   <= {ADDR_W{1'b0}};
            rq_we     <= 1'b0;
            rq_wdata  <= {DATA_W{1'b0}};
            rq_be     <= {(DATA_W/8){1'b0}};
            rq_hit    <= 1'b0;
            vway      <= {WAYS_W{1'b0}};
            rq_vvalid <= 1'b0;
        end else begin
            state <= next;
            if (idle_req & ~rd_hit_now) begin
                rq_addr  <= cpu_addr;
                rq_we    <= cpu_we;
                rq_wdata <= cpu_wdata;
                rq_be    <= cpu_be;
                rq_hit   <= lk_hit;
            end
            if (rd_miss_now) begin
                vway      <= repl_victim;
                rq_vvalid <= repl_victim_valid;
            end
        end
    end

    // array / replacement / memory controls
    assign dwr_en      = wr_hit_now | (rf & word_valid);
    assign dwr_refill  = rf;
    assign tag_wr_en   = rf & refill_done;
    assign valid_wr_en = rf & refill_done;
    assign victim_adv  = rd_miss_now;
    assign repl_upd_en = rd_hit_now | wr_hit_now | (rf & refill_done);
    assign op_refill   = rf;
    assign op_write    = wr;

    // events
    assign ev_access  = accept;
    assign ev_read    = accept & (idle | ~rq_we);
    assign ev_write   = accept & ~idle &  rq_we;
    assign ev_hit     = accept & (idle |  rq_hit);
    assign ev_miss    = accept & ~idle & ~rq_hit;
    assign ev_refill  = rf & refill_done;
    assign ev_replace = rf & refill_done & rq_vvalid;
    assign ev_stall   = cpu_valid & ~cpu_ready;
    assign ev_memrd   = rf & word_valid;
    assign ev_memwr   = wr & wr_done;
endmodule
