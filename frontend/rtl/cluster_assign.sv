//=============================================================================
// Module: cluster_assign
//
// Final pass of the pipeline (see docs/ARCHITECTURE.md, "Partie 2"): scans
// the converged point coordinates and assigns a cluster number to each
// point, grouping points that ended up within a fixed distance tolerance
// (TOL) of each other. Directly implements the reference model's final
// grouping pass, with the -1 "unassigned" sentinel replaced by an explicit
// valid bit (see ADR-0006).
//
// For each unassigned reference point i (found by scanning in order,
// skipping points that are already labelled), this block labels i with a
// new cluster number, then checks every unassigned candidate j > i against
// i using the same dx/dy -> squares -> distance pipeline pattern as
// dist_mat_arg_exp (see docs/blocks/exp_block.md), merging j into i's cluster
// whenever the squared distance is within TOL.
//
// See docs/blocks/cluster_assign.md for the full block-level documentation.
//=============================================================================


module cluster_assign #(
    parameter int NB_POINTS    = 8,        // Number of points.
    parameter int COORD_W      = 16,       // Coordinate width, fixed-point
    parameter int ADDR_W       = 7,        // Point / cluster address width
    parameter int TOL          = 422144877 // Squared-distance tolerance, precomputed in software
	)(
	input  logic             clk,
	input  logic             rst_n,
 
    input logic              start, // Launches the clustering pass

    // --- Final point coordinate BRAM port ---
    output logic [ADDR_W-1:0]  addr_coord,
    input  logic [COORD_W-1:0] coord_X,
    input  logic [COORD_W-1:0] coord_Y,

    // --- Cluster memory port ---
    output logic [ADDR_W-1:0] addr_cluster,
    output logic              we_cluster,
    input  logic              valid_cluster, // 0 = not yet assigned, 1 = already assigned (see ADR-0006)
    output logic [ADDR_W-1:0] cluster_out,

    output logic done
);

    // -------------------------------------------------------------------
    // Sequencing FSM
    // -------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE,           // Idle, waiting for start
        S_FETCH_I,        // Issue addr_coord = addr_cluster = cnt_i
        S_FETCH_WAIT,     // Issue addr = cnt_j (=0); capture coord_X_i / coord_Y_i
        S_WRITE_I,        // Write cluster[i]
        S_FETCH_J,        // Issue addr = cnt_j (read only)
        S_CHOICE_COMPUTE, // Read back valid_cluster for j (valid thanks to the previous cycle), then decide
        S_COMPUTE,        // Distance pipeline in flight
        S_WRITE,          // writing cluster[j]
        S_DRAIN,          // Let the pipeline flush
        S_DONE            // Clustering pass complete
    } state_t;
 
    state_t current_state, next_state;
 
    logic [ADDR_W-1:0] cnt_i;
    logic [ADDR_W-1:0] num_cluster;
    logic [ADDR_W-1:0] cluster_out_i;
    logic [ADDR_W-1:0] cnt_j;
    
    logic issue_i;       // 1 when addr carries a valid i-fetch this cycle
    logic issue_j;       // 1 when addr carries a valid j-fetch this cycle

    assign issue_i = (current_state == S_FETCH_I) || (current_state == S_FETCH_WAIT) || (current_state == S_WRITE_I);
    assign issue_j = (current_state == S_FETCH_J) || (current_state == S_CHOICE_COMPUTE) || (current_state == S_WRITE);
 
    // -------------------------------------------------------------------
    // BRAM address mux
    // -------------------------------------------------------------------
    assign addr_coord   = issue_i ? cnt_i : cnt_j;
    assign addr_cluster = issue_i ? cnt_i : cnt_j;
 
    // -------------------------------------------------------------------
    // i / j counter management for coord / cluster addressing
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_i       <= '0;
            num_cluster <= '0;
            cnt_j       <= '0;
        end else begin
            case (current_state)
                S_IDLE: begin
                    cnt_i       <= '0;
                    num_cluster <= '0;
                end

                S_FETCH_I: begin
                    cnt_j <= cnt_i + 1'b1;
                end

                S_FETCH_WAIT: begin
                    if ((cnt_i != NB_POINTS-1) && (valid_cluster == 1'b1))
                            cnt_i <= cnt_i + 1'b1; // i already assigned: skip to the next i
                end

                S_WRITE_I: begin
                    if (cnt_i == NB_POINTS-1)
                        num_cluster <= num_cluster + 1'b1;
                end

                S_CHOICE_COMPUTE: begin
                    if (valid_cluster == 1'b1) begin // j already labelled -> skip (no distance check)
                        if (cnt_j != NB_POINTS-1)
                            cnt_j <= cnt_j + 1'b1;
                        else begin
                            cnt_i       <= cnt_i + 1'b1;
                            num_cluster <= num_cluster + 1'b1;
                        end
                    end
                    // If j is unassigned: move to S_COMPUTE; S_WRITE handles cnt_j / cnt_i advancement afterwards.
                end

                S_WRITE: begin
                    if (cnt_j != NB_POINTS - 1) begin
                        cnt_j <= cnt_j + 1'b1;
                    end else begin
                        cnt_i       <= cnt_i       + 1'b1;
                        num_cluster <= num_cluster + 1'b1;
                    end
                end
 
                default: begin
                    // cnt_i / cnt_j held
                end
            endcase
        end
    end

    assign cluster_out_i = num_cluster;

    // Pipeline drain counter
    localparam int PIPE_DEPTH = 2; // nb d'etages du pipeline
    logic [$clog2(PIPE_DEPTH+1)-1:0] drain_cnt;
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) drain_cnt <= '0;
        else if (current_state == S_DRAIN) drain_cnt <= drain_cnt + 1'b1;
        else drain_cnt <= '0;
    end
 
 
    // -------------------------------------------------------------------
    // FSM: transition logic
    // -------------------------------------------------------------------
    logic valid_out;

    always_comb begin
        next_state = current_state;
        unique case (current_state)
            S_IDLE           : next_state = start ? S_FETCH_I : S_IDLE;
            S_FETCH_I        : next_state = S_FETCH_WAIT;
            S_FETCH_WAIT     : next_state = (valid_cluster == 1'b0) ? S_WRITE_I : (cnt_i == NB_POINTS-1) ? S_DRAIN : S_FETCH_I; // valid_cluster here refers to point i
            S_WRITE_I        : next_state = (cnt_i == NB_POINTS-1) ? S_DRAIN : S_FETCH_J;
            S_FETCH_J        : next_state = S_CHOICE_COMPUTE;
            S_CHOICE_COMPUTE : next_state = (valid_cluster == 1'b0) ? S_COMPUTE : (cnt_j == NB_POINTS-1) ? S_FETCH_I : S_FETCH_J;// valid_cluster here refers to point j
            S_COMPUTE        : next_state = (valid_out) ? S_WRITE : S_COMPUTE;
            S_WRITE          : next_state = (cnt_j != NB_POINTS - 1) ? S_FETCH_J : S_FETCH_I;
            S_DRAIN          : next_state = (drain_cnt == PIPE_DEPTH - 1) ? S_DONE : S_DRAIN;
            S_DONE           : next_state = S_IDLE;
            default          : next_state = S_IDLE;
        endcase
    end
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= S_IDLE;
        end else begin
            current_state <= next_state;
        end
    end

 
    assign done = (current_state == S_DONE);
 

    // -------------------------------------------------------------------
    // Shift-register tags: independent of the current FSM state, derived
    // from which address was issued the previous cycle.
    // -------------------------------------------------------------------
    logic  j_compute_start;
    assign j_compute_start = (current_state == S_CHOICE_COMPUTE) && (valid_cluster == 1'b0);


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
            j_valid_d   <= j_compute_start;
            j_idx_d     <= cnt_j;
            i_idx_d <= cnt_i;
        end
    end

    // -------------------------------------------------------------------
    // Latch coord_X_i / coord_Y_i (independent of the pipeline's own advancement)
    // -------------------------------------------------------------------
    logic [COORD_W-1:0] coord_X_i, coord_Y_i;

    always_ff @(posedge clk) begin
        if (i_capture_d) begin
            coord_X_i <= coord_X;
            coord_Y_i <= coord_Y;
        end
    end



    // -------------------------------------------------------------------
    // Distance pipeline (3 stages). Same dx/dy -> squares -> sum pattern as
    // dist_mat_arg_exp (see docs/blocks/exp_block.md section 4).
    // -------------------------------------------------------------------
    logic signed [COORD_W:0] dx, dy;
    logic [ADDR_W-1:0]       i_1, j_1;
    logic                    valid_1;
 
    // Etage 1 -> 2 : squares
    logic [2*COORD_W-1:0] x_2, y_2;
    logic [ADDR_W-1:0]    i_2, j_2;
    logic                 valid_2;

    // Stage 2 -> 3: dist_sq = x2 + y2
    logic [2*COORD_W:0] dist_sq;
    logic [ADDR_W-1:0]  i_3, j_3;
    logic               valid_3;

    logic [ADDR_W-1:0]  out_i, out_j;
    logic [ADDR_W-1:0] cluster_out_j;


    // Unassigned points are now identified by their valid bit rather than a
    // -1 sentinel (see ADR-0006), so there is no need to ever write a
    // placeholder value for an unassigned cluster field -- only actual
    // assignments are written.
    logic hit_j;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_1   <= 1'b0;
            valid_2   <= 1'b0;
            valid_3   <= 1'b0;
            valid_out <= 1'b0;
            hit_j     <= 1'b0;
        end else begin
                        
            // Stage 0 -> output: delta = coord_i - coord_j
            dx <= $signed({1'b0,coord_X_i}) - $signed({1'b0,coord_X});
            dy <= $signed({1'b0,coord_Y_i}) - $signed({1'b0,coord_Y});
            i_1     <= cnt_i;
            j_1     <= j_idx_d;
            valid_1 <= j_valid_d;
            
            // Stage 1 -> output: squares
            x_2     <= dx * dx;
            y_2     <= dy * dy;
            i_2     <= i_1;
            j_2     <= j_1;
            valid_2 <= valid_1;
            
            // Stage 2 -> output: squared distance
            dist_sq    <= x_2 + y_2;
            i_3     <= i_2;
            j_3     <= j_2;
            valid_3 <= valid_2;
        
            // Stage 3 -> output: threshold comparison
            hit_j         <= (dist_sq <= TOL);
            cluster_out_j <= num_cluster;
            out_i         <= i_3;
            out_j         <= j_3;
            valid_out     <= valid_3;
            
        end
    end

 
    // NOTE: driven directly from the pipeline result (valid_out/hit_j), not
    // gated by current_state == S_WRITE -- see docs/blocks/cluster_assign.md
    // section 4 for the resulting write-timing subtlety.
    assign we_cluster = (valid_out && hit_j) || (current_state == S_WRITE_I);

    assign cluster_out = (current_state == S_WRITE_I) ? cluster_out_i : cluster_out_j;


endmodule

