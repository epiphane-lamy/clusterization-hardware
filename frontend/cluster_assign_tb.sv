

module cluster_assign_tb #(
    parameter int NB_POINTS    = 100,         // nombre de points stockés en dur, prochainement chargé au début du calcul <= 2**ADDR_W
    parameter int NB_ITER      = 50,          // nombre d'itérations
    parameter int COORD_W      = 16,          // largeur des coordonnees
    parameter int ADDR_W       = 7,           // largeur des adresses points Xf
    parameter int TOL          = 422144877    // cst TOL
	);

    // -------------------------------------------------------------------
    // Déclaration bloc de recherche de clusters + mémoire cluster
    // -------------------------------------------------------------------

    logic       clk;
    logic       rst_n;

    logic start_b4;     // lance le bloc cluster_assign


    // --- Port BRAM point (adresse incrementee chaque cycle) ---
    
    logic [ADDR_W-1:0] addr;

    logic              control_mem;
    logic [ADDR_W-1:0] addr_tb;
    logic [ADDR_W-1:0] addr_compute;

    logic [COORD_W-1:0] coord_X;
    logic [COORD_W-1:0] coord_Y;

    // --- Port BRAM clusters ---
    logic              control_mem_cluster;
    logic [ADDR_W-1:0] addr_cluster;
    logic [ADDR_W-1:0] addr_cluster_tb;
    logic [ADDR_W-1:0] addr_cluster_compute;
    logic              we_cluster;
    logic [ADDR_W-1:0] cluster_in;
    logic              valid_cluster;
    logic [ADDR_W-1:0] cluster_out;

    logic done_cluster;

    // DUT cluster_assign
    cluster_assign #(
        .NB_POINTS (NB_POINTS),
        .COORD_W   (COORD_W),
        .ADDR_W    (ADDR_W),
        .TOL       (TOL)
    ) dut_cluster_assign (
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


    // memory cluster
    memory_cluster #(
        .ADDR_W (ADDR_W)
    ) mem_cluster (
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

    // DUT memory
    memory_dual_port #(
        .ADDR_W (ADDR_W),
        .DATA_W (COORD_W)
    ) memory_coord (
        .clk(clk),
        .rst_n(rst_n),

        .we(we),
        .addr(addr),
        .data_in1(data_in1),
        .data_in2(data_in2),

        .data_out1(coord_X),
        .data_out2(coord_Y)
    );




    task display_state(input string label);
    $display("[%0t] %-22s | coord_X=%08b coord_Y=%08b addr=%08b",
        $time, label, coord_X, coord_Y, addr);
    endtask

    // write memory task
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


    task read_memory_cluster(input logic [ADDR_W-1:0] addr_task);
        control_mem_cluster = 0;
        addr_cluster_tb = addr_task;
        @(posedge clk);
        $display("lecture mémoire cluster cluster[%0d] = %0d",
        addr_cluster, cluster_in);
        control_mem_cluster = 1;
    endtask


    task automatic monitor_results();
        int result_count = 0;

        forever begin
            @(posedge clk);
            if (done_cluster) begin
                $display("[%0t] Calcul terminé", $time);
                break;
            end
        end
    endtask

    always #5 clk = ~clk;


    always_comb begin
        addr = (control_mem == 1) ? addr_compute : addr_tb;
        addr_cluster = (control_mem_cluster == 1) ? addr_cluster_compute : addr_cluster_tb;
    end

    integer fd;
    int ret;
    int xf, yf;
    int addr_file;
    initial begin


        $display("\n=== début de la simulation ===");

        // init
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

        @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        
        // Écriture des vecteurs X_f et Y_f en mémoire (100 points)
        fd = $fopen("cluster_fixed.txt", "r");

        if (fd == 0) begin
            $fatal(1, "Impossible d'ouvrir cluster_fixed.txt");
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

        $display("%0d points chargés depuis cluster_fixed.txt", addr_file);


        // lancement calcul
        control_mem = 1;
        start_b4 = 1;
        @(posedge clk);
        start_b4 = 0;

        wait(done_cluster);
        @(posedge clk);

        for (int i = 0; i < 100; i++) begin
            read_memory_cluster(i);
        end

        #10;
        $display("\n=== Fin de la simulation ===");
        $finish;
    end

endmodule