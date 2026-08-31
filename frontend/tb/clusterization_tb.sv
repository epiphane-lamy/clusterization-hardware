//=============================================================================
// Testbench: clusterization_tb
//
// Full-system testbench for the clusterization toplevel: loads a benchmark
// point set (produced by the fixed-point software reference model, see
// docs/ARCHITECTURE.md section 8) into both duplicated coordinate memories,
// runs the full pipeline to completion, and writes out the final
// coordinates alongside their assigned cluster numbers for comparison
// against the software reference (see the plotting scripts referenced in
// the README).
//
// NOTE: this testbench targets the macro-backed build (make sim_rtl_bb, see
// ARCHITECTURE.md section 10), not the plain behavioral memories.
//=============================================================================

module clusterization_tb #(
    parameter int NB_POINTS    = 1250,        // Number of points
    parameter int NB_ITER      = 50,          // Number of iterations
    parameter int COORD_W      = 16,          // Coordinate width
    parameter int ADDR_W       = 12,          // Point address width
    parameter int P_IJ_W       = 16,          // P_ij width, fixed-point
    parameter int ADDR_P_IJ_W  = 12,          // P_ij address width (same ADR-0007 note as ADDR_W above)
    parameter int ADDR_LUT_INV = 10,          // Inverse LUT address width
    parameter int ADDR_LUT_EXP = 14,          // exp LUT address width
    parameter int ACT_W        = 16,          // Update value width, signed fixed-point
    parameter int STEP_W       = 6,           // Iteration counter width (max_iter=50 -> 6 bits is enough)
    parameter int K_W          = 16,          // Precomputed K_step constant width, signed, always negative
    parameter int SQ_W         = 2 * COORD_W, // dx*dx / dy*dy: product of two signed COORD_W-bit values
    parameter int D2_W         = SQ_W + 1,    // D2 = x2 + y2
    parameter int TOL          = 170459136    // Squared-distance tolerance for cluster_assign, precomputed in software
	);

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


    clusterization #(
        .NB_POINTS                (NB_POINTS),
        .NB_ITER                  (NB_ITER),
        .COORD_W                  (COORD_W),
        .ADDR_W                   (ADDR_W),
        .P_IJ_W                   (P_IJ_W),
        .ADDR_P_IJ_W              (ADDR_P_IJ_W),
        .ADDR_LUT_INV             (ADDR_LUT_INV),
        .ADDR_LUT_EXP             (ADDR_LUT_EXP),
        .ACT_W                    (ACT_W),
        .STEP_W                   (STEP_W),
        .K_W                      (K_W),
        .SQ_W                     (SQ_W),
        .D2_W                     (D2_W),
        .TOL                      (TOL)
    ) clusterization (
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

    task read_memory_cluster(input logic [ADDR_W-1:0] addr_task);
        control_mem_cluster_read = 0;
        addr_cluster_read        = addr_task;
        @(posedge clk);
        $display("CLUSTER MEMORY READ cluster[%0d] = %0d",
        addr_cluster_read, cluster_read);
        control_mem_cluster_read = 1;
    endtask

    task save_memory_cluster(input logic [ADDR_W-1:0] addr_task);
        control_mem_cluster_read = 0;
        addr_cluster_read   = addr_task;
        @(posedge clk);
        $display("CLUSTER MEMORY READ cluster[%0d] = %0d",
        addr_cluster_read, cluster_read);
        $fdisplay(fd_cluster, "%0d", cluster_read);
        control_mem_cluster_read = 1;
    endtask



    always #5 clk = ~clk;

    integer fd, fd_cluster;
    int ret;
    int xf, yf;
    real xf_real, yf_real;
    real scale, xmin, ymin;
    real norm_scale, center_x, center_y;
    int addr_file;
    int addr_mem_coord;
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

 
        // Wait for the full pipeline (all NB_ITER iterations + final
        // cluster_assign pass) to complete.
        wait (done);

        @(posedge clk);
        for (int i = 0; i < NB_POINTS; i++) begin
            read_memory_cluster(i);
        end

        // Write out the final results: real-world coordinates (reconstructed
        // from the fixed-point representation using the header parameters
        // read above) alongside each point's assigned cluster number, for
        // the plotting scripts referenced in the README.
        fd_cluster = $fopen("data/resultats.txt", "w");
        fd         = $fopen("data/cluster_fixed_full_benchmark.txt", "r");

        if (fd_cluster == 0) begin
            $display("Error: could not open the output file");
            $finish;
        end
        if (fd == 0) begin
            $fatal(1, "Could not open cluster_fixed_full_benchmark.txt");
        end


        ret = $fscanf(fd, "%f %f %f %f %f %f", scale, xmin, ymin, norm_scale, center_x, center_y);

        if (ret != 6) begin
            $fatal(1, "Error reading header: scale/xmin/ymin/norm_scale/center_x/center_y");
        end

        $display("scale=%f xmin=%f ymin=%f norm_scale=%f center_x=%f center_y=%f", scale, xmin, ymin, norm_scale, center_x, center_y);

        addr_file = 0;
        while (addr_file < NB_POINTS) begin

            ret = $fscanf(fd, "%d %d", xf, yf);

            if (ret != 2)
                break;

            xf_real = ((xf / 256.0) / scale + xmin) / norm_scale + center_x;
            yf_real = ((yf / 256.0) / scale + ymin) / norm_scale + center_y;
            $fwrite(fd_cluster, "%f %f ", xf_real, yf_real);

            $fdisplay(fd_cluster, "%0d", clusterization.memory_cluster.u_ram.memory[addr_file]);

            addr_file++;
        end

        $fclose(fd);
        $fclose(fd_cluster);


        #10;
        $display("\n=== Simulation end ===");
        $finish;
    end



endmodule
