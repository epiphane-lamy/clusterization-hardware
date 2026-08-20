//=============================================================================
// Module: norm_entropy_grad  ("grad block")
//
// Consumes one row of P_ij (produced by the exp block, buffered through the
// ping-pong arbiter) per sweep: normalizes each coefficient, accumulates the
// weighted sum of neighbour coordinates (P_dot), derives the Ricci gradient
// for the row's reference point, and applies the entropy-modulated update
// force to produce mult_act_X/Y for the upd block. The Gini entropy of the
// row (ADR-0005) is computed here too, as a byproduct of the same
// normalized P_ij stream, and directly drives the "surgery" force
// modulation (forca) applied to the same row's update.
//
// Row start is triggered by the exp block's sum_row_P / valid_sum_row_P /
// out_i outputs (see docs/blocks/exp_block.md section 5), not through the
// ping-pong arbiter -- the arbiter only mediates access to the P_ij data
// itself (see docs/blocks/ping_pong_arbiter.md). A one-slot pending latch
// (see the start_pulse logic below) makes sure a row-ready notification is
// never lost if it arrives while this block is still finishing the
// previous row.
//
// done (asserted once per row) feeds back into ping_pong_arbiter as
// line_done_grad, releasing a ping-pong credit for the exp block
// (see ADR-0003).
//
// Related design decisions: ADR-0001 (fixed-point quantization chain),
// ADR-0002 (row streaming), ADR-0003 (ping-pong buffering), ADR-0004
// (LUT-based inverse instead of CORDIC), ADR-0005 (Gini entropy instead
// of Shannon).
//
// See docs/blocks/grad_block.md for the full block-level documentation.
//=============================================================================


