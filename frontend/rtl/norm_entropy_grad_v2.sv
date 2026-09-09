//=============================================================================
// Module: norm_entropy_grad_v2  ("grad block")
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


module norm_entropy_grad_v2 #(
    parameter int NB_POINTS    = 8,   // Number of points. Fixed default for now, see docs/blocks/exp.md, known limitations.
    parameter int COORD_W      = 16,  // Coordinate width, signed fixed-point
    parameter int ADDR_W       = 7,   // Point address width (used for cnt_i / cnt_j / addr)
    parameter int P_IJ_W       = 16,  // P_ij width fixed-point
    parameter int ADDR_P_IJ_W  = 7,   // P_ij address width
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
 
    // --- P_ij ---
    input  logic              valid_P_ij,
    input  logic [P_IJ_W-1:0] P_ij,
 
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
    input logic [ADDR_W-1:0]      out_i_sum,       // Row index this sum applies to (and so the next P_ij applies to)
    input logic                   valid_sum_row_P, // Strobe: launches this row's processing
 
    output logic [ENTH_W-1:0] entropy,
    output logic              valid_entropy,
 
    output logic done
);
 
    logic [ADDR_W-1:0] cnt_i;
    logic [ADDR_W-1:0] cnt_j;

    // -------------------------------------------------------------------
    // j counter management
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_j <= '0;
        end else begin
            if (valid_P_ij) begin
                if (cnt_j == NB_POINTS-1) begin
                    cnt_j <= '0;
                end else begin
                    cnt_j <= cnt_j + 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------
    // Shift-register tags: independent of the current FSM state, derived
    // from which address was issued the previous cycle.
    // -------------------------------------------------------------------
    logic              j_valid_d;     // 1: the BRAM response this cycle is a valid j-fetch
    logic              j_valid_d_2;   // 1: the BRAM response this cycle is a valid j-fetch
    logic [ADDR_W-1:0] j_idx_d;       // j index matching the response on the bus

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            j_valid_d   <= 1'b0;
            j_valid_d_2 <= 1'b0;
            j_idx_d     <= '0;
        end else begin
            j_valid_d   <= valid_P_ij;
            j_valid_d_2 <= j_valid_d;
            j_idx_d     <= cnt_j;
        end
    end

    logic [P_IJ_W-1:0] P_ij_reg;
    always_ff @(posedge clk) begin
        P_ij_reg  <= P_ij;
    end


    // -------------------------------------------------------------------
    // Capture out_i / sum_row_P_i / coord_X_i / coord_Y_i
    // -------------------------------------------------------------------
    logic               valid_coord_i_1, valid_coord_i_2;
    logic [COORD_W-1:0] coord_X_i, coord_Y_i;
    logic [COORD_W-1:0] coord_X_i_next, coord_Y_i_next;

    logic [SUM_ROW_P_W-1:0] sum_row_P_i;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_coord_i_1 <= 1'b0;
            valid_coord_i_2 <= 1'b0;
        end else begin
            valid_coord_i_1 <= 1'b0;
            if (valid_sum_row_P) begin
                sum_row_P_i     <= sum_row_P;
                cnt_i           <= out_i_sum-1; // Capture index row of the next P_ij line
                valid_coord_i_1 <= 1'b1;
                
                $display("[%0t] ================= cnt_i=%0d",
                        $time,
                        cnt_i);
                /*
                if (cnt_i == 1) begin
                    $finish;
                end*/
            end

            valid_coord_i_2 <= valid_coord_i_1;

            if (valid_coord_i_2) begin
                coord_X_i_next <= coord_X;
                coord_Y_i_next <= coord_Y;
                coord_X_i      <= coord_X_i_next;
                coord_Y_i      <= coord_Y_i_next;
            end
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
        msb      <= msb_comb;
        mantissa <= sum_row_P_i << (31 - msb_comb);
        
        sum_row_P_inv <= result_inv;
    end

    assign index_LUT_inv = mantissa[SUM_ROW_P_W-1:SUM_ROW_P_W-10];


    // -------------------------------------------------------------------
    // Point / P_ij / update address generation
    // -------------------------------------------------------------------
    logic [ADDR_W-1:0]  out_i;
    assign addr = valid_coord_i_1 ? cnt_i : cnt_j;
    assign addr_act = out_i;
 


    // -------------------------------------------------------------------
    // Compute pipeline. See docs/blocks/grad_block.md section 6 for the full
    // stage-by-stage description.
    // -------------------------------------------------------------------
 
    // Stage 0 -> 1: normalize P_ij into P_ij_norm; capture coord_X/coord_Y in lockstep
    logic [COORD_W - 1:0] P_ij_norm;
    logic [COORD_W-1:0]   coord_X_d, coord_Y_d;
    logic [ADDR_W-1:0]    i_1;
    logic [ADDR_W-1:0]    j_1;
    logic                 valid_1;
 
    // Stage 1 -> 2: P_ij_norm * coord
    logic [ACT_W-1:0]       mult_X;
    logic [ACT_W-1:0]       mult_Y;
    logic [ADDR_W-1:0]    i_2;
    logic [ADDR_W-1:0] j_2;
    logic              valid_2;
 
    // Stage 2 -> 3: P_dot accumulation
    logic [63:0]       P_dot_X;
    logic [63:0]       P_dot_Y;
    logic [ADDR_W-1:0]    i_3;
    logic [ADDR_W-1:0] j_3;
    logic              valid_grad;
 
    // Stage 3 -> 4: grad_X and grad_Y
    logic signed [15:0]       grad_X;
    logic signed [15:0]       grad_Y;
    logic [ADDR_W-1:0]    i_4;
    logic [ADDR_W-1:0] j_4;
    logic              valid_mult_act;
 
    // Force applied at stage 4 (forca * grad), updated per-row by the
    // entropy accumulator further below.
    logic [15:0]        forca;
    logic signed [16:0] forca_s;
    logic [ADDR_W-1:0]  out_j;
 
 
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
            P_ij_norm <= (P_ij_reg * sum_row_P_inv) >> msb;
            coord_X_d <= coord_X;
            coord_Y_d <= coord_Y;
            i_1       <= cnt_i;
            j_1       <= j_idx_d;
            valid_1   <= j_valid_d_2;

            // Stage 1: P_ij_norm * coord
            mult_X  <= P_ij_norm * coord_X_d;
            mult_Y  <= P_ij_norm * coord_Y_d;
            i_2       <= i_1;
            j_2     <= j_1;
            valid_2 <= valid_1;
