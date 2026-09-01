//=============================================================================
// Testbench: act_coord_tb
//
// Testbench for the upd block: loads a small subset of the full benchmark
// point set and the initial snapshot of the update value memory (produced by
// the fixed-point software reference model, see docs/ARCHITECTURE.md section 8),
// runs the upd block to produce the updated coordinate for comparison
// against the software reference.
//
//=============================================================================

module act_coord_tb #(
    parameter int NB_POINTS = 100, // Number of points, Currently a fixed default
    parameter int COORD_W   = 16,  // Coordinate width, fixed-point
    parameter int ACT_W     = 32,  // Update value width
    parameter int ADDR_W    = 7    // Point BRAM address width
	);

    logic clk;
    logic rst_n;

    logic start; // Launches a full sweep (all rows) for the current step

    // --- Point coordinate BRAM port ---
    logic [COORD_W-1:0] coord_X;
    logic [COORD_W-1:0] coord_Y;

    logic              control_mem_coord;
    logic [ADDR_W-1:0] addr_coord;
    logic [ADDR_W-1:0] addr_coord_tb;
    logic [ADDR_W-1:0] addr_coord_compute;

	logic              we_coord;
	logic              we_coord_tb;
	logic              we_coord_compute;

    logic [COORD_W-1:0] coord_X_act;
    logic [COORD_W-1:0] coord_Y_act;
    logic [COORD_W-1:0] coord_X_act_tb;
    logic [COORD_W-1:0] coord_Y_act_tb;
    logic [COORD_W-1:0] coord_X_act_compute;
    logic [COORD_W-1:0] coord_Y_act_compute;

    // --- Update value memory port ---
    logic               control_mem_act;
    logic [ADDR_W-1:0]  addr_act;
    logic [ADDR_W-1:0]  addr_act_tb;
    logic [ADDR_W-1:0]  addr_act_compute;
    logic signed [31:0] mult_act_X;
    logic signed [31:0] mult_act_Y;

    logic done;

    // DUT instantiation
    act_coord #(
        .NB_POINTS   (NB_POINTS),
        .COORD_W     (COORD_W),
        .ADDR_W      (ADDR_W)
    ) upd_block (
        .clk         (clk),
        .rst_n       (rst_n),

        .start       (start),

        .addr_coord  (addr_coord_compute),
        .we_coord    (we_coord_compute),

        .coord_X     (coord_X),
        .coord_Y     (coord_Y),

        .coord_X_act (coord_X_act_compute),
        .coord_Y_act (coord_Y_act_compute),

        .addr_act    (addr_act_compute),
        .mult_act_X  (mult_act_X),
        .mult_act_Y  (mult_act_Y),

        .done        (done)
    );
    

    // Coordinate memory
    memory_dual_port #(
        .ADDR_W    (ADDR_W),
        .DATA_W    (COORD_W)
    ) coord_memory (
        .clk       (clk),
        .rst_n     (rst_n),

        .we        (we_coord),
        .addr      (addr_coord),
        .data_in1  (coord_X_act),
        .data_in2  (coord_Y_act),

        .data_out1 (coord_X),
        .data_out2 (coord_Y)
    );


    // memory access
    logic       we_act;
    logic [31:0] mult_act_X_in1;
    logic [31:0] mult_act_Y_in2;

    // Update value memory
    memory_dual_port #(
        .ADDR_W (ADDR_W),
        .DATA_W (ACT_W)
    ) upd_memory (
        .clk       (clk),
        .rst_n     (rst_n),

        .we        (we_act),
        .addr      (addr_act),
        .data_in1  (mult_act_X_in1),
        .data_in2  (mult_act_Y_in2),

        .data_out1 (mult_act_X),
        .data_out2 (mult_act_Y)
    );



    // -------------------------------------------------------------------------
    // Testbench tasks
    // -------------------------------------------------------------------------

    // Display state task
    task display_state(input string label);
    $display("[%0t] %-22s | coord_X=%08b coord_Y=%08b addr=%08b",
        $time, label, coord_X, coord_Y, addr_coord);
    endtask

    // Task to write coordinate data to memory
    task write_memory_coord(input logic [ADDR_W-1:0] addr_task, input logic [15:0] data_in1_task, input logic [15:0] data_in2_task);
        control_mem_coord    = 0;
        we_coord_tb    = 1;
        addr_coord_tb        = addr_task;
        coord_X_act_tb = data_in1_task;
        coord_Y_act_tb = data_in2_task;

        @(posedge clk);

        we_coord_tb = 0;
        control_mem_coord = 1;
    endtask
    
    // Task to write update values to memory
    task write_memory_act(input logic [ADDR_W-1:0] addr_task, input logic [31:0] data_in1_task, input logic [31:0] data_in2_task);
        control_mem_act = 0;
        we_act          = 1;
        addr_act_tb     = addr_task;
        mult_act_X_in1  = data_in1_task;
        mult_act_Y_in2  = data_in2_task;

        @(posedge clk);

        we_act          = 0;
        control_mem_act = 1;
    endtask

    // Task to read coordinate data from memory
    task read_memory_coord(input logic [ADDR_W-1:0] addr_task);
        control_mem_coord = 0;
        addr_coord_tb = addr_task;
        @(posedge clk);
        $display("READ memory addr=%08b coord_X=%08b coord_Y=%08b", addr_coord, coord_X, coord_Y);
        control_mem_coord = 1;
    endtask


    // Automatic task to monitor computation results
    task automatic monitor_results();

        forever begin
            @(posedge clk);

            if (we_coord_compute) begin
                $display("[%0t] RESULT coord_act coord_X_act=%0d coord_Y_act=%0d",
                        $time,
                        coord_X_act,
                        coord_Y_act);
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
        addr_coord  = control_mem_coord ? addr_coord_compute : addr_coord_tb;
        we_coord    = control_mem_coord ? we_coord_compute   : we_coord_tb;
        coord_X_act = control_mem_coord ? coord_X_act_compute : coord_X_act_tb;
        coord_Y_act = control_mem_coord ? coord_Y_act_compute : coord_Y_act_tb;

        addr_act    = control_mem_act   ? addr_act_compute : addr_act_tb;
        
    end


    // -------------------------------------------------------------------------
    // Testbench stimulus
    // -------------------------------------------------------------------------

    integer fd;
    int ret;
    int xf, yf;
    int mult_act_x, mult_act_y;
    int addr_file;
    initial begin


        $display("\n=== Simulation start ===");

        // ---------------------------------------------------------------------
        // Initialization
        // ---------------------------------------------------------------------
        clk               = 0;
        rst_n             = 0;
        we_coord_tb       = 0;
        we_act            = 0;
        addr_coord_tb     = '0;
        control_mem_coord = 0;
        control_mem_act   = 0;
        start             = 0;

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

            write_memory_coord(addr_file[ADDR_W-1:0], xf[15:0], yf[15:0]);

            addr_file++;
        end

        $fclose(fd);

        $display("%0d points loaded from cluster_fixed.txt", addr_file);

        // ---------------------------------------------------------------------
        // Load update values into memory
        // ---------------------------------------------------------------------
        fd = $fopen("data/mult_act_fixed.txt", "r");

        if (fd == 0) begin
            $fatal(1, "Error while opening mult_act_fixed.txt");
        end

        addr_file = 0;

        while (addr_file < 100) begin

            ret = $fscanf(fd, "%d %d", mult_act_x, mult_act_y);

            if (ret != 2)
                break;

            write_memory_act(addr_file[ADDR_W-1:0], mult_act_x, mult_act_y);

            addr_file++;
        end

        $fclose(fd);

        $display("%0d points loaded from mult_act_fixed.txt", addr_file);


        // ---------------------------------------------------------------------
        // Start computation
        // ---------------------------------------------------------------------
        control_mem_coord = 1;
        control_mem_act   = 1;
        start = 1;
        @(posedge clk);
        start = 0;
        // Wait for computation to complete
        wait(done);

        #10;
        $display("\n=== Simulation completed ===");
        $finish;
    end

endmodule
