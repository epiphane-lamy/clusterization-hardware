//=============================================================================
// Testbench: norm_entropy_grad_tb
//
// Testbench for the grad block: loads a small subset of the full benchmark
// point set and a row of the P_ij matrix in memory (produced by the fixed-point
// software reference model, see docs/ARCHITECTURE.md section 8), runs the
// grad block to perform its computations on the row of the P_ij matrix for
// comparison against the software reference.
//
//=============================================================================

module norm_entropy_grad_tb #(
    parameter int NB_POINTS    = 100,        // Number of points, Currently a fixed default
    parameter int COORD_W      = 16,         // Coordinate width, fixed-point
    parameter int ADDR_W       = 7,          // Point BRAM address width
    parameter int P_IJ_W       = 16,         // P_ij width fixed-point
    parameter int ADDR_P_IJ_W  = 7,          // P_ij address width
    parameter int ADDR_LUT_INV = 10          // inv LUT address width
	);

    logic       clk;
    logic       rst_n;

    // --- Point coordinate BRAM port ---
    logic [ADDR_W-1:0]  addr_coord;
    logic [COORD_W-1:0] coord_X;
    logic [COORD_W-1:0] coord_Y;

    logic              control_mem_coord;
    logic [ADDR_W-1:0] addr_tb_coord;
    logic [ADDR_W-1:0] addr_compute_coord;


    // --- BRAM P_ij port ---
    logic [ADDR_P_IJ_W-1:0] addr_P_ij;
    logic [P_IJ_W-1:0]      P_ij;

    logic                   control_mem_P_ij;
    logic [ADDR_P_IJ_W-1:0] addr_tb_P_ij;
    logic [ADDR_P_IJ_W-1:0] addr_compute_P_ij;

    // --- inv LUT port: inv_lut[index = mantissa] ---
    logic [ADDR_LUT_INV-1:0] index_LUT_inv;
    logic [COORD_W-1:0]      result_inv;

    // --- Output to the upd memory ---
    logic [31:0]            mult_act_X;
    logic [31:0]            mult_act_Y;
    logic [ADDR_P_IJ_W-1:0] addr_act;
    logic                   valid_out;

    logic [31:0]       sum_row_P;
    logic [ADDR_W-1:0] out_i;
    logic              valid_sum_row_P;
    
    logic [31:0] entropy;
    logic        valid_entropy;

    logic done;

    // DUT instantiation
    norm_entropy_grad #(
        .NB_POINTS       (NB_POINTS),
        .COORD_W         (COORD_W),
        .ADDR_W          (ADDR_W),

        .P_IJ_W          (P_IJ_W),
        .ADDR_P_IJ_W     (ADDR_P_IJ_W),
        .ADDR_LUT_INV    (ADDR_LUT_INV)
    ) grad_block (
        .clk             (clk),
        .rst_n           (rst_n),

        .addr            (addr_compute_coord),
        .coord_X         (coord_X),
        .coord_Y         (coord_Y),
        
        .addr_P_ij       (addr_compute_P_ij),
        .P_ij            (P_ij),

        .index_LUT_inv   (index_LUT_inv),
        .result_inv      (result_inv),

        .mult_act_X      (mult_act_X),
        .mult_act_Y      (mult_act_Y),
        .addr_act        (addr_act),
        .valid_out       (valid_out),

        .sum_row_P       (sum_row_P),
        .out_i           (out_i),
        .valid_sum_row_P (valid_sum_row_P),

        .entropy         (entropy),
        .valid_entropy   (valid_entropy),

        .done            (done)
    );

    // memory access
    logic               we_coord;
    logic [COORD_W-1:0] data_in1_coord;
    logic [COORD_W-1:0] data_in2_coord;
    

    // Coordinate memory
    memory_dual_port #(
        .ADDR_W    (ADDR_W),
        .DATA_W    (COORD_W)
    ) coord_memory (
        .clk       (clk),
        .rst_n     (rst_n),

        .we        (we_coord),
        .addr      (addr_coord),
        .data_in1  (data_in1_coord),
        .data_in2  (data_in2_coord),

        .data_out1 (coord_X),
        .data_out2 (coord_Y)
    );
    

    // memory access P_ij
    logic              we_P_ij;
    logic [P_IJ_W-1:0] data_in_P_ij;

    // P_ij memory 
    memory_dual_port #(
        .ADDR_W    (ADDR_P_IJ_W),
        .DATA_W    (P_IJ_W)
    ) P_ij_memory (
        .clk       (clk),
        .rst_n     (rst_n),

        .we        (we_P_ij),
        .addr      (addr_P_ij),
        .data_in1  (data_in_P_ij),
        .data_in2  (),

        .data_out1 (P_ij),
        .data_out2 ()
    );

    // inv_LUT
    inv_LUT inv_LUT (
        .clk        (clk),
        .rst_n      (rst_n),

        .index      (index_LUT_inv),
        .result_inv (result_inv)
    );

    // -------------------------------------------------------------------------
    // Testbench tasks
    // -------------------------------------------------------------------------

    // Display state task
    task display_state(input string label);
    $display("[%0t] %-22s | coord_X=%08b coord_Y=%08b addr_coord=%08b",
        $time, label, coord_X, coord_Y, addr_coord);
    endtask

    // Task to write coordinate data to memory
    task write_memory_coord(input logic [ADDR_W-1:0] addr_task, input logic [15:0] data_in1_task, input logic [15:0] data_in2_task);
        control_mem_coord = 0;
        we_coord          = 1;
        addr_tb_coord     = addr_task;
        data_in1_coord    = data_in1_task;
        data_in2_coord    = data_in2_task;

        @(posedge clk);

        we_coord          = 0;
        control_mem_coord = 1;
    endtask

    // Task to write P_ij data to memory
    task write_memory_P_ij(input logic [ADDR_P_IJ_W-1:0] addr_task, input logic [15:0] data_in1_task, input logic [15:0] data_in2_task);
        control_mem_P_ij = 0;
        we_P_ij          = 1;
        addr_tb_P_ij     = addr_task;
        data_in_P_ij     = data_in1_task;

        @(posedge clk);

        we_P_ij          = 0;
        control_mem_P_ij = 1;
    endtask

    // Task to read coordinate data from memory
    task read_memory_coord(input logic [ADDR_W-1:0] addr_task);
        control_mem_coord = 0;
        addr_tb_coord = addr_task;
        @(posedge clk);
        $display("READ memory addr_coord=%08b coord_X=%08b coord_Y=%08b", addr_coord, coord_X, coord_Y);
        control_mem_coord = 1;
    endtask

    // Task to read P_ij data from memory
    task read_memory_P_ij(input logic [ADDR_P_IJ_W-1:0] addr_task);
        control_mem_P_ij = 0;
        addr_tb_P_ij = addr_task;
        @(posedge clk);
        $display("READ memory addr_P_ij=%08b P_ij=%08b", addr_P_ij, P_ij);
        control_mem_P_ij = 1;
    endtask

    // Automatic task to monitor computation results
    task automatic monitor_results();
        int result_count = 0;

        forever begin
            @(posedge clk);

            if (valid_out) begin
                result_count++;
                
                /*
                $display("[%0t] RESULT #%0d i=%0d j=%0d P_ij=%0d",
                        $time,
                        result_count,
                        out_i,
                        out_j,
                        P_ij);
                */
                $display("[%0t] RESULT i=%0d mult_act_X=%0d mult_act_Y=%0d",
                        $time,
                        out_i,
                        mult_act_X,
                        mult_act_Y);
            end
            if (valid_entropy) begin
                $display("[%0t] RESULT entropy i=%0d entropy=%0d",
                        $time,
                        out_i,
                        entropy);
            end
            
            if (done) begin
                $display("[%0t] Simulation finished", $time);
                break;
            end
        end
    endtask

    always #5 clk = ~clk;


    // -------------------------------------------------------------------------
    // Memory control multiplexing
    // -------------------------------------------------------------------------
    always_comb begin
        addr_coord = (control_mem_coord == 1) ? addr_compute_coord : addr_tb_coord;
        addr_P_ij  = (control_mem_P_ij == 1)  ? addr_compute_P_ij  : addr_tb_P_ij;
    end


    // -------------------------------------------------------------------------
    // Testbench stimulus
    // -------------------------------------------------------------------------
    integer fd_coord;
    integer fd_P_ij;
    int ret;
    int xf, yf;
    int Pij;
    int addr_file;
    initial begin


        $display("\n=== Simulation start ===");

        // ---------------------------------------------------------------------
        // Initialization
        // ---------------------------------------------------------------------
        clk               =  0;
        rst_n             =  0;
        we_coord          =  0;
        addr_tb_coord     = '0;
        control_mem_coord =  0;
        we_P_ij           =  0;
        addr_tb_P_ij      = '0;
        control_mem_P_ij  =  0;
        out_i             =  0;
        valid_sum_row_P   =  0;

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
        // Load point coordinates into memory
        // ---------------------------------------------------------------------
        fd_coord = $fopen("data/cluster_fixed.txt", "r");

        if (fd_coord == 0) begin
            $fatal(1, "Error while opening cluster_fixed.txt");
        end

        addr_file = 0;

        while (addr_file < 100) begin

            ret = $fscanf(fd_coord, "%d %d", xf, yf);

            if (ret != 2)
                break;

            write_memory_coord(addr_file[ADDR_W-1:0], xf[15:0], yf[15:0]);

            addr_file++;
        end

        $fclose(fd_coord);

        $display("%0d points loaded from cluster_fixed.txt", addr_file);
        
        // ---------------------------------------------------------------------
        // Load one row of the P_ij matrix into memory
        // ---------------------------------------------------------------------
        fd_P_ij = $fopen("data/P_ij_fixed.txt", "r");

        if (fd_P_ij == 0) begin
            $fatal(1, "Error while opening P_ij_fixed.txt");
        end

        addr_file = 0;

        while (addr_file < 100) begin

            ret = $fscanf(fd_P_ij, "%d", Pij);

            if (ret != 1)
                break;

            write_memory_P_ij(addr_file[ADDR_P_IJ_W-1:0], Pij[15:0], '0);

            addr_file++;
        end

        $fclose(fd_P_ij);

        $display("%0d points loaded from P_ij_fixed.txt", addr_file);


        // ---------------------------------------------------------------------
        // Start computation
        // ---------------------------------------------------------------------
        control_mem_coord = 1;
        control_mem_P_ij  = 1;

        out_i             =  1;
        sum_row_P         = 32'd1555704;
        valid_sum_row_P   = 1;

        @(posedge clk);

        valid_sum_row_P = 0;
        // Wait for computation to complete
        wait(done);

        #10;
        $display("\n=== Simulation completed ===");
        $finish;
    end

endmodule