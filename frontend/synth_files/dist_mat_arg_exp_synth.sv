//=============================================================================
// Module: dist_mat_arg_exp  ("exp block")
//
// This module is the synthesizable version of the dist_mat_arg_exp module.
// It includes, in particular, a synthesizable ROM, unlike the dist_mat_arg_exp
// module used for RTL simulation, whose ROM contents are preloaded using the
// readmemh directive.
//
// Streams one row of the unnormalized Gaussian-kernel similarity matrix P
// per sweep. For a fixed reference point i, computes the squared distance to
// every other point j, scales it by the precomputed K_step factor, and looks
// up the resulting argument in a LUT to produce P_ij = exp(arg_ij). The row
// is never buffered in full on this side: P_ij is produced and forwarded
// downstream (through the ping-pong arbiter, see ADR-0003) one coefficient
// per cycle, together with a running row sum used later for normalization
// by the grad block (see docs/ARCHITECTURE.md, section 6).
//
// Both the reference point i and its neighbours j are read from the same
// single read-port coordinate BRAM, with address multiplexing between the
// "fetch i" and "stream j" phases (see the FSM below).
//
// Flow control: once a full row has been produced, the block waits for
// credit_avail before starting the next row -- this is how the ping-pong
// arbiter signals that the destination buffer is free to write into
// (see ADR-0003).
//
// Related design decisions:
//   ADR-0001 - fixed-point quantization chain
//   ADR-0002 - row-streaming instead of storing the full P matrix
//   ADR-0003 - ping-pong buffering / credit-based flow control
//   ADR-0004 - LUT-based exp() instead of CORDIC
//
// See docs/blocks/exp_block.md for the full block-level documentation.
//=============================================================================

module dist_mat_arg_exp #(
    parameter int NB_POINTS    = 8,          // Number of points, Currently a fixed default
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
 
    input logic              start,     // Launches a full sweep (all rows) for the current step
    input logic [STEP_W-1:0] step_idx,  // Current iteration index, selects K_step from the ROM

    // --- Point coordinate BRAM port (shared for both i and j accesses) ---
    output logic [ADDR_W-1:0]  addr,
    input  logic [COORD_W-1:0] coord_X,
    input  logic [COORD_W-1:0] coord_Y,

    // --- exp LUT port: exp_lut[index = arg + 10240] ---
    output logic [ADDR_LUT_EXP-1:0] index_LUT_exp,
    input  logic [COORD_W-1:0]      result_exp,

	// --- Output to the ping-pong arbiter / grad block ---
    output logic [P_IJ_W - 1:0]    P_ij,       // exp(arg_ij), saturated to 0 if arg out of LUT range
    output logic [ADDR_P_IJ_W-1:0] out_i,
    output logic [ADDR_P_IJ_W-1:0] out_j,
    output logic                   valid_out,

    output logic [SUM_ROW_P_W-1:0] sum_row_P,
    output logic                   valid_sum_row_P,

    input logic  credit_avail, // From the ping-pong arbiter: destination buffer is free for the next row
    output logic done
);
    // -------------------------------------------------------------------
    // K_step ROM: K_step = -1 / (2*T^2), precomputed in software per step
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

    assign issue_i = (current_state == S_FETCH_I);
    assign issue_j = (current_state == S_FETCH_WAIT) || (current_state == S_RUN);

 
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
                    if (cnt_j != NB_POINTS - 1)
                        cnt_j <= cnt_j + 1'b1;
                    // else: last address of the row already issued, hold cnt_j
                end

                S_LAST_WAIT: begin
                    // credit_avail gates the row increment: cnt_i must not advance
                    // until the ping-pong arbiter confirms the destination buffer
                    // is free (see ADR-0003).
                    if ((cnt_i != NB_POINTS - 1) && credit_avail)
                    
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
            S_RUN        : next_state = (cnt_j == NB_POINTS - 1) ? S_LAST_WAIT : S_RUN;
            S_LAST_WAIT  : next_state = (cnt_i == NB_POINTS - 1) ? S_DRAIN : (credit_avail == 1) ? S_FETCH_I : S_LAST_WAIT;
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
    logic              j_valid_d;     // 1: the BRAM response this cycle is a valid j-fetch
    logic [ADDR_W-1:0] j_idx_d;       // j index matching the response on the bus
    logic [ADDR_W-1:0] i_idx_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_capture_d <= 1'b0;
            j_valid_d   <= 1'b0;
            j_idx_d     <= '0;
            i_idx_d     <= '0;
        end else begin
            i_capture_d <= issue_i;
            j_valid_d   <= issue_j;
            j_idx_d     <= cnt_j;
            i_idx_d <= cnt_i;
        end
    end

    // -------------------------------------------------------------------
    // Latch coord_X_i / coord_Y_i once per row (reference point coordinates),
    // held stable while j streams across the row.
    // -------------------------------------------------------------------
    logic [COORD_W-1:0] coord_X_i, coord_Y_i;

    always_ff @(posedge clk) begin
        if (i_capture_d) begin
            coord_X_i <= coord_X;
            coord_Y_i <= coord_Y;
        end
    end


    // -------------------------------------------------------------------
    // Compute pipeline (8 stages, one register stage per cycle).
    // See docs/blocks/exp.md section 4 for the full stage-by-stage description.
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
            i_1     <= cnt_i;
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
    // Row sum accumulation, latched out once per row (see docs/blocks/exp_block.md
    // section 5). Consumed by the grad block for normalization
    // (see docs/ARCHITECTURE.md, section 6).
    // -------------------------------------------------------------------
    logic [SUM_ROW_P_W-1:0] sum_row_P_reg;
    logic [SUM_ROW_P_W-1:0] sum_row_P_next;

    assign sum_row_P_next = sum_row_P_reg + P_ij;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_row_P_reg   <= '0;
            valid_sum_row_P <= 1'b0;
            sum_row_P       <= '0;
        end else begin
            valid_sum_row_P <= 1'b0;
            if (valid_out) begin
                if (out_j == NB_POINTS-1) begin
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

