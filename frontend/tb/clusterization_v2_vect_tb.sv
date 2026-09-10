`timescale 1ns / 1ps

module clusterization_v2_vect_tb #(
    // Parameters passed from the Makefile via xrun -defparam
    parameter integer HALF_PERIOD_PS = 5000, 
    parameter integer WAIT_TIME_NS   = 5,
    parameter integer SIM_RUNTIME    = 0,
    // Parameters used by DUV
    parameter int NB_POINTS          = 1250,        // Number of points
    parameter int NB_ITER            = 50,          // Number of iterations
    parameter int COORD_W            = 16,          // Coordinate width
    parameter int ADDR_W             = 12,          // Point address width
    parameter int P_IJ_W             = 16,          // P_ij width, fixed-point
    parameter int ADDR_P_IJ_W        = 12,          // P_ij address width (same ADR-0007 note as ADDR_W above)
    parameter int ADDR_LUT_INV       = 10,          // Inverse LUT address width
    parameter int ADDR_LUT_EXP       = 14,          // exp LUT address width
    parameter int ACT_W              = 16,          // Update value width, signed fixed-point
    parameter int STEP_W             = 6,           // Iteration counter width (max_iter=50 -> 6 bits is enough)
    parameter int K_W                = 16,          // Precomputed K_step constant width, signed, always negative
    parameter int SQ_W               = 2 * COORD_W, // dx*dx / dy*dy: product of two signed COORD_W-bit values
    parameter int D2_W               = SQ_W + 1,    // D2 = x2 + y2
    parameter int TOL                = 170459136    // Squared-distance tolerance for cluster_assign, precomputed in software
)();

    // System Signals
    logic               clk;
    logic               rst_n;
    logic               start;

    logic               control_mem_coord_load;
    logic               we_coord_load;
    logic [ADDR_W-1:0]  addr_coord_load;
    logic [COORD_W-1:0] data_in1_coord_load;
    logic [COORD_W-1:0] data_in2_coord_load;


    logic [COORD_W-1:0] coord_X;
    logic [COORD_W-1:0] coord_Y;
    
    logic               control_mem_cluster_read;
    logic [ADDR_W-1:0]  addr_cluster_read;
    logic [ADDR_W-1:0]  cluster_read;

    logic               done;

    // Clock scaling variable
    real half_period_ns;

    clusterization_v2 clusterization_DUV (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .start                    (start),

        .control_mem_coord_load   (control_mem_coord_load),
        .we_coord_load            (we_coord_load),
        .addr_coord_load          (addr_coord_load),
        .data_in1_coord_load      (data_in1_coord_load),
        .data_in2_coord_load      (data_in2_coord_load),

        .control_mem_cluster_read (control_mem_cluster_read),
        .addr_cluster_read        (addr_cluster_read),
        .cluster_read             (cluster_read),

        .done                     (done)
    );

 
    // -------------------------------------------------------------------
    // Tasks to write both coordinate (exp block / grad block) memories
    // through the external testbench load port (see ARCHITECTURE.md
    // section 9.2 for the ownership handoff these tasks rely on:
    // control_mem_coord_load = 0 grants the TB ownership for the
    // duration of the access, and setting it back to 1 hands ownership
    // back to the DUT's normal owner priority chain).
    // -------------------------------------------------------------------
    task write_memory_coord(input logic [ADDR_W-1:0] addr_task, input logic [15:0] data_in1_task, input logic [15:0] data_in2_task);
        control_mem_coord_load = 0;
        we_coord_load          = 1;
        addr_coord_load        = addr_task;
        data_in1_coord_load    = data_in1_task;
        data_in2_coord_load    = data_in2_task;
        @(posedge clk);
        we_coord_load          = 0;
        control_mem_coord_load = 1;
    endtask


    // Clock Generation dynamically scaled by Makefile frequency
    initial begin
        half_period_ns = HALF_PERIOD_PS / 1000.0;
        clk = 1'b0;
        forever #(half_period_ns) clk = ~clk; 
    end

    // Main Test Stimulus
    integer fd;
    int ret;
    int xf, yf;
    real xf_real, yf_real;
    real scale, xmin, ymin;
    real norm_scale, center_x, center_y;
    int addr_file;
    int addr_mem_coord;
    time start_time;
    time done_time;
    int cycle_count;
    initial begin


        $display("\n=== Simulation start ===");

        // Initialization
        clk                       =  0;
        rst_n                     =  0;
        start                     =  0;

        control_mem_coord_load =  0;
        we_coord_load          =  0;
        addr_coord_load        = '0;

        control_mem_cluster_read  =  1;
        addr_cluster_read         = '0;

        @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        
        // Load the X_f / Y_f vectors into memory. This file is produced by
        // the fixed-point software reference model (see docs/ARCHITECTURE.md
        // section 8) -- it is the same benchmark, in the same fixed-point
        // representation, that the RTL results are ultimately compared
        // against.
        fd = $fopen("data/cluster_fixed_full_benchmark.txt", "r");

        if (fd == 0) begin
            $fatal(1, "Could not open cluster_fixed_full_benchmark.txt");
        end

        // Header line: scale/offset/normalization parameters, re-used later
        // to convert fixed-point coordinates back to real-world units when
        // writing the results file.
        ret = $fscanf(fd, "%f %f %f %f %f %f", scale, xmin, ymin, norm_scale, center_x, center_y);
        addr_file = 0;

        // Load every point into BOTH duplicated coordinate memories at the
        // same address, with the same initial values -- required so the two
        // copies stay in sync from the very first iteration (see ADR-0003).
        while (addr_file < NB_POINTS) begin

            ret = $fscanf(fd, "%d %d", xf, yf);

            if (ret != 2)
                break;

            write_memory_coord(addr_file[ADDR_W-1:0], xf[15:0], yf[15:0]);

            addr_file++;
        end

        $fclose(fd);

        $display("%0d points loaded from cluster_fixed_full_benchmark.txt", addr_file);
        

        // Launch computation: hand coordinate-memory ownership back to the
        // DUT's normal priority chain (see ARCHITECTURE.md section 9.2),
        // then pulse start.
        control_mem_coord_load = 1;
        start = 1;
        @(posedge clk);
        start = 0;

        // Start measuring AFTER the start pulse
        start_time = $time;
        cycle_count = 0;

        // Wait for completion while counting cycles
        while (!done) begin
            @(posedge clk);
            cycle_count++;
        end
        done_time = $time;

        $display("\n========================================");
        $display("        CLUSTERIZATION TIMING");
        $display("========================================");
        $display("Number of points : %0d", NB_POINTS);
        $display("Number of iter.  : %0d", NB_ITER);
        $display("Clock frequency  : %0.3f MHz", 1000.0 / (half_period_ns * 2.0));
        $display("Clock period     : %0.3f ns", half_period_ns * 2.0);
        $display("Start time       : %0.3f ns", start_time / 1000.0);
        $display("Done time        : %0.3f ns", done_time / 1000.0);
        $display("Compute time     : %0.3f ns", (done_time - start_time) / 1000.0);
        $display("Compute time     : %0.6f ms", (done_time - start_time) / 1_000_000.0);
        $display("Compute cycles   : %0d", cycle_count);
        $display("========================================\n");

        $finish;
    end

endmodule