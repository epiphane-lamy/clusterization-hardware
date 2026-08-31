//=============================================================================
// Testbench: dist_mat_arg_exp_tb
//
// Testbench for the exp block: loads a small subset of the full benchmark
// point set (produced by the fixed-point software reference model, see
// docs/ARCHITECTURE.md section 8), runs the exp block to produce a row of
// the P_ij matrix for comparison against the software reference.
//
//=============================================================================

module dist_mat_arg_exp_tb #(
    parameter int NB_POINTS = 100,         // Number of points, Currently a fixed default
    parameter int COORD_W   = 16,          // Coordinate width, fixed-point
    parameter int ADDR_W    = 7,           // Point BRAM address width
    parameter int ADDR_LUT_EXP = 14,       // exp LUT address width
    parameter int STEP_W    = 6,           // Iteration counter width (max_iter=50 -> 6 bits is enough)
    parameter int K_W       = 16,          // Precomputed K_step constant width, signed, always negative
    parameter int D2_W      = 2 * COORD_W  // dx*dx / dy*dy: product of two COORD_W-bit value
	);

    logic       clk;
    logic       rst_n;

    logic              start;     // Launches a full sweep (all rows) for the current step
    logic [STEP_W-1:0] step_idx;  // Current iteration index, selects K_step from the ROM

    // --- Point coordinate BRAM port (shared for both i and j accesses) ---
    logic [ADDR_W-1:0] addr;

    logic              control_mem;
    logic [ADDR_W-1:0] addr_tb;
    logic [ADDR_W-1:0] addr_compute;

    logic [COORD_W-1:0] coord_X;
    logic [COORD_W-1:0] coord_Y;

    // --- exp LUT port: exp_lut[index = arg + 10240] ---
    logic signed [ADDR_LUT_EXP-1:0] index_LUT_exp;
    logic signed [COORD_W-1:0]      result_exp;

	// --- Output to the ping-pong arbiter / grad block ---
    logic [COORD_W-1:0] P_ij;   // D2_ij * K_step
    logic [ADDR_W-1:0]  out_i;
    logic [ADDR_W-1:0]  out_j;
    logic               valid_out;

    logic [31:0] sum_row_P;
    logic        valid_sum_row_P;
    

    logic credit_avail; // From the ping-pong arbiter: destination buffer is free for the next row
    logic done;

    // DUT instantiation
    dist_mat_arg_exp #(
        .NB_POINTS    (NB_POINTS),
        .COORD_W      (COORD_W),
        .ADDR_W       (ADDR_W),
        .ADDR_LUT_EXP (ADDR_LUT_EXP),
        .STEP_W       (STEP_W),
        .K_W          (K_W)
    ) dut_compute (
        .clk  (clk),
        .rst_n(rst_n),

        .start   (start),
        .step_idx(step_idx),

        .addr   (addr_compute),
        .coord_X(coord_X),
        .coord_Y(coord_Y),

        .index_LUT_exp(index_LUT_exp),
        .result_exp   (result_exp),

        .P_ij     (P_ij),
        .out_i    (out_i),
        .out_j    (out_j),
        .valid_out(valid_out),

        .sum_row_P      (sum_row_P),
        .valid_sum_row_P(valid_sum_row_P),


        .credit_avail(credit_avail),
        .done        (done)
    );

    // memory access
    logic               we;
    logic [COORD_W-1:0] data_in1;
    logic [COORD_W-1:0] data_in2;
    

    // Coordinate memory
    memory_dual_port #(
        .ADDR_W (ADDR_W),
        .DATA_W (COORD_W)
    ) memory (
        .clk(clk),
        .rst_n(rst_n),

        .we(we),
        .addr(addr),
        .data_in1(data_in1),
        .data_in2(data_in2),

        .data_out1(coord_X),
        .data_out2(coord_Y)
    );

    // exp_LUT
    exp_LUT exp_LUT (
        .clk(clk),
        .rst_n(rst_n),

        .index(index_LUT_exp),
        .result_exp(result_exp)
    );


    // -------------------------------------------------------------------------
    // Testbench tasks
    // -------------------------------------------------------------------------

    // Display state task
    task display_state(input string label);
    $display("[%0t] %-22s | coord_X=%08b coord_Y=%08b addr=%08b",
        $time, label, coord_X, coord_Y, addr);
    endtask

    // Task to write coordinate data to memory
    task write_memory(input logic [ADDR_W-1:0] addr_task, input logic [15:0] data_in1_task, input logic [15:0] data_in2_task);
        control_mem = 0;
        we          = 1;
        addr_tb     = addr_task;
        data_in1    = data_in1_task;
        data_in2    = data_in2_task;

        @(posedge clk);

        we          = 0;
        control_mem = 1;
    endtask

    // Task to read coordinate data from memory
    task read_memory(input logic [ADDR_W-1:0] addr_task);
        control_mem = 0;
        addr_tb = addr_task;
        @(posedge clk);
        $display("READ memory addr=%08b coord_X=%08b coord_Y=%08b", addr, coord_X, coord_Y);
        control_mem = 1;
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
                if (out_i <= 1 && out_j < 100) begin
                    $display("[%0t] RESULT i=%0d j=%0d P_ij=%0d",
                            $time,
                            out_i,
                            out_j,
                            P_ij);
                end
            end
            if (valid_sum_row_P) begin
                $display("[%0t] RESULT sum_row_P i=%0d j=%0d sum_row_P=%0d",
                        $time,
                        out_i,
                        out_j,
                        sum_row_P);
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
        addr = (control_mem == 1) ? addr_compute : addr_tb;
    end

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
        clk         =  0;
        rst_n       =  0;
        we          =  0;
        addr_tb     = '0;
        control_mem =  0;
        start       =  0;
        step_idx    = '0;
        credit_avail = 1;

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
        fd = $fopen("data/cluster_fixed.txt", "r");

        if (fd == 0) begin
            $fatal(1, "Error while opening cluster_fixed.txt");
        end

        addr_file = 0;

        while (addr_file < 100) begin

            ret = $fscanf(fd, "%d %d", xf, yf);

            if (ret != 2)
                break;

            write_memory(addr_file[ADDR_W-1:0], xf[15:0], yf[15:0]);

            addr_file++;
        end

        $fclose(fd);

        $display("%0d points loaded from cluster_fixed.txt", addr_file);

        
        // ---------------------------------------------------------------------
        // Start computation
        // ---------------------------------------------------------------------
        control_mem = 1;
        start = 1;
        @(posedge clk);
        start = 0;
        // Wait for computation to complete
        wait(out_i == 2);

        #10;
        $display("\n=== Simulation completed ===");
        $finish;
    end

endmodule