//=============================================================================
// Testbench: step_tb
//
// Full-system testbench for one complete step, processed through the exp,
// grad and ping-pong arbiter blocks: loads a small subset of the full
// benchmark point set (produced by the fixed-point software reference model,
// see docs/ARCHITECTURE.md section 8), runs the reduced pipeline, and writes
// out the final coordinates after the first step for comparison against the
// software reference.
//
//=============================================================================

module step_tb #(
    parameter int NB_POINTS    = 100,         // Number of points
    parameter int COORD_W      = 16,          // Coordinate width
    parameter int ADDR_W       = 7,           // Point address width
    parameter int P_IJ_W       = 16,          // P_ij width, fixed-point
    parameter int ADDR_P_IJ_W  = 7,           // P_ij address width (same ADR-0007 note as ADDR_W above)
    parameter int ADDR_LUT_INV = 10,          // Inverse LUT address width
    parameter int ADDR_LUT_EXP = 14,          // exp LUT address width
    parameter int STEP_W       = 6,           // Iteration counter width (max_iter=50 -> 6 bits is enough)
    parameter int K_W          = 16,          // Precomputed K_step constant width, signed, always negative
    parameter int SQ_W         = 2 * COORD_W, // dx*dx / dy*dy: product of two signed COORD_W-bit values
    parameter int D2_W         = SQ_W + 1     // D2 = x2 + y2
	);

    logic       clk;
    logic       rst_n;


    // -------------------------------------------------------------------
    // exp block and its dedicated coordinate memory / exp_LUT
    // -------------------------------------------------------------------
    logic              start;     // Launches a full row sweep for exp (see step_idx generation further down)
    logic [STEP_W-1:0] step_idx;  // Current iteration index

    // --- Point BRAM port (address advanced every cycle by exp) ---
    logic [ADDR_W-1:0] addr_coord_b1;

    logic              control_mem_coord_b1;
    logic [ADDR_W-1:0] addr_coord_tb_b1;
    logic [ADDR_W-1:0] addr_coord_compute_b1;

    logic [COORD_W-1:0] coord_X_b1;
    logic [COORD_W-1:0] coord_Y_b1;

    logic signed [ADDR_LUT_EXP-1:0] index_LUT_exp;
    logic signed [COORD_W-1:0]      result_exp;

	// --- exp block outputs ---
    logic [COORD_W-1:0] P_ij_b1;
    logic [ADDR_W-1:0]  out_i_b1;
    logic [ADDR_W-1:0]  out_j_b1;
    logic               valid_out_b1;

    logic [31:0] sum_row_P;
    logic        valid_sum_row_P;

    logic credit_avail;
    logic done_b1;

    // DUT exp block
    dist_mat_arg_exp #(
        .NB_POINTS       (NB_POINTS),
        .COORD_W         (COORD_W),
        .ADDR_W          (ADDR_W),
        .ADDR_LUT_EXP    (ADDR_LUT_EXP),
        .STEP_W          (STEP_W),
        .K_W             (K_W)
    ) exp_block (
        .clk             (clk),
        .rst_n           (rst_n),

        .start           (start),
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
    logic [COORD_W-1:0] data_in1_b1;
    logic [COORD_W-1:0] data_in2_b1;
    

    // DUT: exp-side coordinate memory (see ADR-0003, duplicated coordinate memories)
    memory_dual_port #(
        .ADDR_W    (ADDR_W),
        .DATA_W    (COORD_W)
    ) memory_coord_b1 (
        .clk       (clk),
        .rst_n     (rst_n),

        .we        (we_coord_b1),
        .addr      (addr_coord_b1),
        .data_in1  (data_in1_b1),
        .data_in2  (data_in2_b1),

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

    logic              control_mem_coord_b2;
    logic [ADDR_W-1:0] addr_coord_tb_b2;
    logic [ADDR_W-1:0] addr_compute_coord_b2;

    // --- P_ij read port (via the ping-pong arbiter) ---
    logic [ADDR_P_IJ_W-1:0] addr_P_ij_b2;
    logic [P_IJ_W-1:0]      P_ij_b2;

    // --- Inverse LUT port: inv[index = mantissa] ---
    logic [ADDR_LUT_INV-1:0] index_LUT_inv;
    logic [COORD_W-1:0]      result_inv;

	// --- Output to the mult_upd memory ---
    logic signed [31:0]     mult_act_X;
    logic signed [31:0]     mult_act_Y;
    logic [ADDR_P_IJ_W-1:0] addr_act;
    logic                   valid_out_b2;
    
    logic [31:0] entropy;
    logic        valid_entropy;

    logic done_b2;

    // DUT grad block
    norm_entropy_grad #(
        .NB_POINTS       (NB_POINTS),
        .COORD_W         (COORD_W),
        .ADDR_W          (ADDR_W),

        .P_IJ_W          (P_IJ_W),
        .ADDR_P_IJ_W     (ADDR_P_IJ_W),
        .ADDR_LUT_INV    (ADDR_LUT_INV),
        
        .STEP_W          (STEP_W),
        .K_W             (K_W),
        .D2_W            (D2_W)
    ) grad_block (
        .clk             (clk),
        .rst_n           (rst_n),

        .addr            (addr_compute_coord_b2),
        .coord_X         (coord_X_b2),
        .coord_Y         (coord_Y_b2),
        
        .addr_P_ij       (addr_P_ij_b2),
        .P_ij            (P_ij_b2),

        .index_LUT_inv   (index_LUT_inv),
        .result_inv      (result_inv),

        .mult_act_X      (mult_act_X),
        .mult_act_Y      (mult_act_Y),
        .addr_act        (addr_act),
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
    

    // DUT: grad-side coordinate memory (see ADR-0003, duplicated coordinate memories)
    memory_dual_port #(
        .ADDR_W (ADDR_W),
        .DATA_W (COORD_W)
    ) memory_coord_b2 (
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
        .clk(clk),
        .rst_n(rst_n),

        .index(index_LUT_inv),
        .result_inv(result_inv)
    );


    // -------------------------------------------------------------------
    // ping_pong_arbiter and the two P_ij row buffers (see ADR-0003)
    // -------------------------------------------------------------------
    logic                   we_P_ij_A;
    logic [ADDR_P_IJ_W-1:0] addr_P_ij_A;
    logic [P_IJ_W-1:0]      data_in_P_ij_A;
    logic [P_IJ_W-1:0]      P_ij_A;

    // P_ij row buffer A
    memory_dual_port #(
        .ADDR_W    (ADDR_P_IJ_W),
        .DATA_W    (P_IJ_W)
    ) P_ij_memory_A (
        .clk       (clk),
        .rst_n     (rst_n),

        .we        (we_P_ij_A),
        .addr      (addr_P_ij_A),
        .data_in1  (data_in_P_ij_A),
        .data_in2  (),

        .data_out1 (P_ij_A),
        .data_out2 ()
    );


    logic                   we_P_ij_B;
    logic [ADDR_P_IJ_W-1:0] addr_P_ij_B;
    logic [P_IJ_W-1:0]      data_in_P_ij_B;
    logic [P_IJ_W-1:0]      P_ij_B;

    // P_ij row buffer B
    memory_dual_port #(
        .ADDR_W    (ADDR_P_IJ_W),
        .DATA_W    (P_IJ_W)
    ) P_ij_memory_B (
        .clk       (clk),
        .rst_n     (rst_n),

        .we        (we_P_ij_B),
        .addr      (addr_P_ij_B),
        .data_in1  (data_in_P_ij_B),
        .data_in2  (),

        .data_out1 (P_ij_B),
        .data_out2 ()
    );

    // ping_pong_arbitrer
    ping_pong_arbiter #(
        .ADDR_W         (ADDR_W),
        .P_IJ_W         (P_IJ_W),
        .ADDR_P_IJ_W    (ADDR_P_IJ_W)
    ) memory_P_ij_arbiter (
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



    // -------------------------------------------------------------------------
    // Testbench tasks
    // -------------------------------------------------------------------------

    // Task to write coordinate data to memory (exp copy)
    task write_memory_coord_b1(input logic [ADDR_W-1:0] addr_task, input logic [15:0] data_in1_task, input logic [15:0] data_in2_task);
        control_mem_coord_b1 = 0;
        we_coord_b1          = 1;
        addr_coord_tb_b1     = addr_task;
        data_in1_b1          = data_in1_task;
        data_in2_b1          = data_in2_task;

        @(posedge clk);

        we_coord_b1          = 0;
        control_mem_coord_b1 = 1;
    endtask

    // Task to write coordinate data to memory (grad copy)
    task write_memory_coord_b2(input logic [ADDR_W-1:0] addr_task, input logic [15:0] data_in1_task, input logic [15:0] data_in2_task);
        control_mem_coord_b2 = 0;
        we_coord_b2          = 1;
        addr_coord_tb_b2     = addr_task;
        data_in1_coord_b2    = data_in1_task;
        data_in2_coord_b2    = data_in2_task;

        @(posedge clk);

        we_coord_b2          = 0;
        control_mem_coord_b2 = 1;
    endtask

    // -------------------------------------------------------------------------
    // Memory control multiplexing
    // -------------------------------------------------------------------------
    always_comb begin
        addr_coord_b1 = (control_mem_coord_b1 == 1) ? addr_coord_compute_b1 : addr_coord_tb_b1;
        addr_coord_b2 = (control_mem_coord_b2 == 1) ? addr_compute_coord_b2 : addr_coord_tb_b2;
    end


    // Automatic task to monitor computation results
    logic [7:0] cnt_done_b2;
    task automatic monitor_results();
        int result_count = 0;

        forever begin
            @(posedge clk);

            if (valid_sum_row_P) begin
                $display("[%0t] RESULT sum_row_P i=%0d j=%0d sum_row_P=%0d",
                        $time,
                        out_i_b1,
                        out_j_b1,
                        sum_row_P);
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
            if (done_b2) begin
                cnt_done_b2++;
            end
        end
    endtask

    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Testbench stimulus
    // -------------------------------------------------------------------------
    integer fd;
    int ret;
    int xf, yf;
    int addr_file;
    initial begin

        $display("\n=== Simulation start ===");

        // ---------------------------------------------------------------------
        // Initialization
        // ---------------------------------------------------------------------
        clk                  =  0;
        rst_n                =  0;
        we_coord_b1          =  0;
        we_coord_b2          =  0;
        addr_coord_tb_b1     = '0;
        addr_coord_tb_b2     = '0;
        control_mem_coord_b1 =  0;
        control_mem_coord_b2 =  0;

        cnt_done_b2 = 0;

        start       =  0;
        step_idx    = '0;

        fork
            monitor_results();
        join_none

        // ---------------------------------------------------------------------
        // Reset
        // ---------------------------------------------------------------------
        @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        
        // ---------------------------------------------------------------------
        // Load point coordinates into both memory
        // ---------------------------------------------------------------------
        fd = $fopen("data/cluster_fixed.txt", "r");

        if (fd == 0) begin
            $fatal(1, "Error while opening cluster_fixed.txt");
        end

        addr_file = 0;

        while (addr_file < 100) begin

            ret = $fscanf(fd, "%d %d", xf, yf);

            if (ret != 2)
                break;

            write_memory_coord_b1(addr_file[ADDR_W-1:0], xf[15:0], yf[15:0]);
            write_memory_coord_b2(addr_file[ADDR_W-1:0], xf[15:0], yf[15:0]);


            addr_file++;
        end

        $fclose(fd);

        $display("%0d points loaded from cluster_fixed.txt", addr_file);

        // ---------------------------------------------------------------------
        // Start computation
        // ---------------------------------------------------------------------
        control_mem_coord_b1 = 1;
        control_mem_coord_b2 = 1;
        start = 1;
        @(posedge clk);
        start = 0;

        // Wait for computation to complete
        wait (cnt_done_b2 == 3);

        #10;
        $display("\n=== Simulation completed ===");
        $finish;
    end



endmodule
