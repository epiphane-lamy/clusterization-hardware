//=============================================================================
// Module: clusterization (toplevel)
//
// Instantiates and wires together the full clustering pipeline described in
// docs/ARCHITECTURE.md: the exp/grad iterative loop (via the ping-pong
// arbiter and its two P_ij buffers), the upd (act_coord) block that closes
// out each iteration, and the final cluster_assign pass -- run NB_ITER
// times before handing off to cluster assignment.
//
// Beyond wiring, this module owns two pieces of toplevel-only control logic
// not covered in any individual block's documentation:
//   1. Iteration sequencing: chaining exp/grad -> upd -> (next iteration or
//      final cluster_assign) automatically once the design is started
//      (see the step_idx / start_b3 / start_b4 generation logic near the
//      end of this file).
//   2. Coordinate-memory ownership handoff: the two duplicated coordinate
//      memories (memory_coord_b1/b2, see ADR-0003) are shared over time by
//      several different requesters (external load, exp/grad's own reads,
//      the upd block's broadcast write, and -- for b1 only -- the final
//      cluster_assign pass). See the coord_owner_t / mux_coord_port
//      section below for how that sharing is arbitrated.
//
// See docs/blocks/*.md for the internals of each instantiated block.
//=============================================================================

module clusterization #(
    parameter int NB_POINTS    = 1250,              // Number of points. Fixed default for now, see docs/blocks/exp.md, known limitations.
    parameter int NB_ITER      = 50,                // Number of iterations
    parameter int COORD_W      = 16,                // Coordinate width
    parameter int ADDR_W       = $clog2(NB_POINTS), // Point address width
    parameter int P_IJ_W       = 16,                // P_ij width, signed fixed-point
    parameter int ADDR_P_IJ_W  = $clog2(NB_POINTS), // P_ij address width (same ADR-0007 note as ADDR_W above)
    parameter int ADDR_LUT_INV = 10,                // Inverse LUT address width
    parameter int ADDR_LUT_EXP = 14,                // exp LUT address width
    parameter int ACT_W        = 16,                // Update value width, signed fixed-point
    parameter int STEP_W       = 6,                 // Iteration counter width (max_iter=50 -> 6 bits is enough)
    parameter int K_W          = 16,                // Precomputed K_step constant width, signed, always negative
    parameter int SQ_W         = 2 * COORD_W,       // dx*dx / dy*dy: product of two signed COORD_W-bit values
    parameter int D2_W         = 2 * COORD_W,       // D2 = x2 + y2
    parameter int TOL          = 170459136          // Squared-distance tolerance for cluster_assign, precomputed in software
    )(
    input logic clk,
    input logic rst_n,
 
    input logic start, // Launches the clustering pipeline
 
    // --- Point BRAM load port (Xf / Yf) -- external write access for testbenches ---
    input logic control_mem_coord_load, // 1: give the coordinate memory port to the external loader below
 
    input logic               we_coord_load,
    input logic [ADDR_W-1:0]  addr_coord_load,
    input logic [COORD_W-1:0] data_in1_coord_load,
    input logic [COORD_W-1:0] data_in2_coord_load,
 
    // --- Cluster BRAM read port -- external readout access for testbenches ---
    input logic control_mem_cluster_read, // 1: give the cluster memory's address port to the external reader below
    input logic [ADDR_W-1:0] addr_cluster_read,
    output logic [ADDR_W-1:0] cluster_read,
 
    output logic done // Clustering fully complete (= cluster_assign's own done)
    );

    // One memory-access request: write enable, address, and the two data
    // words (a point's X/Y) that a given requester would like to issue to a
    // coordinate memory this cycle. Used to describe each candidate
    // requester uniformly so they can be muxed by mux_coord_port below.
    typedef struct packed {
        logic                  we;
        logic [ADDR_W-1:0]     addr;
        logic [COORD_W-1:0]    data_in1;
        logic [COORD_W-1:0]    data_in2;
    } coord_mem_port_t;

    // The four possible owners of a coordinate memory port at any given
    // time. Only one can drive the physical memory port per cycle -- see
    // the owner_b1 / owner_b2 priority muxes further down for exactly when
    // each applies.
    typedef enum logic [1:0] {
        OWNER_TB,             // External testbench load (control_mem_coord_load_bX asserted)
        OWNER_COMPUTE,        // exp (b1) / grad (b2) own read stream during an iteration
        OWNER_ACT,            // act_coord's broadcast update write, once an iteration's compute is done
        OWNER_CLUSTER_ASSIGN  // Final cluster_assign pass (b1 only -- see owner_b2 below)
    } coord_owner_t;

    // Reusable mux, shared by both coordinate memories (b1 and b2) to
    // avoid duplicating the same case statement twice.
    function automatic coord_mem_port_t mux_coord_port(
        input coord_owner_t     owner,
        input coord_mem_port_t  tb,
        input coord_mem_port_t  compute,
        input coord_mem_port_t  act,
        input coord_mem_port_t  cluster
    );
        unique case (owner)
            OWNER_TB:             mux_coord_port = tb;
            OWNER_COMPUTE:        mux_coord_port = compute;
            OWNER_ACT:            mux_coord_port = act;
            OWNER_CLUSTER_ASSIGN: mux_coord_port = cluster;
            default:              mux_coord_port = tb;
        endcase
    endfunction

    // -------------------------------------------------------------------
    // coord_b1 / coord_b2 memory port declarations
    // -------------------------------------------------------------------
    coord_owner_t     owner_b1;
    coord_mem_port_t  port_coord_b1_load, port_compute_b1, port_act_b1, port_cluster_b1, port_mux_b1;
    coord_owner_t     owner_b2;
    coord_mem_port_t  port_coord_b2_load, port_compute_b2, port_act_b2, port_cluster_b2, port_mux_b2;
    
    // -------------------------------------------------------------------
    // exp block and its dedicated coordinate memory / exp_LUT
    // -------------------------------------------------------------------
    logic              start_b1;         // Launches a full row sweep for exp (see step_idx generation further down)
    logic              start_compute_b1;
    logic [STEP_W-1:0] step_idx;         // Current iteration index

    // --- Point BRAM port (address advanced every cycle by exp) ---
    logic [ADDR_W-1:0]  addr_coord_b1;
    logic [ADDR_W-1:0]  addr_coord_compute_b1;

    logic [COORD_W-1:0] coord_X_b1;
    logic [COORD_W-1:0] coord_Y_b1;

    logic signed [ADDR_LUT_EXP-1:0] index_LUT_exp;
    logic signed [COORD_W-1:0]      result_exp;

	// --- exp block outputs ---
    logic [COORD_W-1:0] P_ij_b1;
    logic [ADDR_W-1:0]  out_i_b1;
    logic [ADDR_W-1:0]  out_j_b1;
    logic               valid_out_b1;

    logic        valid_sum_row_P;
    logic [31:0] sum_row_P;

    logic credit_avail;
    logic done_b1;

    // DUT exp block
    dist_mat_arg_exp #(
        .NB_POINTS       (NB_POINTS),
        .COORD_W         (COORD_W),
        .ADDR_W          (ADDR_W),
        .ADDR_P_IJ_W     (ADDR_P_IJ_W),
        .ADDR_LUT_EXP    (ADDR_LUT_EXP),
        .STEP_W          (STEP_W),
        .K_W             (K_W),
        .D2_W            (D2_W)
    ) exp_block (
        .clk             (clk),
        .rst_n           (rst_n),

        .start           (start_b1),
        .step_idx        (step_idx),

        .addr            (addr_coord_compute_b1),
        .coord_X         (coord_X_b1),
        .coord_Y         (coord_Y_b1),

        .index_LUT_exp   (index_LUT_exp),
        .result_exp      (result_exp),

        .P_ij            (P_ij_b1),
        .out_i           (out_i_b1),
        .out_j           (out_j_b1),
        .valid_out       (valid_out_b1),

        .sum_row_P       (sum_row_P),
        .valid_sum_row_P (valid_sum_row_P),

        .credit_avail    (credit_avail),
        .done            (done_b1)
    );

    // memory access
    logic               we_coord_b1;
    logic [COORD_W-1:0] data_in1_coord_b1;
    logic [COORD_W-1:0] data_in2_coord_b1;
    

    // DUT: exp-side coordinate memory (see ADR-0003, duplicated coordinate memories)
    memory_dual_port #(
        .ADDR_W (ADDR_W),
        .DATA_W (COORD_W)
    ) coord_memory_b1 (
        .clk       (clk),
        .rst_n     (rst_n),

        .we        (we_coord_b1),
        .addr      (addr_coord_b1),
        .data_in1  (data_in1_coord_b1),
        .data_in2  (data_in2_coord_b1),

        .data_out1 (coord_X_b1),
        .data_out2 (coord_Y_b1)
    );

    // DUT: exp_LUT
    exp_LUT exp_LUT (
        .clk        (clk),
        .rst_n      (rst_n),

        .index      (index_LUT_exp),
        .result_exp (result_exp)
    );


    // -------------------------------------------------------------------
    // grad block and its dedicated coordinate memory / inv_LUT
    // -------------------------------------------------------------------
    logic [ADDR_W-1:0]  addr_coord_b2;
    logic [COORD_W-1:0] coord_X_b2;
    logic [COORD_W-1:0] coord_Y_b2;

    logic [ADDR_W-1:0] addr_coord_compute_b2;

    // --- P_ij read port (via the ping-pong arbiter) ---
    logic [ADDR_P_IJ_W-1:0] addr_P_ij_b2;
    logic [P_IJ_W-1:0]      P_ij_b2;

    // --- Inverse LUT port: inv[index = mantissa] ---
    logic [ADDR_LUT_INV-1:0] index_LUT_inv;
    logic [COORD_W-1:0]      result_inv;

	// --- Output to the mult_upd memory ---
    logic signed [ACT_W-1:0] mult_act_X;
    logic signed [ACT_W-1:0] mult_act_Y;
    logic [ADDR_P_IJ_W-1:0]  addr_act;
    logic [ADDR_P_IJ_W-1:0]  addr_act_b2;
    logic                    valid_out_b2;
    
    logic [31:0] entropy;
    logic        valid_entropy;

    logic done_b2;

    // DUT: grad block. Note out_i(out_i_b1): the row-ready notification
    // (sum_row_P / out_i / valid_sum_row_P) documented in docs/blocks/exp_block.md
    // section 5 and docs/blocks/grad_block.md section 4 is realized here simply
    // by wiring exp's own out_i output directly into grad's out_i input.
    norm_entropy_grad #(
        .NB_POINTS       (NB_POINTS),
        .COORD_W         (COORD_W),
        .ADDR_W          (ADDR_W),

        .P_IJ_W          (P_IJ_W),
        .ADDR_P_IJ_W     (ADDR_P_IJ_W),
        .ADDR_LUT_INV    (ADDR_LUT_INV),
        .ACT_W           (ACT_W)
    ) grad_block (
        .clk             (clk),
        .rst_n           (rst_n),

        .addr            (addr_coord_compute_b2),
        .coord_X         (coord_X_b2),
        .coord_Y         (coord_Y_b2),
        
        .addr_P_ij       (addr_P_ij_b2),
        .P_ij            (P_ij_b2),

        .index_LUT_inv   (index_LUT_inv),
        .result_inv      (result_inv),

        .mult_act_X      (mult_act_X),
        .mult_act_Y      (mult_act_Y),
        .addr_act        (addr_act_b2),
        .valid_out       (valid_out_b2),

        .sum_row_P       (sum_row_P),
        .out_i           (out_i_b1),
        .valid_sum_row_P (valid_sum_row_P),

        .entropy         (entropy),
        .valid_entropy   (valid_entropy),

        .done            (done_b2)
    );

    logic               we_coord_b2;
    logic [COORD_W-1:0] data_in1_coord_b2;
    logic [COORD_W-1:0] data_in2_coord_b2;
    logic [COORD_W-1:0] data_in1_coord_tb_b2;
    logic [COORD_W-1:0] data_in2_coord_tb_b2;
    

    // DUT: grad-side coordinate memory (see ADR-0003, duplicated coordinate memories)
    memory_dual_port #(
        .ADDR_W    (ADDR_W),
        .DATA_W    (COORD_W)
    ) coord_memory_b2 (
        .clk       (clk),
        .rst_n     (rst_n),

        .we        (we_coord_b2),
        .addr      (addr_coord_b2),
        .data_in1  (data_in1_coord_b2),
        .data_in2  (data_in2_coord_b2),

        .data_out1 (coord_X_b2),
        .data_out2 (coord_Y_b2)
    );
    
    // DUT: inv_LUT
    inv_LUT inv_LUT (
        .clk        (clk),
        .rst_n      (rst_n),

        .index      (index_LUT_inv),
        .result_inv (result_inv)
    );


    // -------------------------------------------------------------------
    // ping_pong_arbiter and the two P_ij row buffers (see ADR-0003)
    // -------------------------------------------------------------------
 
    logic                   we_P_ij_A;
    logic [ADDR_P_IJ_W-1:0] addr_P_ij_A;
    logic [P_IJ_W-1:0]      data_in_P_ij_A;
    logic [P_IJ_W-1:0]      P_ij_A;

    // P_ij row buffer A
    memory_single_port #(
        .ADDR_W   (ADDR_P_IJ_W),
        .DATA_W   (P_IJ_W)
    ) P_ij_memory_A (
        .clk      (clk),
        .rst_n    (rst_n),

        .we       (we_P_ij_A),
        .addr     (addr_P_ij_A),
        .data_in  (data_in_P_ij_A),

        .data_out (P_ij_A)
    );


    logic                   we_P_ij_B;
    logic [ADDR_P_IJ_W-1:0] addr_P_ij_B;
    logic [P_IJ_W-1:0]      data_in_P_ij_B;
    logic [P_IJ_W-1:0]      P_ij_B;

    // P_ij row buffer B
    memory_single_port #(
        .ADDR_W   (ADDR_P_IJ_W),
        .DATA_W   (P_IJ_W)
    ) P_ij_memory_B (
        .clk      (clk),
        .rst_n    (rst_n),

        .we       (we_P_ij_B),
        .addr     (addr_P_ij_B),
        .data_in  (data_in_P_ij_B),

        .data_out (P_ij_B)
    );

    // ping_pong_arbiter: mediates exp's writes and grad's reads across
    // buffers A/B (see docs/blocks/ping_pong_arbiter.md).
    ping_pong_arbiter #(
        .ADDR_W         (ADDR_W),
        .P_IJ_W         (P_IJ_W),
        .ADDR_P_IJ_W    (ADDR_P_IJ_W)
    ) P_ij_memory_arbiter (
        .clk            (clk),
        .rst_n          (rst_n),

        .valid_p_ij_exp (valid_out_b1), // Per-element write strobe (= dist_mat_arg_exp's valid_out)
        .out_i_exp      (out_i_b1),     // Row index currently being written, used for buffer-select parity
        .line_done_grad (done_b2),      // Row fully consumed by grad -- releases a ping-pong credit

        // Write side (exp)
        .addr_P_ij_w    (out_j_b1),
        .P_ij_w         (P_ij_b1),

        // Read side (grad)
        .addr_P_ij_r    (addr_P_ij_b2),
        .P_ij_r         (P_ij_b2),

        // Buffer A port
        .addr_A         (addr_P_ij_A),
        .we_A           (we_P_ij_A),
        .w_data_A       (data_in_P_ij_A),
        .r_data_A       (P_ij_A),

        // Buffer B port
        .addr_B         (addr_P_ij_B),
        .we_B           (we_P_ij_B),
        .w_data_B       (data_in_P_ij_B),
        .r_data_B       (P_ij_B),

        .credit_avail   (credit_avail)
    );


 
    // -------------------------------------------------------------------
    // upd (act_coord) block and the mult_upd memory
    // -------------------------------------------------------------------
 
    logic start_b3; // Launches act_coord's full update pass over all points

    // --- Point coordinate port (broadcast write, see docs/blocks/act_coord.md) ---
    logic [ADDR_W-1:0]  addr_coord_b3;
	logic               we_coord_b3;
    logic [COORD_W-1:0] coord_X_act;
    logic [COORD_W-1:0] coord_Y_act;

    // --- Port BRAM mult_act (adresse incrementee chaque cycle) ---
    logic                    control_mem_b3; // 1 while act_coord owns both coordinate memories (see below)
    logic [ADDR_W-1:0]       addr_act_b3;
    logic signed [ACT_W-1:0] mult_act_X_mem;
    logic signed [ACT_W-1:0] mult_act_Y_mem;

    logic done_act;

    // DUT: act_coord. Reads the current coordinate from the b1 memory's
    // output (coord_X_b1/coord_Y_b1) -- shared with cluster_assign's own
    // read further down, since the two never run at the same time (see
    // owner_b1 below) -- and broadcasts its write to BOTH coordinate
    // memories via port_act_b1/port_act_b2.
    act_coord #(
        .NB_POINTS   (NB_POINTS),
        .COORD_W     (COORD_W),
        .ADDR_W      (ADDR_W),
        .ACT_W       (ACT_W)
    ) upd_block (
        .clk         (clk),
        .rst_n       (rst_n),

        .start       (start_b3),

        .addr_coord  (addr_coord_b3),
        .we_coord    (we_coord_b3),

        .coord_X     (coord_X_b1),
        .coord_Y     (coord_Y_b1),

        .coord_X_act (coord_X_act),
        .coord_Y_act (coord_Y_act),

        .addr_act    (addr_act_b3),
        .mult_act_X  (mult_act_X_mem),
        .mult_act_Y  (mult_act_Y_mem),

        .done        (done_act)
    );

    // mult_upd memory. Write side is driven directly by grad's own
    // valid_out_b2 (grad populates this memory during normal computation);
    // act_coord only ever reads it back afterwards, once grad's phase for
    // the iteration has fully finished -- see the addr_act mux below for
    // how the two blocks' accesses are time-multiplexed on this same port.
    memory_dual_port #(
        .ADDR_W    (ADDR_W),
        .DATA_W    (ACT_W)
    ) upd_memory (
        .clk       (clk),
        .rst_n     (rst_n),

        .we        (valid_out_b2),
        .addr      (addr_act),
        .data_in1  (mult_act_X),
        .data_in2  (mult_act_Y),

        .data_out1 (mult_act_X_mem),
        .data_out2 (mult_act_Y_mem)
    );
 
    // -------------------------------------------------------------------
    // cluster_assign block and the cluster memory
    // -------------------------------------------------------------------

    logic start_b4; // Launches cluster_assign, only once (see the all_steps_done logic below)

    // --- Point coordinate read port (final, converged coordinates) ---
    logic [ADDR_W-1:0]  addr_coord_compute_b4;
    logic [COORD_W-1:0] coord_X_b4;
    logic [COORD_W-1:0] coord_Y_b4;

    // --- Cluster memory port ---
    logic [ADDR_W-1:0] addr_cluster;
    logic [ADDR_W-1:0] addr_cluster_compute;
    logic              we_cluster;
    logic              valid_cluster;
    logic [ADDR_W-1:0] cluster_out;


    // DUT: cluster_assign
    cluster_assign #(
        .NB_POINTS     (NB_POINTS),
        .COORD_W       (COORD_W),
        .ADDR_W        (ADDR_W),
        .TOL           (TOL)
    ) cluster_assign (
        .clk           (clk),
        .rst_n         (rst_n),

        .start         (start_b4),

        .addr_coord    (addr_coord_compute_b4),
        .coord_X       (coord_X_b1),
        .coord_Y       (coord_Y_b1),

        .addr_cluster  (addr_cluster_compute),
        .we_cluster    (we_cluster),
        .valid_cluster (valid_cluster),
        .cluster_out   (cluster_out),

        .done          (done)
    );

    // memory cluster (see ADR-0006 for the valid_cluster / unassigned-point contract)
    memory_cluster #(
        .ADDR_W        (ADDR_W)
    ) memory_cluster (
        .clk           (clk),
        .rst_n         (rst_n),

        .we            (we_cluster),
        .addr          (addr_cluster),
        .data_in       (cluster_out),

        .valid_cluster (valid_cluster),
        .data_out      (cluster_read)
    );

    // -------------------------------------------------------------------
    // Iteration sequencing (1/3): launch act_coord once a full row sweep
    // is done. cnt_done_b2 counts how many rows grad has finished (done_b2
    // pulses once per row) within the CURRENT iteration; once all
    // NB_POINTS rows are done, the whole iteration's compute is complete,
    // and start_b3 pulses exactly once to launch act_coord's update pass.
    // -------------------------------------------------------------------
    logic [ADDR_W-1:0] cnt_done_b2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_b3    <= 1'b0;
            cnt_done_b2 <= '0;
        end else begin
            start_b3 <= 1'b0;
            if (done_b2) begin
                if (cnt_done_b2 == NB_POINTS - 1) begin
                    start_b3    <= 1'b1;
                    cnt_done_b2 <= '0;
                end else begin
                    start_b3    <= 1'b0;
                    cnt_done_b2 <= cnt_done_b2 + 1'b1;
                end
            end
        end
    end


    // If start_b3 fires, act_coord runs its update pass -> ownership of
    // both coordinate memories switches over to it (see owner_b1/owner_b2
    // below) so it can modify them, and it is also given read access to
    // the mult_act memory.
    //
    // Once it's done, its done_act signal is used to relaunch computation
    // for the next iteration via the start_b1 input, and at the same time
    // hands ownership of the b1/b2 memory ports back to exp and grad.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            control_mem_b3 <= 1'b0;
        end else begin
            if (start_b3) control_mem_b3 <= 1'b1;
            if (done_act) control_mem_b3 <= 1'b0;
        end
    end

    // While act_coord owns the memories (control_mem_b3), the mult_act
    // memory's address follows act_coord's own read address (addr_act_b3),
    // so it can read back the update it needs to apply for the current
    // point. Otherwise, the address follows grad's write address
    // (addr_act_b2), since grad is the one populating this memory during
    // normal computation. Note: the write-enable (we(valid_out_b2) on
    // memory_act above) stays wired to grad's own valid_out unconditionally,
    // relying on the fact that grad has already fully finished producing
    // updates for the iteration by the time control_mem_b3 goes high (see
    // the start_b3 generation above) -- valid_out_b2 is simply inactive
    // throughout act_coord's window, rather than being explicitly gated.

    assign addr_act = (control_mem_b3) ? addr_act_b3 : addr_act_b2;


    // -------------------------------------------------------------------
    // Iteration sequencing (2/3): chain iterations automatically. Once
    // act_coord finishes an iteration (done_act) and there are more
    // iterations left (step_idx != NB_ITER), advance step_idx and pulse
    // start_compute_b1 to launch exp/grad again for the next iteration.
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            step_idx <= '0;
            start_compute_b1 <= 1'b0;
        end else begin
            start_compute_b1 <= 1'b0;
            if (done_act && (step_idx != NB_ITER)) begin
                step_idx <= step_idx + 1'b1;
                start_compute_b1 <= 1'b1;
            end
        end
    end

    // start is only needed to kick off iteration 0; every subsequent
    // iteration is self-triggered via start_compute_b1 above.
    assign start_b1 = start || start_compute_b1;

    logic all_steps_done;
    // -------------------------------------------------------------------
    // Iteration sequencing (3/3): once the last iteration's act_coord pass
    // completes (step_idx == NB_ITER), launch cluster_assign exactly once.
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            all_steps_done <= 1'b0;
            start_b4       <= 1'b0;
        end else begin
            start_b4 <= 1'b0; // Default: single-cycle pulse
            if (done_act && (step_idx == NB_ITER) && !all_steps_done) begin
                all_steps_done <= 1'b1;
                start_b4       <= 1'b1; // Fires once, on the transition only
            end
        end
    end


    // -------------------------------------------------------------------
    // coord_b1 ownership: priority order matters here -- an external
    // testbench load always wins, then act_coord's update window, then
    // (once every iteration is done) cluster_assign's final read pass,
    // and exp's own compute reads by default otherwise.
    // -------------------------------------------------------------------
    always_comb begin
        if (!control_mem_coord_load) owner_b1 = OWNER_TB;
        else if (control_mem_b3)        owner_b1 = OWNER_ACT;
        else if (all_steps_done)        owner_b1 = OWNER_CLUSTER_ASSIGN;
        else                            owner_b1 = OWNER_COMPUTE;
    end

    assign port_coord_b1_load.we       = we_coord_load;
    assign port_coord_b1_load.addr     = addr_coord_load;
    assign port_coord_b1_load.data_in1 = data_in1_coord_load;
    assign port_coord_b1_load.data_in2 = data_in2_coord_load;

    assign port_compute_b1.we          = 1'b0; // exp block only reads
    assign port_compute_b1.addr        = addr_coord_compute_b1;
    assign port_compute_b1.data_in1    = '0;
    assign port_compute_b1.data_in2    = '0;

    assign port_act_b1.we              = we_coord_b3;
    assign port_act_b1.addr            = addr_coord_b3;
    assign port_act_b1.data_in1        = coord_X_act;
    assign port_act_b1.data_in2        = coord_Y_act;

    assign port_cluster_b1.we          = 1'b0;
    assign port_cluster_b1.addr        = addr_coord_compute_b4;
    assign port_cluster_b1.data_in1    = '0;
    assign port_cluster_b1.data_in2    = '0;

    assign port_mux_b1 = mux_coord_port(owner_b1, port_coord_b1_load, port_compute_b1, port_act_b1, port_cluster_b1);

    assign we_coord_b1                 = port_mux_b1.we;
    assign addr_coord_b1               = port_mux_b1.addr;
    assign data_in1_coord_b1           = port_mux_b1.data_in1;
    assign data_in2_coord_b1           = port_mux_b1.data_in2;


    // -------------------------------------------------------------------
    // coord_b2 ownership: same idea as b1, but simpler -- cluster_assign
    // never touches b2 (it only ever reads via b1, see the cluster_assign
    // instantiation above), so there is no OWNER_CLUSTER_ASSIGN branch here.
    // -------------------------------------------------------------------
    always_comb begin
        if (!control_mem_coord_load) owner_b2 = OWNER_TB;
        else if (control_mem_b3)        owner_b2 = OWNER_ACT;
        else                            owner_b2 = OWNER_COMPUTE;
    end


    assign port_coord_b2_load.we       = we_coord_load;
    assign port_coord_b2_load.addr     = addr_coord_load;
    assign port_coord_b2_load.data_in1 = data_in1_coord_load;
    assign port_coord_b2_load.data_in2 = data_in2_coord_load;

    assign port_compute_b2.we          = 1'b0; // grad block only reads
    assign port_compute_b2.addr        = addr_coord_compute_b2;
    assign port_compute_b2.data_in1    = '0;
    assign port_compute_b2.data_in2    = '0;

    assign port_act_b2.we              = we_coord_b3;
    assign port_act_b2.addr            = addr_coord_b3;
    assign port_act_b2.data_in1        = coord_X_act;
    assign port_act_b2.data_in2        = coord_Y_act;

    assign port_cluster_b2.we          = 1'b0;
    assign port_cluster_b2.addr        = '0;
    assign port_cluster_b2.data_in1    = '0;
    assign port_cluster_b2.data_in2    = '0;

    assign port_mux_b2 = mux_coord_port(owner_b2, port_coord_b2_load, port_compute_b2, port_act_b2, port_cluster_b2);

    assign we_coord_b2                 = port_mux_b2.we;
    assign addr_coord_b2               = port_mux_b2.addr;
    assign data_in1_coord_b2           = port_mux_b2.data_in1;
    assign data_in2_coord_b2           = port_mux_b2.data_in2;

 
    // Cluster memory address: external testbench readout vs. cluster_assign's
    // own internal address stream while it's actively running.
    assign addr_cluster = (control_mem_cluster_read) ? addr_cluster_compute : addr_cluster_read;


    // -------------------------------------------------------------------
    // Debug print block -- simulation only, ignored by synthesis. Traces
    // the pipeline's key intermediate results (row sums, entropy,
    // mult_act, coordinate updates) as they're produced.
    // -------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (valid_sum_row_P) begin
            $display("[%0t] RESULT sum_row_P i=%0d j=%0d sum_row_P=%0d",
                    $time,
                    out_i_b1,
                    out_j_b1,
                    sum_row_P);
        end
        
        if (start_b4) begin
            $display("\n=== start_b4 ===");
        end

        if (valid_entropy) begin
            $display("[%0t] RESULT entropy i=%0d j=%0d entropy=%0d",
                    $time,
                    out_i_b1,
                    out_j_b1,
                    entropy);
        end
        if (valid_out_b2) begin
            $display("[%0t] *****RESULT mult_act_X / mult_act_Y***** addr_act=%0d mult_act_X=%0d mult_act_Y=%0d",
                    $time,
                    addr_act,
                    mult_act_X,
                    mult_act_Y);
        end

        if (we_coord_b3) begin
            $display("[%0t] RESULT coord_act coord_X_act=%0d coord_Y_act=%0d",
                    $time,
                    coord_X_act,
                    coord_Y_act);
        end
    end


endmodule