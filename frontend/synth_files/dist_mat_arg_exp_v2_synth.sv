//=============================================================================
// Module: dist_mat_arg_exp_v2  ("exp block", v2)
//
// This module is the synthesizable version of the dist_mat_arg_exp_v2 module.
// It includes, in particular, a synthesizable ROM, unlike the dist_mat_arg_exp_v2
// module used for RTL simulation, whose ROM contents are preloaded using the
// readmemh directive.
//
// Streams the unnormalized Gaussian-kernel similarity matrix P directly to
// grad_v2, one coefficient per cycle, with NO row buffer in between --
// unlike v1 (dist_mat_arg_exp), which wrote each row into a ping-pong
// buffer for grad to read back (see ADR-0003). This implements ADR-0008.
//
// Normalizing a row still requires its full sum before any coefficient in
// it can be normalized, and that sum is only known once every coefficient
// has been produced -- so instead of buffering the row (v1's answer), this
// version computes each row TWICE, on two identical compute pipelines
// running exactly one pass apart:
//   - the SUM pipeline computes sum_row_P for the CURRENT pass's row,
//     using a freshly fetched reference point;
//   - the P_ij pipeline forwards the REAL coefficients for the PREVIOUS
//     pass's row, using that row's reference point (held one pass longer
//     in a second register stage), by which point its sum has already
//     been computed and forwarded to grad_v2.
// This keeps total latency at NB_POINTS+1 passes instead of the 2*NB_POINTS
// a naive "compute every row twice, sequentially" approach would cost.
// See docs/blocks/exp_block_v2.md section 2 for the full row-offset
// explanation and a pass-by-pass table.
//
// Both point i and its neighbours j are still read from a single shared
// coordinate BRAM port -- only the compute pipeline and the exp_LUT read
// port are duplicated, not the coordinate memory access itself.
//
// Related design decisions:
//   ADR-0001 - fixed-point quantization chain
//   ADR-0002 - row-streaming instead of storing the full P matrix
//   ADR-0003 - v1's ping-pong buffering (superseded here by ADR-0008)
//   ADR-0004 - LUT-based exp() instead of CORDIC
//   ADR-0008 - on-the-fly row processing / duplicated exp pipeline (this module)
//
// See docs/blocks/exp_block_v2.md for the full delta documentation, and
// docs/blocks/exp_block.md for everything unchanged from v1 (per-stage
// pipeline math, quantization formats, LUT saturation behavior).
//=============================================================================



