//=============================================================================
// Testbench: cluster_assign_tb
//
// Testbench for cluster_assign: loads a small subset of the full benchmark
// point set (produced by the fixed-point software reference model, see
// docs/ARCHITECTURE.md section 8), runs cluster_assign to assign each point
// to a cluster.
//=============================================================================

module cluster_assign_tb #(
    parameter int NB_POINTS    = 100,      // Number of points, Currently a fixed default
    parameter int COORD_W      = 16,       // Coordinate width, fixed-point
    parameter int ADDR_W       = 7,        // Point BRAM address width
    parameter int TOL          = 422144877 // cst TOL
	);

    // -------------------------------------------------------------------
    // Declaration of the cluster search module and cluster memory
    // -------------------------------------------------------------------

    logic       clk;
    logic       rst_n;

    logic start_b4; // Launches the cluster_assign module


    // --- Point coordinate BRAM port ---
    logic [ADDR_W-1:0] addr;

    logic              control_mem;
    logic [ADDR_W-1:0] addr_tb;
    logic [ADDR_W-1:0] addr_compute;

    logic [COORD_W-1:0] coord_X;
    logic [COORD_W-1:0] coord_Y;

    // --- Clusters BRAM Port ---
    logic              control_mem_cluster;
    logic [ADDR_W-1:0] addr_cluster;
    logic [ADDR_W-1:0] addr_cluster_tb;
    logic [ADDR_W-1:0] addr_cluster_compute;
    logic              we_cluster;
    logic [ADDR_W-1:0] cluster_in;
    logic              valid_cluster;
    logic [ADDR_W-1:0] cluster_out;

    logic done_cluster;

    // DUT instantiation
    cluster_assign #(
        .NB_POINTS (NB_POINTS),
        .COORD_W   (COORD_W),
        .ADDR_W    (ADDR_W),
        .TOL       (TOL)
    ) cluster_assign (
        .clk           (clk),
        .rst_n         (rst_n),

        .start         (start_b4),

        .addr_coord    (addr_compute),
        .coord_X       (coord_X),
        .coord_Y       (coord_Y),

        .addr_cluster  (addr_cluster_compute),
        .we_cluster    (we_cluster),
        .valid_cluster (valid_cluster),
        .cluster_out   (cluster_out),

        .done          (done_cluster)
    );


    // Clusters memory
    memory_cluster #(
        .ADDR_W (ADDR_W)
    ) memory_cluster (
        .clk(clk),
        .rst_n(rst_n),

        .we(we_cluster),
        .addr(addr_cluster),
        .data_in(cluster_out),

        .valid_cluster(valid_cluster),
        .data_out(cluster_in)
    );


    // memory access
    logic       we;
    logic [COORD_W-1:0] data_in1;
    logic [COORD_W-1:0] data_in2;

    // Coordinate memory
    memory_dual_port #(
        .ADDR_W (ADDR_W),
        .DATA_W (COORD_W)
    ) coord_memory (
        .clk(clk),
        .rst_n(rst_n),

        .we(we),
        .addr(addr),
        .data_in1(data_in1),
        .data_in2(data_in2),

        .data_out1(coord_X),
        .data_out2(coord_Y)
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

    // Task to write update values to memory
    task read_memory_cluster(input logic [ADDR_W-1:0] addr_task);
        control_mem_cluster = 0;
        addr_cluster_tb = addr_task;
        @(posedge clk);
        $display("READ memory cluster[%0d] = %0d",
        addr_cluster, cluster_in);
        control_mem_cluster = 1;
    endtask

    // Task to read coordinate data from memory
    task automatic monitor_results();
        int result_count = 0;

        forever begin
            @(posedge clk);
            if (done_cluster) begin
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
        addr_cluster = (control_mem_cluster == 1) ? addr_cluster_compute : addr_cluster_tb;
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
        control_mem_cluster =  1;
        addr_cluster_tb     = '0;
        start_b4    =  0;

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
        start_b4 = 1;
        @(posedge clk);
        start_b4 = 0;

        // Wait for computation to complete
        wait(done_cluster);
        @(posedge clk);

        for (int i = 0; i < 100; i++) begin
            read_memory_cluster(i);
        end

        #10;
        $display("\n=== Simulation completed ===");
        $finish;
    end

endmodule