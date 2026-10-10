//==============================================================================
// adaptive_controller.v   (Phase 2)  -- lightweight deterministic policy selector
//
// IDEA (no machine learning, no multipliers, no dividers):
//   * A few "leader" sets are permanently assigned one candidate policy each
//     (see leader_set_map). Their MISS COUNTS measure how the candidates
//     perform on the SAME workload at the SAME time.
//   * Execution is divided into fixed OBSERVATION WINDOWS of WIN_ACCESSES
//     accepted processor requests.
//   * In a window each leader group counts misses over its first SAMPLE_N
//     accesses (equal sample size => raw miss counts are directly comparable).
//   * At the end of a window the unit compares the candidates' miss counts and
//     decides whether the FOLLOWER sets should switch policy.
//
// HYSTERESIS / STABILITY (all parameters, so they can be ablated):
//   MARGIN      : the best candidate must beat the current policy by >= MARGIN
//                 misses (per SAMPLE_N samples)
//   CONF_THRESH : the same candidate must win this many CONSECUTIVE windows
//                 (saturating confidence counter)
//   MIN_HOLD    : after a switch, no switch is allowed for MIN_HOLD windows
//   Insufficient samples (a leader group saw < SAMPLE_N accesses) => retain.
//
// Event inputs are the same single-cycle pulses that feed performance_monitor.
// The window is evaluated combinationally on the NEXT counter values, so a
// decision takes effect from the very next request (transaction-exact, which
// the Python reference model reproduces).
//
// Policy codes: 0 Random, 1 LRU, 2 PLRU.  Reset active policy = LRU.
//==============================================================================
module adaptive_controller #(
    parameter WAYS         = 4,
    parameter INDEX_W      = 5,
    parameter WIN_ACCESSES = 2048,
    parameter SAMPLE_N     = 64,
    parameter MARGIN       = 4,
    parameter MIN_HOLD     = 1,
    parameter CONF_THRESH  = 2,
    parameter CNT_W        = 32
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enable,        // cfg_policy == 2'b11
    input  wire [INDEX_W-1:0] lk_index,      // set index of the request in progress
    input  wire               ev_access,
    input  wire               ev_miss,
    output wire [1:0]         policy_sel,    // policy to use for lk_index
    output reg  [1:0]         active_policy, // follower-set policy
    output reg  [CNT_W-1:0]   cnt_switch,
    output reg  [CNT_W-1:0]   cnt_window
);
    localparam NCAND = (WAYS == 2) ? 2 : 3;
    localparam ACW   = $clog2(SAMPLE_N + 1);
    localparam WCW   = $clog2(WIN_ACCESSES);
    localparam [31:0]    WIN_LAST32 = WIN_ACCESSES - 1;
    localparam [WCW-1:0] WIN_LAST   = WIN_LAST32[WCW-1:0];
    localparam [ACW-1:0] SN       = SAMPLE_N;
    localparam [ACW:0]   MARGIN_V = MARGIN;
    localparam [3:0]     CONF_T   = CONF_THRESH;
    localparam [7:0]     HOLD_V   = MIN_HOLD;

    // ---- leader classification -------------------------------------------
    wire       is_leader;
    wire [1:0] grp, lpol;
    leader_set_map #(.WAYS(WAYS), .INDEX_W(INDEX_W)) u_map (
        .index(lk_index), .is_leader(is_leader), .grp(grp), .pol(lpol));

    assign policy_sel = (enable && is_leader) ? lpol : active_policy;

    // ---- window state -----------------------------------------------------
    reg [WCW-1:0] win_cnt;
    reg [ACW-1:0] acc0, acc1, acc2;
    reg [ACW-1:0] mis0, mis1, mis2;
    reg [3:0]     conf;
    reg [1:0]     cand_prev;
    reg [7:0]     hold;

    wire cnt_ev  = enable & ev_access;
    wire win_end = cnt_ev & (win_cnt == WIN_LAST);

    // a group sample is taken while that group's access counter < SAMPLE_N
    wire s0 = cnt_ev & is_leader & (grp == 2'd0) & (acc0 < SN);
    wire s1 = cnt_ev & is_leader & (grp == 2'd1) & (acc1 < SN);
    wire s2 = cnt_ev & is_leader & (grp == 2'd2) & (acc2 < SN) & (NCAND == 3);

    wire [ACW-1:0] n_acc0 = acc0 + {{(ACW-1){1'b0}}, s0};
    wire [ACW-1:0] n_acc1 = acc1 + {{(ACW-1){1'b0}}, s1};
    wire [ACW-1:0] n_acc2 = acc2 + {{(ACW-1){1'b0}}, s2};
    wire [ACW-1:0] n_mis0 = mis0 + {{(ACW-1){1'b0}}, (s0 & ev_miss)};
    wire [ACW-1:0] n_mis1 = mis1 + {{(ACW-1){1'b0}}, (s1 & ev_miss)};
    wire [ACW-1:0] n_mis2 = mis2 + {{(ACW-1){1'b0}}, (s2 & ev_miss)};

    // ---- decision (evaluated on next-values; used only at win_end) ---------
    wire v0 = (n_acc0 == SN);
    wire v1 = (n_acc1 == SN);
    wire v2 = (NCAND == 2) ? 1'b1 : (n_acc2 == SN);
    wire all_valid = v0 & v1 & v2;

    wire [ACW:0] m0 = {1'b0, n_mis0};
    wire [ACW:0] m1 = {1'b0, n_mis1};
    // 2-way: candidate 2 does not exist; alias it to candidate 0 so it can never change the minimum
    wire [ACW:0] m2 = (NCAND == 3) ? {1'b0, n_mis2} : m0;

    wire [ACW:0] m01  = (m1 < m0) ? m1 : m0;
    wire [ACW:0] mmin = (m2 < m01) ? m2 : m01;
    wire [ACW:0] cur_miss = (active_policy == 2'd0) ? m0 :
                            (active_policy == 2'd1) ? m1 : m2;

    reg [1:0] best;
    always @* begin
        if (cur_miss == mmin)  best = active_policy;      // ties keep current
        else if (m0 == mmin)   best = 2'd0;
        else if (m1 == mmin)   best = 2'd1;
        else                   best = 2'd2;
    end

    wire [ACW+1:0] need = {1'b0, mmin} + {1'b0, MARGIN_V};
    wire want = all_valid & (best != active_policy) & ({1'b0, cur_miss} >= need);

    wire [3:0] new_conf = ((conf != 4'd0) && (cand_prev == best)) ? (conf + 4'd1) : 4'd1;

    // ---- sequential ----------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            win_cnt <= {WCW{1'b0}};
            acc0 <= {ACW{1'b0}}; acc1 <= {ACW{1'b0}}; acc2 <= {ACW{1'b0}};
            mis0 <= {ACW{1'b0}}; mis1 <= {ACW{1'b0}}; mis2 <= {ACW{1'b0}};
            conf <= 4'd0; cand_prev <= 2'd0; hold <= 8'd0;
            active_policy <= 2'd1;
            cnt_switch <= {CNT_W{1'b0}};
            cnt_window <= {CNT_W{1'b0}};
        end else if (win_end) begin
            cnt_window <= cnt_window + {{(CNT_W-1){1'b0}}, 1'b1};
            win_cnt <= {WCW{1'b0}};
            acc0 <= {ACW{1'b0}}; acc1 <= {ACW{1'b0}}; acc2 <= {ACW{1'b0}};
            mis0 <= {ACW{1'b0}}; mis1 <= {ACW{1'b0}}; mis2 <= {ACW{1'b0}};
            if (hold != 8'd0) begin
                hold <= hold - 8'd1;
                conf <= 4'd0;
            end else if (want) begin
                if (new_conf >= CONF_T) begin
                    active_policy <= best;
                    hold          <= HOLD_V;
                    conf          <= 4'd0;
                    cnt_switch    <= cnt_switch + {{(CNT_W-1){1'b0}}, 1'b1};
                end else begin
                    conf      <= new_conf;
                    cand_prev <= best;
                end
            end else begin
                conf <= 4'd0;
            end
        end else if (cnt_ev) begin
            win_cnt <= win_cnt + {{(WCW-1){1'b0}}, 1'b1};
            acc0 <= n_acc0; acc1 <= n_acc1; acc2 <= n_acc2;
            mis0 <= n_mis0; mis1 <= n_mis1; mis2 <= n_mis2;
        end
    end
endmodule