module dist_mat_arg_exp_v2 #(
    parameter int COORD_W      = 16,         // Coordinate width, fixed-point
    parameter int ADDR_W       = 7,          // Point BRAM address width
    parameter int P_IJ_W       = 16,         // P_ij width, fixed-point
    parameter int ADDR_P_IJ_W  = 7,          // P_ij address width
    parameter int SUM_ROW_P_W  = 32,         // sum_row_P accumulator width
    parameter int ADDR_LUT_EXP = 14,         // exp LUT address width
    parameter int STEP_W       = 6,          // Iteration counter width (max_iter=50 -> 6 bits is enough)
    parameter int K_W          = 16,         // Precomputed K_step constant width, signed, always negative
    parameter int D2_W         = 2 * COORD_W // dx*dx / dy*dy: product of two COORD_W-bit value
	)(
	input  logic             clk,
	input  logic             rst_n,

    // Added for v3 (see ADR-0011): nb_points is now loaded at runtime via
    // NB_POINTS_LOADER instead of being a compile-time NB_POINTS parameter,
    // letting the same fabricated chip process any benchmark up to its
    // physical 4096-point capacity (ADR-0007), not only the exact point count
    // it was synthesized for.
    input  logic [11:0]      nb_points,

    input logic              start,     // Launches a full sweep (all rows) for the current step
    input logic [STEP_W-1:0] step_idx,  // Current iteration index, selects K_step from the ROM

    // --- Point coordinate BRAM port (shared for both i and j accesses) ---
    output logic [ADDR_W-1:0]  addr,
    input  logic [COORD_W-1:0] coord_X,
    input  logic [COORD_W-1:0] coord_Y,

    // --- exp LUT port: exp_lut[index = arg + 10240] ---
    output logic [ADDR_LUT_EXP-1:0] index_LUT_exp,     // P_ij pipeline
    input  logic [COORD_W-1:0]      result_exp,
    output logic [ADDR_LUT_EXP-1:0] index_LUT_exp_sum, // sum pipeline
    input  logic [COORD_W-1:0]      result_exp_sum,

	// --- Output to grad_v2 (no arbiter in between, see ADR-0008) ---
    output logic [P_IJ_W - 1:0]    P_ij,      // exp(arg_ij), saturated to 0 if arg out of LUT range
    output logic [ADDR_P_IJ_W-1:0] out_i,
    output logic [ADDR_P_IJ_W-1:0] out_j,
    output logic [ADDR_P_IJ_W-1:0] out_i_sum, // Row/column the just-completed sum_row_P belongs to
    output logic [ADDR_P_IJ_W-1:0] out_j_sum,
    output logic                   valid_out,

    output logic [SUM_ROW_P_W-1:0] sum_row_P,
    output logic                   valid_sum_row_P,

    output logic done
);
    // -------------------------------------------------------------------
    // K_step ROM: K_step = -1 / (2*T^2), precomputed in software per step
    // and preloaded from file.
    // -------------------------------------------------------------------
    logic signed [K_W-1:0] K_step_r;
    logic signed [K_W-1:0] K_step_value;
    always_comb begin
        case (step_idx)
            6'd0:  K_step_value = 16'hFFFE;
            6'd1:  K_step_value = 16'hFFFF;
            6'd2:  K_step_value = 16'hFFFF;
            6'd3:  K_step_value = 16'hFFFF;
            6'd4:  K_step_value = 16'hFFFF;
            6'd5:  K_step_value = 16'hFFFF;
            6'd6:  K_step_value = 16'hFFFF;
            6'd7:  K_step_value = 16'hFFFF;
            6'd8:  K_step_value = 16'hFFFF;
            6'd9:  K_step_value = 16'hFFFF;
            6'd10: K_step_value = 16'hFFFF;
            6'd11: K_step_value = 16'hFFFF;
            6'd12: K_step_value = 16'hFFFF;
            6'd13: K_step_value = 16'h0000;
            6'd14: K_step_value = 16'h0000;
            6'd15: K_step_value = 16'h0000;
            6'd16: K_step_value = 16'h0000;
            6'd17: K_step_value = 16'h0000;
            6'd18: K_step_value = 16'h0000;
            6'd19: K_step_value = 16'h0000;
            6'd20: K_step_value = 16'h0000;
            6'd21: K_step_value = 16'h0000;
            6'd22: K_step_value = 16'h0000;
            6'd23: K_step_value = 16'h0000;
            6'd24: K_step_value = 16'h0000;
            6'd25: K_step_value = 16'h0000;
            6'd26: K_step_value = 16'h0000;
            6'd27: K_step_value = 16'h0000;
            6'd28: K_step_value = 16'h0000;
            6'd29: K_step_value = 16'h0000;
            6'd30: K_step_value = 16'h0000;
            6'd31: K_step_value = 16'h0000;
            6'd32: K_step_value = 16'h0000;
            6'd33: K_step_value = 16'h0000;
            6'd34: K_step_value = 16'h0000;
            6'd35: K_step_value = 16'h0000;
            6'd36: K_step_value = 16'h0000;
            6'd37: K_step_value = 16'h0000;
            6'd38: K_step_value = 16'h0000;
            6'd39: K_step_value = 16'h0000;
            6'd40: K_step_value = 16'h0000;
            6'd41: K_step_value = 16'h0000;
            6'd42: K_step_value = 16'h0000;
            6'd43: K_step_value = 16'h0000;
            6'd44: K_step_value = 16'h0000;
            6'd45: K_step_value = 16'h0000;
            6'd46: K_step_value = 16'h0000;
            6'd47: K_step_value = 16'h0000;
            6'd48: K_step_value = 16'h0000;
            6'd49: K_step_value = 16'h0000;

            default: K_step_value = 16'h0000;
        endcase
    end

    // -------------------------------------------------------------------
    // Sequencing FSM
    // -------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE,       // Idle, waiting for start
        S_FETCH_I,    // Issue addr = cnt_i (reference point of the new row)
        S_FETCH_WAIT, // Issue addr = cnt_j (=0); capture coord_X_i / coord_Y_i from the BRAM response
        S_RUN,        // Stream addr = cnt_j across the row
        S_LAST_WAIT,  // Last j of the row issued; wait here (see credit_avail below)
        S_DRAIN,      // Let the compute pipeline flush the last row's in-flight data
        S_DONE        // Sweep complete
    } state_t;

 
    state_t current_state, next_state;
 
    logic [ADDR_W-1:0] cnt_i;
    logic [ADDR_W-1:0] cnt_j;
 
    logic issue_i;       // 1 when addr carries a valid i-fetch this cycle
    logic issue_j;       // 1 when addr carries a valid j-fetch this cycle
    logic issue_j_sum;   // 1 when addr carries a valid j-fetch this cycle

    assign issue_i = (current_state == S_FETCH_I);


    // The P_ij pipeline forwards row (cnt_i - 1), so it has nothing to do on
    // the very first pass (cnt_i == 0, no "row -1"). The sum pipeline
    // computes row cnt_i, so it has nothing to do on the extra final pass
    // (cnt_i == NB_POINTS, every row already has a sum by then). See
    // docs/blocks/exp_block_v2.md section 2 for the full pass-by-pass table.
    assign issue_j     = ((current_state == S_FETCH_WAIT) || (current_state == S_RUN)) && (cnt_i != 0);
    assign issue_j_sum = ((current_state == S_FETCH_WAIT) || (current_state == S_RUN)) && (cnt_i != nb_points);

 
    // -------------------------------------------------------------------
    // BRAM address mux
    // -------------------------------------------------------------------
    assign addr = issue_i ? cnt_i : cnt_j;
 
    // -------------------------------------------------------------------
    // i / j counter management
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_i <= '0;
            cnt_j <= '0;
        end else begin
            case (current_state)
                S_IDLE: begin
                    if (start) cnt_i <= '0;
                end

                S_FETCH_I: begin
                    cnt_j <= '0;
                end

                S_FETCH_WAIT: begin
                    cnt_j <= cnt_j + 1'b1;   // j=0 was just issued; prepare j=1
                end
 
                S_RUN: begin
                    if (cnt_j != nb_points - 1)
                        cnt_j <= cnt_j + 1'b1;
                    // else: last address of the row already issued, hold cnt_j
                end

                S_LAST_WAIT: begin
                    // Unconditional advance -- no credit/flow-control wait
                    // here anymore (v1's ping-pong buffer, and the
                    // credit_avail signal that protected it, are both gone,
                    // see ADR-0008). Runs through cnt_i == NB_POINTS once,
                    // for the extra final pass (see docs/blocks/exp_block_v2.md).
                    if ((cnt_i != nb_points))
                        cnt_i <= cnt_i + 1'b1;
                end
 
                default: begin
                    // cnt_i / cnt_j held constant during S_DRAIN / S_DONE
                end
            endcase
        end
    end

    // Pipeline drain counter
    localparam int PIPE_DEPTH = 8; // Number of pipeline stages, see docs/blocks/exp_block.md section 4
    logic [$clog2(PIPE_DEPTH+1)-1:0] drain_cnt;
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) drain_cnt <= '0;
        else if (current_state == S_DRAIN) drain_cnt <= drain_cnt + 1'b1;
        else drain_cnt <= '0;
    end
 
    // -------------------------------------------------------------------
    // FSM: transition logic
    // -------------------------------------------------------------------
    always_comb begin
        next_state = current_state;
        unique case (current_state)
            S_IDLE       : next_state = start ? S_FETCH_I : S_IDLE;
            S_FETCH_I    : next_state = S_FETCH_WAIT;
            S_FETCH_WAIT : next_state = S_RUN;
            S_RUN        : next_state = (cnt_j == nb_points - 1) ? S_LAST_WAIT : S_RUN;
            // cnt_i here is still the PRE-increment value for this pass (the
            // increment above happens the same cycle); reaching S_DRAIN only
            // once cnt_i was already NB_POINTS means the extra final pass
            // (cnt_i == NB_POINTS) still runs through S_FETCH_I once more
            // before draining.
            S_LAST_WAIT  : next_state = (cnt_i == nb_points) ? S_DRAIN : S_FETCH_I;
            S_DRAIN      : next_state = (drain_cnt == PIPE_DEPTH - 1) ? S_DONE : S_DRAIN;
            S_DONE       : next_state = S_IDLE;
            default      : next_state = S_IDLE;
        endcase
    end
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) current_state <= S_IDLE;
        else        current_state <= next_state;
    end
 
    assign done = (current_state == S_DONE);
 
    // Latch K_step at the start of the step; held constant for the whole sweep
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) K_step_r <= '0;
        else if (current_state == S_IDLE && start) K_step_r <= K_step_value;
    end
 

    // -------------------------------------------------------------------
    // Shift-register tags: independent of the current FSM state, derived
    // from which address was issued the previous cycle. Used to keep the
    // BRAM response aligned with the (i, j) pair it corresponds to.
    // -------------------------------------------------------------------
    logic              i_capture_d;   // 1: the BRAM response this cycle is the i-fetch
    logic              j_valid_d;     // 1: the BRAM response this cycle is a valid j-fetch for the P_ij pipeline
    logic              j_valid_d_sum; // 1: the BRAM response this cycle is a valid j-fetch for the sum pipeline
    logic [ADDR_W-1:0] j_idx_d;       // j index matching the response on the bus
    logic [ADDR_W-1:0] i_idx_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_capture_d   <= 1'b0;
            j_valid_d     <= 1'b0;
            j_valid_d_sum <= 1'b0;
            j_idx_d       <= '0;
            i_idx_d       <= '0;
        end else begin
            i_capture_d   <= issue_i;
            j_valid_d     <= issue_j;
            j_valid_d_sum <= issue_j_sum;
            j_idx_d       <= cnt_j;
            i_idx_d       <= cnt_i;
        end
    end

    // -------------------------------------------------------------------
    // Two-deep coordinate shift register for the reference point:
    //   coord_X_i_sum/coord_Y_i_sum <- freshly fetched this pass (point cnt_i),
    //     used by the SUM pipeline for row cnt_i.
    //   coord_X_i/coord_Y_i         <- what coord_X_i_sum held LAST pass
    //     (point cnt_i - 1), used by the P_ij pipeline for row cnt_i - 1.
    // This one-pass delay is exactly what lets the P_ij pipeline forward a
    // row using its reference point one pass after the sum pipeline first
    // fetched it (see docs/blocks/exp_block_v2.md section 2).
    // -------------------------------------------------------------------
    logic [COORD_W-1:0] coord_X_i, coord_Y_i;
    logic [COORD_W-1:0] coord_X_i_sum, coord_Y_i_sum;

    always_ff @(posedge clk) begin
        if (i_capture_d) begin
            coord_X_i_sum <= coord_X;
            coord_Y_i_sum <= coord_Y;
            coord_X_i     <= coord_X_i_sum;
            coord_Y_i     <= coord_Y_i_sum;
        end
    end


 