/*
            if (j_valid_d_2) begin
            $display("[%0t] =================||||||| sum_row_P_inv=%0d",
                    $time,
                    sum_row_P_inv);
            end
            
            if (j_1 == 10) begin
                $finish;
            end*/
            
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
            i_3       <= i_2;
            j_3        <= j_2;

            // Stage 3: grad_X and grad_Y (only on the row's last column)
            if (valid_grad && (j_3 == NB_POINTS-1)) begin
                grad_X         <= $signed(P_dot_X[15:0]) - $signed({1'b0,coord_X_i});
                grad_Y         <= $signed(P_dot_Y[15:0]) - $signed({1'b0,coord_Y_i});
                i_4       <= i_3;
                j_4            <= j_3;
                valid_mult_act <= valid_grad;
            end else begin
                valid_mult_act <= 1'b0;
            end

            // Stage 4: forca * grad (only on the row's last column)
            if (valid_mult_act) begin
                mult_act_X <= (grad_X * forca_s) >>> 16;
                mult_act_Y <= (grad_Y * forca_s) >>> 16;
                out_i       <= i_4;
                out_j      <= j_4;
                valid_out  <= valid_mult_act;
            end else begin
                valid_out <= 1'b0;
            end
        end
    end

    assign done = valid_out && (out_j == NB_POINTS-1);

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