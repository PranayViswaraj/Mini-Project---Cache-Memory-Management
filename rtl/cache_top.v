//==============================================================================
// cache_top.v  -- Lightweight reconfigurable (Phase 1) / adaptive (Phase 2)
//                 data-cache controller for a 32-bit processor
//
// ADAPTIVE_EN = 0 : PHASE-1 BASELINE. No adaptive hardware is instantiated;
//                   cfg_policy 11 is reserved and falls back to LRU.
// ADAPTIVE_EN = 1 : PHASE-2 EXTENSION. cfg_policy 11 = Adaptive. Fixed policies
//                   00/01/10 behave bit-for-bit identically to Phase 1.
//
// cfg_policy : 00 Random   01 LRU   10 Pseudo-LRU   11 Adaptive (Phase 2)
//              (change it only between requests)
// Supported : DATA_W = 32, WAYS in {2,4}, power-of-two size/line, >= 8 sets.
//==============================================================================
/* verilator lint_off UNUSEDSIGNAL */   // cur_offset[1:0]: word-aligned accesses only (documented)
module cache_top #(
    parameter ADDR_W       = 32,
    parameter DATA_W       = 32,
    parameter CACHE_BYTES  = 4096,
    parameter LINE_BYTES   = 32,
    parameter WAYS         = 2,
    parameter CNT_W        = 32,
    // Phase-2 parameters
    parameter ADAPTIVE_EN  = 0,
    parameter WIN_ACCESSES = 2048,
    parameter SAMPLE_N     = 64,
    parameter MARGIN       = 4,
    parameter MIN_HOLD     = 1,
    parameter CONF_THRESH  = 2
)(
    input  wire                   clk,
    input  wire                   rst_n,
    // processor interface
    input  wire                   cpu_valid,
    input  wire                   cpu_we,
    input  wire [ADDR_W-1:0]      cpu_addr,
    input  wire [DATA_W-1:0]      cpu_wdata,
    input  wire [DATA_W/8-1:0]    cpu_be,
    output wire                   cpu_ready,
    output wire [DATA_W-1:0]      cpu_rdata,
    // main-memory interface
    output wire                   mem_valid,
    output wire                   mem_we,
    output wire [ADDR_W-1:0]      mem_addr,
    output wire [DATA_W-1:0]      mem_wdata,
    output wire [DATA_W/8-1:0]    mem_be,
    input  wire                   mem_ready,
    input  wire [DATA_W-1:0]      mem_rdata,
    // configuration / status
    input  wire [1:0]             cfg_policy,
    input  wire                   cnt_clear,
    output wire [1:0]             policy_active,
    // performance counters
    output wire [CNT_W-1:0]       cnt_access, cnt_read, cnt_write,
    output wire [CNT_W-1:0]       cnt_hit, cnt_miss,
    output wire [CNT_W-1:0]       cnt_refill, cnt_replace, cnt_stall,
    output wire [CNT_W-1:0]       cnt_memrd, cnt_memwr,
    output wire                   cnt_saturated,
    // adaptive statistics (0 when ADAPTIVE_EN = 0)
    output wire [CNT_W-1:0]       cnt_switch,
    output wire [CNT_W-1:0]       cnt_window
);
    //---------------------------------------------------------------- derived
    localparam WAYS_W    = $clog2(WAYS);
    localparam NUM_LINES = CACHE_BYTES / LINE_BYTES;
    localparam SETS      = NUM_LINES / WAYS;
    localparam OFFSET_W  = $clog2(LINE_BYTES);
    localparam INDEX_W   = $clog2(SETS);
    localparam TAG_W     = ADDR_W - OFFSET_W - INDEX_W;
    localparam WORD_W    = OFFSET_W - 2;
    localparam BE_W      = DATA_W / 8;

    // elaboration-time legality check: instantiating an undefined module
    // makes any unsupported parameter combination a hard error.
    generate
        if (DATA_W != 32 || (WAYS != 2 && WAYS != 4) ||
            (1 << OFFSET_W) != LINE_BYTES || (1 << INDEX_W) != SETS ||
            SETS * WAYS * LINE_BYTES != CACHE_BYTES || SETS < 8) begin : cfg_err
            UNSUPPORTED_CACHE_PARAMETERS u_err();
        end
    endgenerate

    //---------------------------------------------------------------- wires
    wire [ADDR_W-1:0]   cur_addr;
    wire [DATA_W-1:0]   cur_wdata;
    wire [BE_W-1:0]     cur_be;
    wire [WAYS_W-1:0]   cur_way;

    wire [TAG_W-1:0]    cur_tag;
    wire [INDEX_W-1:0]  cur_index;
    wire [OFFSET_W-1:0] cur_offset;
    wire [WORD_W-1:0]   cur_word = cur_offset[OFFSET_W-1:2];   // addresses are word aligned; byte offset [1:0] unused

    wire [WAYS*TAG_W-1:0]  rd_tags;
    wire [WAYS-1:0]        rd_valid;
    wire [WAYS*DATA_W-1:0] rd_data;
    wire                   lk_hit;
    wire [WAYS-1:0]        hit_onehot;     // one-hot match vector (observability only)
    wire [WAYS_W-1:0]      lk_hit_way;

    wire [WAYS_W-1:0]  repl_victim;
    wire               repl_victim_valid = rd_valid[repl_victim];

    wire tag_wr_en, valid_wr_en, dwr_en, dwr_refill;
    wire victim_adv, repl_upd_en;
    wire op_refill, op_write, word_valid, refill_done, wr_done;
    wire [WORD_W-1:0] word_idx;
    wire [DATA_W-1:0] word_data;

    wire ev_access, ev_read, ev_write, ev_hit, ev_miss;
    wire ev_refill, ev_replace, ev_stall, ev_memrd, ev_memwr;

    //---------------------------------------------------------------- decode
    address_decoder #(.ADDR_W(ADDR_W), .OFFSET_W(OFFSET_W), .INDEX_W(INDEX_W)) u_dec (
        .addr(cur_addr), .tag(cur_tag), .index(cur_index), .offset(cur_offset));

    //---------------------------------------------------------------- arrays
    tag_array #(.WAYS(WAYS), .SETS(SETS), .INDEX_W(INDEX_W), .TAG_W(TAG_W)) u_tag (
        .clk(clk), .rd_index(cur_index), .rd_tags(rd_tags),
        .wr_en(tag_wr_en), .wr_way(cur_way), .wr_index(cur_index), .wr_tag(cur_tag));

    valid_array #(.WAYS(WAYS), .SETS(SETS), .INDEX_W(INDEX_W)) u_valid (
        .clk(clk), .rst_n(rst_n), .rd_index(cur_index), .rd_valid(rd_valid),
        .wr_en(valid_wr_en), .wr_way(cur_way), .wr_index(cur_index), .wr_val(1'b1));

    wire [WORD_W-1:0] dwr_word = dwr_refill ? word_idx  : cur_word;
    wire [DATA_W-1:0] dwr_data = dwr_refill ? word_data : cur_wdata;
    wire [BE_W-1:0]   dwr_be   = dwr_refill ? {BE_W{1'b1}} : cur_be;

    data_array #(.WAYS(WAYS), .SETS(SETS), .INDEX_W(INDEX_W), .WORD_W(WORD_W), .DATA_W(DATA_W)) u_data (
        .clk(clk), .rd_index(cur_index), .rd_word(cur_word), .rd_data(rd_data),
        .wr_en(dwr_en), .wr_way(cur_way), .wr_index(cur_index), .wr_word(dwr_word),
        .wr_data(dwr_data), .wr_be(dwr_be));

    assign cpu_rdata = rd_data[cur_way*DATA_W +: DATA_W];

    //---------------------------------------------------------------- hit/miss
    hit_miss_logic #(.WAYS(WAYS), .TAG_W(TAG_W)) u_hm (
        .rd_tags(rd_tags), .rd_valid(rd_valid), .req_tag(cur_tag),
        .hit(lk_hit), .hit_way(lk_hit_way), .hit_onehot(hit_onehot));

    //---------------------------------------------------------------- policy
    wire       adaptive_mode = (cfg_policy == 2'b11);
    wire [1:0] fixed_pol     = adaptive_mode ? 2'b01 : cfg_policy;   // 11 -> LRU
    wire [1:0] policy_eff;

    generate
        if (ADAPTIVE_EN != 0) begin : g_adapt
            wire [1:0] adapt_sel, adapt_active;
            adaptive_controller #(
                .WAYS(WAYS), .INDEX_W(INDEX_W), .WIN_ACCESSES(WIN_ACCESSES),
                .SAMPLE_N(SAMPLE_N), .MARGIN(MARGIN), .MIN_HOLD(MIN_HOLD),
                .CONF_THRESH(CONF_THRESH), .CNT_W(CNT_W)
            ) u_adapt (
                .clk(clk), .rst_n(rst_n), .enable(adaptive_mode),
                .lk_index(cur_index), .ev_access(ev_access), .ev_miss(ev_miss),
                .policy_sel(adapt_sel), .active_policy(adapt_active),
                .cnt_switch(cnt_switch), .cnt_window(cnt_window));
            assign policy_eff    = adaptive_mode ? adapt_sel    : fixed_pol;
            assign policy_active = adaptive_mode ? adapt_active : fixed_pol;
        end else begin : g_noadapt
            assign cnt_switch    = {CNT_W{1'b0}};
            assign cnt_window    = {CNT_W{1'b0}};
            assign policy_eff    = fixed_pol;
            assign policy_active = fixed_pol;
        end
    endgenerate

    //---------------------------------------------------------------- replacement
    replacement_controller #(.WAYS(WAYS), .SETS(SETS), .INDEX_W(INDEX_W)) u_repl (
        .clk(clk), .rst_n(rst_n), .policy(policy_eff),
        .lk_index(cur_index), .lk_valid(rd_valid), .victim_adv(victim_adv),
        .victim(repl_victim),
        .upd_en(repl_upd_en), .upd_index(cur_index), .upd_way(cur_way));

    //---------------------------------------------------------------- controller
    cache_controller #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .WAYS(WAYS)) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .cpu_valid(cpu_valid), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_be(cpu_be), .cpu_ready(cpu_ready),
        .lk_hit(lk_hit), .lk_hit_way(lk_hit_way),
        .repl_victim(repl_victim), .repl_victim_valid(repl_victim_valid),
        .cur_addr(cur_addr), .cur_wdata(cur_wdata), .cur_be(cur_be), .cur_way(cur_way),
        .tag_wr_en(tag_wr_en), .valid_wr_en(valid_wr_en),
        .dwr_en(dwr_en), .dwr_refill(dwr_refill),
        .victim_adv(victim_adv), .repl_upd_en(repl_upd_en),
        .op_refill(op_refill), .op_write(op_write),
        .word_valid(word_valid), .refill_done(refill_done), .wr_done(wr_done),
        .ev_access(ev_access), .ev_read(ev_read), .ev_write(ev_write),
        .ev_hit(ev_hit), .ev_miss(ev_miss), .ev_refill(ev_refill),
        .ev_replace(ev_replace), .ev_stall(ev_stall),
        .ev_memrd(ev_memrd), .ev_memwr(ev_memwr));

    //---------------------------------------------------------------- memory port
    memory_interface #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .OFFSET_W(OFFSET_W)) u_mem (
        .clk(clk), .rst_n(rst_n),
        .op_refill(op_refill), .refill_addr(cur_addr),
        .op_write(op_write), .wr_addr(cur_addr), .wr_data(cur_wdata), .wr_be(cur_be),
        .word_valid(word_valid), .word_idx(word_idx), .word_data(word_data),
        .refill_done(refill_done), .wr_done(wr_done),
        .mem_valid(mem_valid), .mem_we(mem_we), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_ready(mem_ready), .mem_rdata(mem_rdata));

    //---------------------------------------------------------------- monitor
    performance_monitor #(.CNT_W(CNT_W)) u_perf (
        .clk(clk), .rst_n(rst_n), .cnt_clear(cnt_clear),
        .ev_access(ev_access), .ev_read(ev_read), .ev_write(ev_write),
        .ev_hit(ev_hit), .ev_miss(ev_miss),
        .ev_refill(ev_refill), .ev_replace(ev_replace), .ev_stall(ev_stall),
        .ev_memrd(ev_memrd), .ev_memwr(ev_memwr),
        .cnt_access(cnt_access), .cnt_read(cnt_read), .cnt_write(cnt_write),
        .cnt_hit(cnt_hit), .cnt_miss(cnt_miss),
        .cnt_refill(cnt_refill), .cnt_replace(cnt_replace), .cnt_stall(cnt_stall),
        .cnt_memrd(cnt_memrd), .cnt_memwr(cnt_memwr),
        .any_saturated(cnt_saturated));
endmodule
/* verilator lint_on UNUSEDSIGNAL */