// -------------------------------------------------------------------
// Compute pipeline forwarding the real P_ij coefficients, for row
// (cnt_i - 1). Identical stage-by-stage structure to v1's single pipeline
// -- see docs/blocks/exp_block.md section 4 for the full description.
// -------------------------------------------------------------------
    logic signed [COORD_W:0]   dx, dy;
    logic [ADDR_W-1:0]         i_1, j_1;
    logic                      valid_1;
 
    // Stage 1 -> 2: squares
    logic [2*COORD_W-1:0] x_2, y_2;
    logic [ADDR_W-1:0]      i_2, j_2;
    logic                   valid_2;

    // Stage 2 -> 3: D2 = x2 + y2
    logic [2*COORD_W:0] D2_ij;
    logic [ADDR_W-1:0]      i_3, j_3;
    logic                   valid_3;

    // Stage 3 -> 4: arg_exp_brut = D2 * K_step (always <= 0)
    logic signed [D2_W + K_W - 1:0] arg_exp_brut;
    logic [ADDR_W-1:0]      i_4, j_4;
    logic                   valid_4;

    // Stage 4 -> 5: arg_exp_q6_10 = arg_exp_brut >>> 22 (align to the Q6.10
    // format expected by the LUT address, per the quantization chain in ADR-0001)
    logic [D2_W + K_W - 1:0] arg_exp_q6_10;
    logic signed [21:0] arg_shifted;
    logic [ADDR_W-1:0]      i_5, j_5;
    logic                   valid_5;

    // Stage 5 -> 6: bias the argument into a valid LUT address, or flag it
    // as out of range (saturates P_ij to 0, mirrors the reference model's
    // exp_lut saturation behavior, see ADR-0004)
    logic                   flag_exp;
    logic [ADDR_W-1:0]      i_6, j_6;
    logic                   valid_6;

    // Stage 6 -> 7: the LUT answers one cycle after index_LUT_exp is driven;
    // delay flag_exp/i/j/valid by one more stage to stay aligned with result_exp.
    logic              flag_exp_d;
    logic [ADDR_W-1:0] i_7, j_7;
    logic              valid_7;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_1   <= 1'b0;
            valid_2   <= 1'b0;
            valid_3   <= 1'b0;
            valid_4   <= 1'b0;
            valid_5   <= 1'b0;
            flag_exp  <= 1'b0;
            valid_6   <= 1'b0;
            valid_out <= 1'b0;
        end else begin
                        
            dx <= $signed({1'b0,coord_X_i}) - $signed({1'b0,coord_X});
            dy <= $signed({1'b0,coord_Y_i}) - $signed({1'b0,coord_Y});
            i_1     <= cnt_i-1;
            j_1     <= j_idx_d;
            valid_1 <= j_valid_d;
            
            x_2     <= dx * dx;
            y_2     <= dy * dy;
            i_2     <= i_1;
            j_2     <= j_1;
            valid_2 <= valid_1;
            
            
            D2_ij   <= x_2 + y_2;
            i_3     <= i_2;
            j_3     <= j_2;
            valid_3 <= valid_2;

            arg_exp_brut <= $signed({1'b0,D2_ij}) * K_step_r;
            i_4          <= i_3;
            j_4          <= j_3;
            valid_4      <= valid_3;

            arg_exp_q6_10 <= $signed(arg_exp_brut) >>> 22;
            i_5            <= i_4;
            j_5            <= j_4;
            valid_5        <= valid_4;

            if (($signed(arg_exp_q6_10) >= -10240) && ($signed(arg_exp_q6_10) <= 0) && valid_5) begin
                arg_shifted <= arg_exp_q6_10[21:0] + 22'sd10240;
                flag_exp      <= 1'b0;
            end else begin
                arg_shifted <= '0;
                flag_exp <= 1'b1;
            end
            i_6           <= i_5;
            j_6           <= j_5;
            valid_6       <= valid_5;
            
            flag_exp_d <= flag_exp;
            i_7        <= i_6;
            j_7        <= j_6;
            valid_7    <= valid_6;


            // result_exp is now aligned with flag_exp_d / i_7 / j_7 / valid_7
            P_ij      <= flag_exp_d ? '0 : result_exp;
            out_i     <= i_7;
            out_j     <= j_7;
            valid_out <= valid_7;
            
        end
    end

    assign index_LUT_exp = arg_shifted[ADDR_LUT_EXP - 1:0];



// -------------------------------------------------------------------
// Compute pipeline producing sum_row_P for the CURRENT pass's row
// (cnt_i). Structurally identical to the P_ij pipeline above -- its
// per-coefficient output (P_ij_sum) is intentionally never exposed as a
// module output; only the accumulated sum_row_P (below) is consumed
// downstream. See docs/blocks/exp_block.md section 4 for the stage detail.
// -------------------------------------------------------------------
    logic signed [COORD_W:0]   dx_sum, dy_sum;
    logic [ADDR_W-1:0]         i_1_sum, j_1_sum;
    logic                      valid_1_sum;
 
    // Stage 1 -> 2: squares
    logic [2*COORD_W-1:0] x_2_sum, y_2_sum;
    logic [ADDR_W-1:0]      i_2_sum, j_2_sum;
    logic                   valid_2_sum;

    // Stage 2 -> 3: D2 = x2 + y2
    logic [2*COORD_W:0] D2_ij_sum;
    logic [ADDR_W-1:0]      i_3_sum, j_3_sum;
    logic                   valid_3_sum;

    // Stage 3 -> 4: arg_exp_brut = D2 * K_step (always <= 0)
    logic signed [D2_W + K_W - 1:0] arg_exp_brut_sum;
    logic [ADDR_W-1:0]      i_4_sum, j_4_sum;
    logic                   valid_4_sum;

    // Stage 4 -> 5: arg_exp_q6_10 = arg_exp_brut >>> 22 (align to the Q6.10
    // format expected by the LUT address, per the quantization chain in ADR-0001)
    logic [D2_W + K_W - 1:0] arg_exp_q6_10_sum;
    logic signed [21:0] arg_shifted_sum;
    logic [ADDR_W-1:0]      i_5_sum, j_5_sum;
    logic                   valid_5_sum;

    // Stage 5 -> 6: bias the argument into a valid LUT address, or flag it
    // as out of range (saturates P_ij to 0, mirrors the reference model's
    // exp_lut saturation behavior, see ADR-0004)
    logic                   flag_exp_sum;
    logic [ADDR_W-1:0]      i_6_sum, j_6_sum;
    logic                   valid_6_sum;

    // Stage 6 -> 7: the LUT answers one cycle after index_LUT_exp is driven;
    // delay flag_exp/i/j/valid by one more stage to stay aligned with result_exp.
    logic              flag_exp_d_sum;
    logic [ADDR_W-1:0] i_7_sum, j_7_sum;
    logic              valid_7_sum;

    logic              valid_out_sum;
    logic [P_IJ_W - 1:0] P_ij_sum;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_1_sum   <= 1'b0;
            valid_2_sum   <= 1'b0;
            valid_3_sum   <= 1'b0;
            valid_4_sum   <= 1'b0;
            valid_5_sum   <= 1'b0;
            flag_exp_sum  <= 1'b0;
            valid_6_sum   <= 1'b0;
            valid_out_sum <= 1'b0;
            out_i_sum     <= '0;
            out_j_sum     <= '0;
            P_ij_sum      <= '0;
        end else begin
                        
            dx_sum <= $signed({1'b0,coord_X_i_sum}) - $signed({1'b0,coord_X});
            dy_sum <= $signed({1'b0,coord_Y_i_sum}) - $signed({1'b0,coord_Y});
            i_1_sum     <= cnt_i;
            j_1_sum     <= j_idx_d;
            valid_1_sum <= j_valid_d_sum;
            
            x_2_sum     <= dx_sum * dx_sum;
            y_2_sum     <= dy_sum * dy_sum;
            i_2_sum     <= i_1_sum;
            j_2_sum     <= j_1_sum;
            valid_2_sum <= valid_1_sum;
            
            
            D2_ij_sum   <= x_2_sum + y_2_sum;
            i_3_sum     <= i_2_sum;
            j_3_sum     <= j_2_sum;
            valid_3_sum <= valid_2_sum;

            arg_exp_brut_sum <= $signed({1'b0,D2_ij_sum}) * K_step_r;
            i_4_sum          <= i_3_sum;
            j_4_sum          <= j_3_sum;
            valid_4_sum      <= valid_3_sum;

            arg_exp_q6_10_sum  <= $signed(arg_exp_brut_sum) >>> 22;
            i_5_sum            <= i_4_sum;
            j_5_sum            <= j_4_sum;
            valid_5_sum        <= valid_4_sum;

            if (($signed(arg_exp_q6_10_sum) >= -10240) && ($signed(arg_exp_q6_10_sum) <= 0) && valid_5_sum) begin
                arg_shifted_sum <= arg_exp_q6_10_sum[21:0] + 22'sd10240;
                flag_exp_sum      <= 1'b0;
            end else begin
                arg_shifted_sum <= '0;
                flag_exp_sum <= 1'b1;
            end
            i_6_sum           <= i_5_sum;
            j_6_sum           <= j_5_sum;
            valid_6_sum       <= valid_5_sum;
            
            flag_exp_d_sum <= flag_exp_sum;
            i_7_sum        <= i_6_sum;
            j_7_sum        <= j_6_sum;
            valid_7_sum    <= valid_6_sum;


            // result_exp is now aligned with flag_exp_d / i_7 / j_7 / valid_7
            P_ij_sum      <= flag_exp_d_sum ? '0 : result_exp_sum;
            out_i_sum     <= i_7_sum;
            out_j_sum     <= j_7_sum;
            valid_out_sum <= valid_7_sum;
            
        end
    end

    assign index_LUT_exp_sum = arg_shifted_sum[ADDR_LUT_EXP - 1:0];

    // -------------------------------------------------------------------
    // Row sum accumulation, latched out once per row (see docs/blocks/exp_block.md
    // section 5). Consumed by the grad block for normalization
    // (see docs/ARCHITECTURE.md, section 6).
    // -------------------------------------------------------------------
    logic [SUM_ROW_P_W-1:0] sum_row_P_reg;
    logic [SUM_ROW_P_W-1:0] sum_row_P_next;

    assign sum_row_P_next = sum_row_P_reg + P_ij_sum;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_row_P_reg   <= '0;
            valid_sum_row_P <= 1'b0;
            sum_row_P       <= '0;
        end else begin
            valid_sum_row_P <= 1'b0;
            if (valid_out_sum) begin
                if (out_j_sum == nb_points-1) begin
                    sum_row_P       <= sum_row_P_next; // Full row sum, including this last P_ij
                    valid_sum_row_P <= 1'b1;
                    sum_row_P_reg   <= '0;             // Reset for the next row
                end else begin
                    sum_row_P_reg <= sum_row_P_next;
                end
            end
        end
    end

endmodule