module norm_entropy_grad #(
    parameter int NB_POINTS    = 8,   // Number of points. Fixed default for now, see docs/blocks/exp.md, known limitations.
    parameter int COORD_W      = 16,  // Coordinate width, signed fixed-point
    parameter int ADDR_W       = 7,   // Point address width (used for cnt_i / cnt_j / addr)
    parameter int P_IJ_W       = 16,  // P_ij width, signed fixed-point
    parameter int ADDR_P_IJ_W  = 7,   // P_ij / update address width
    parameter int SUM_ROW_P_W  = 32,  // sum_row_P width
    parameter int ACT_W        = 32,  // Update value width (mult_act_X/Y), signed fixed-point
 
    parameter int ENTH_W       = 32,  // Entropy value width, signed fixed-point
 
    parameter int ADDR_LUT_INV = 10  // Inverse LUT address width
    )(
    input  logic             clk,
    input  logic             rst_n,
 
    // --- Grad-side point coordinate BRAM port ---
    output logic [ADDR_W-1:0]  addr,
    input  logic [COORD_W-1:0] coord_X,
    input  logic [COORD_W-1:0] coord_Y,
 
    // --- P_ij read port (via the ping-pong arbiter) ---
    output logic [ADDR_P_IJ_W-1:0] addr_P_ij,
    input  logic [P_IJ_W-1:0]      P_ij,
 
    // --- Inverse LUT port: inv[index = mantissa] ---
    output logic [ADDR_LUT_INV-1:0] index_LUT_inv,
    input  logic [COORD_W-1:0]      result_inv,
 
    // --- Output to the mult_upd memory ---
    output logic signed [ACT_W-1:0] mult_act_X,
    output logic signed [ACT_W-1:0] mult_act_Y,
    output logic [ADDR_P_IJ_W-1:0]  addr_act,
    output logic                    valid_out,
 
    // --- Row-ready notification from the exp block ---
    input logic [SUM_ROW_P_W-1:0] sum_row_P,
    input logic [ADDR_W-1:0]      out_i,           // Row index this sum applies to
    input logic                   valid_sum_row_P, // Strobe: launches this row's processing
 
    output logic [ENTH_W-1:0] entropy,
    output logic              valid_entropy,
 
    output logic done
);



    // -------------------------------------------------------------------
    // Sequencing FSM
    // -------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE,        // Idle, waiting for start_pulse
        S_COMPUTE_INV, // Compute the inv[sum_row_P] LUT address
        S_INV_WAIT,    // Wait one cycle to match the inverse LUT's read latency
        S_FETCH_I,     // Issue addr = cnt_i (reference point of the row)
        S_FETCH_WAIT,  // Issue addr = cnt_j (=0); capture coord_X_i / coord_Y_i
        S_RUN,         // Stream the row
        S_DRAIN,       // Let the compute pipeline flush the last row's in-flight data
        S_DONE         // Row complete
    } state_t;
 
    state_t current_state, next_state;
 
 
    logic [ADDR_W-1:0] cnt_i;
    logic [ADDR_W-1:0] cnt_j;
    
    logic issue_i;       // 1 when addr carries a valid i-fetch this cycle
    logic issue_j;       // 1 when addr carries a valid j-fetch this cycle
 
    assign issue_i = (current_state == S_FETCH_I);
    assign issue_j = (current_state == S_RUN);

 
    // -------------------------------------------------------------------
    // Point / P_ij / update address generation
    // -------------------------------------------------------------------
    assign addr = issue_i ? cnt_i : cnt_j;
    assign addr_P_ij = cnt_j;
    assign addr_act = cnt_i;
 
 
    // -------------------------------------------------------------------
    // j counter management
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_j <= '0;
        end else begin
            case (current_state)
                S_IDLE: begin
                    cnt_j <= '0;
                end
 
                S_RUN: begin
                    if (cnt_j != NB_POINTS - 1)
                        cnt_j <= cnt_j + 1'b1;
                end
 
                default: begin
                    // cnt_j held
                end
            endcase
        end
    end

    // Pipeline drain counter
    localparam int PIPE_DEPTH = 85; // Number of pipeline stages, see docs/blocks/grad_block.md section 6
    logic [$clog2(PIPE_DEPTH+1)-1:0] drain_cnt;
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) drain_cnt <= '0;
        else if (current_state == S_DRAIN) drain_cnt <= drain_cnt + 1'b1;
        else drain_cnt <= '0;
    end


    // mult_act and entropy finish at different pipeline depths, so both
    // "last value seen" flags are needed to know when the row is truly done.
    logic last_mult_act_seen;
    logic last_entropy_seen;
    logic [ADDR_W-1:0]  out_j;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_mult_act_seen <= 1'b0;
            last_entropy_seen  <= 1'b0;
        end else begin
            if (current_state == S_FETCH_I) begin
                // Reset for each new row
                last_mult_act_seen <= 1'b0;
                last_entropy_seen  <= 1'b0;
            end else begin
                if (valid_out && (out_j == NB_POINTS-1))
                    last_mult_act_seen <= 1'b1;
                if (valid_entropy)
                    last_entropy_seen <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------
    // Deferred capture of sum_row_P / out_i if this block is busy when the
    // notification arrives (see docs/blocks/grad_block.md section 4).
    // -------------------------------------------------------------------
    logic                   pending;
    logic [SUM_ROW_P_W-1:0] sum_row_P_latched;
    logic [ADDR_W-1:0]      out_i_latched;
    logic                   start_pulse;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= 1'b0;
        end else begin
            if (valid_sum_row_P && (current_state != S_IDLE)) begin
                // Busy: remember the pulse for later
                pending           <= 1'b1;
                sum_row_P_latched <= sum_row_P;
                out_i_latched     <= out_i;
            end else if (start_pulse) begin
                pending <= 1'b0; // Consumed
            end
        end
    end

    // Clean start pulse: either the notification arrives while already
    // idle, or a previously queued notification is being caught up on.
    assign start_pulse = (current_state == S_IDLE) && (valid_sum_row_P || pending);
 
    // -------------------------------------------------------------------
    // FSM: transition logic
    // -------------------------------------------------------------------
    always_comb begin
        next_state = current_state;
        unique case (current_state)
            S_IDLE : next_state = start_pulse ? S_COMPUTE_INV : S_IDLE;
            S_COMPUTE_INV : next_state = S_INV_WAIT;
            S_INV_WAIT    : next_state = S_FETCH_I;
            S_FETCH_I     : next_state = S_FETCH_WAIT;
            S_FETCH_WAIT  : next_state = S_RUN;
            S_RUN         : next_state = (cnt_j == NB_POINTS - 1) ? S_DRAIN : S_RUN;
            S_DRAIN : next_state = (last_mult_act_seen && last_entropy_seen) ? S_DONE : S_DRAIN;
            S_DONE        : next_state = S_IDLE;
            default       : next_state = S_IDLE;
        endcase
    end
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) current_state <= S_IDLE;
        else        current_state <= next_state;
    end
 
    assign done = (current_state == S_DONE);

 

    // -------------------------------------------------------------------
    // Shift-register tags: independent of the current FSM state, derived
    // from which address was issued the previous cycle.
    // -------------------------------------------------------------------
    logic              i_capture_d;   // 1: the BRAM response this cycle is the i-fetch
    logic              j_valid_d;     // 1: the BRAM response this cycle is a valid j-fetch
    logic [ADDR_W-1:0] j_idx_d;       // j index matching the response on the bus

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_capture_d <= 1'b0;
            j_valid_d   <= 1'b0;
            j_idx_d     <= '0;
        end else begin
            i_capture_d <= issue_i;
            j_valid_d   <= issue_j;
            j_idx_d     <= cnt_j;
        end
    end



    // -------------------------------------------------------------------
    // Capture out_i / sum_row_P_i / coord_X_i / coord_Y_i
    // -------------------------------------------------------------------
    logic [COORD_W-1:0] coord_X_i, coord_Y_i;
    logic [SUM_ROW_P_W-1:0] sum_row_P_i;

    always_ff @(posedge clk) begin
        if (start_pulse) begin
            sum_row_P_i <= pending ? sum_row_P_latched : sum_row_P;
            cnt_i       <= pending ? (out_i_latched) : (out_i - 1);
        end
        if (i_capture_d) begin
            coord_X_i <= coord_X;
            coord_Y_i <= coord_Y;
        end
    end


    // -------------------------------------------------------------------
    // inv[sum_row_P] address computation (mantissa-based, see ADR-0004)
    // -------------------------------------------------------------------
    logic [$clog2(SUM_ROW_P_W)-1:0] msb_comb;
    logic [$clog2(SUM_ROW_P_W)-1:0] msb;
    logic [SUM_ROW_P_W-1:0]         mantissa;
    logic [SUM_ROW_P_W-1:0]         sum_row_P_inv;

    always_comb begin
        msb_comb = '0;
        for (int i = (SUM_ROW_P_W-1); i >= 0; i--)
            if (sum_row_P_i[i]) begin
                msb_comb = i[$clog2(SUM_ROW_P_W)-1:0];
                break;
            end
    end

    always_ff @(posedge clk) begin
        if (current_state == S_COMPUTE_INV) begin
            msb      <= msb_comb;
            mantissa <= sum_row_P_i << (31 - msb_comb);
        end
        
        if (current_state == S_FETCH_I) begin
            sum_row_P_inv <= result_inv;
        end
    end

    assign index_LUT_inv = mantissa[SUM_ROW_P_W-1:SUM_ROW_P_W-10];


    // -------------------------------------------------------------------
    // Compute pipeline. See docs/blocks/grad_block.md section 6 for the full
    // stage-by-stage description.
    // -------------------------------------------------------------------
 
    // Stage 0 -> 1: normalize P_ij into P_ij_norm; capture coord_X/coord_Y in lockstep
    logic [COORD_W - 1:0] P_ij_norm;
    logic [COORD_W-1:0]   coord_X_d, coord_Y_d;
    logic [ADDR_W-1:0]    j_1;
    logic                 valid_1;
 
    // Stage 1 -> 2: P_ij_norm * coord
    logic [ACT_W-1:0]       mult_X;
    logic [ACT_W-1:0]       mult_Y;
    logic [ADDR_W-1:0] j_2;
    logic              valid_2;
 
    // Stage 2 -> 3: P_dot accumulation
    logic [63:0]       P_dot_X;
    logic [63:0]       P_dot_Y;
    logic [ADDR_W-1:0] j_3;
    logic              valid_grad;
 
    // Stage 3 -> 4: grad_X and grad_Y
    logic signed [15:0]       grad_X;
    logic signed [15:0]       grad_Y;
    logic [ADDR_W-1:0] j_4;
    logic              valid_mult_act;
 
    // Force applied at stage 4 (forca * grad), updated per-row by the
    // entropy accumulator further below.
    logic [15:0]        forca;
    logic signed [16:0] forca_s;
 
 
    logic [63:0] P_dot_X_reg;
    logic [63:0] P_dot_Y_reg;
    logic [63:0] P_dot_X_next;
    logic [63:0] P_dot_Y_next;
 
    assign P_dot_X_next = P_dot_X_reg + mult_X;
    assign P_dot_Y_next = P_dot_Y_reg + mult_Y;
    
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            P_dot_X     <= '0;
            P_dot_Y     <= '0;
            P_dot_X_reg <= '0;
            P_dot_Y_reg <= '0;

            valid_1     <= 1'b0;
            valid_2     <= 1'b0;
            valid_grad  <= 1'b0;
            valid_mult_act <= 1'b0;
            valid_out      <= 1'b0;
        end else begin
            
            // Stage 0: normalize P_ij
            P_ij_norm <= (P_ij * sum_row_P_inv) >> msb;
            coord_X_d <= coord_X;
            coord_Y_d <= coord_Y;
            j_1       <= j_idx_d;
            valid_1   <= j_valid_d;

            // Stage 1: P_ij_norm * coord
            mult_X  <= P_ij_norm * coord_X_d;
            mult_Y  <= P_ij_norm * coord_Y_d;
            j_2     <= j_1;
            valid_2 <= valid_1;

            
            // Stage 2: P_dot accumulation
            if (valid_2) begin
                if (j_2 == NB_POINTS-1) begin
                    P_dot_X <= P_dot_X_next >> 16; // Final logical shift
                    P_dot_Y <= P_dot_Y_next >> 16;

                    valid_grad  <= 1'b1;

                    P_dot_X_reg <= '0;
                    P_dot_Y_reg <= '0;
                end else begin
                    P_dot_X_reg <= P_dot_X_next;
                    P_dot_Y_reg <= P_dot_Y_next;
                    valid_grad  <= 1'b1;
                end
            end else begin
                valid_grad <= 1'b0;
            end
            j_3        <= j_2;

            // Stage 3: grad_X and grad_Y (only on the row's last column)
            if (valid_grad && (j_3 == NB_POINTS-1)) begin
                grad_X         <= $signed(P_dot_X[15:0]) - $signed({1'b0,coord_X_i});
                grad_Y         <= $signed(P_dot_Y[15:0]) - $signed({1'b0,coord_Y_i});
                j_4            <= j_3;
                valid_mult_act <= valid_grad;
            end else begin
                valid_mult_act <= 1'b0;
            end

            // Stage 4: forca * grad (only on the row's last column)
            if (valid_mult_act) begin
                mult_act_X <= (grad_X * forca_s) >>> 16;
                mult_act_Y <= (grad_Y * forca_s) >>> 16;
                out_j      <= j_4;
                valid_out  <= valid_mult_act;
            end else begin
                valid_out <= 1'b0;
            end
        end
    end

    assign forca_s = {1'b0, forca};


    // -------------------------------------------------------------------
    // Gini entropy accumulator (ADR-0005). Taps P_ij_norm directly at
    // stage 0, independently of the mult_X/P_dot/grad chain above -- this
    // is what lets entropy (and forca, below) be ready before mult_act_X/Y
    // is computed for the same row, with no extra synchronization needed.
    // -------------------------------------------------------------------
    logic [ENTH_W-1:0] entropy_reg;
    logic [ENTH_W-1:0] entropy_next;
    logic [ENTH_W-1:0] p_squared;

    assign p_squared    = P_ij_norm * P_ij_norm;
    assign entropy_next = entropy_reg + (p_squared >> 16);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            entropy_reg  <= '0;
            entropy       <= 32'h0000FFFF;
            valid_entropy <= 1'b0;
        end else begin
            valid_entropy <= 1'b0;
            if (valid_1) begin
                if (j_1 == NB_POINTS-1) begin
                    entropy       <= 32'd65536 - entropy_next; // Final subtraction, once per row
                    valid_entropy <= 1'b1;
                    entropy_reg  <= '0;
                end else begin
                    entropy_reg <= entropy_next;
                end
            end
        end
    end


    // -------------------------------------------------------------------
    // Perelman-surgery force modulation: matches the reference model's
    // forca_float / limiar_cirurgico_fixed constants (0.35, 0.002, 65200).
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            forca  <= 16'd22938;
        end else begin
            if (valid_entropy) begin
                if (entropy > 16'd65200) begin
                forca  <= 16'd131;
                end else begin
                    forca  <= 16'd22938;
                end
            end
        end
    end

endmodule