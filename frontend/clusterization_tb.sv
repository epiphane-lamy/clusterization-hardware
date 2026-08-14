import clusterization_pkg::*;

module clusterization_tb #(
    parameter int NB_POINTS    = clusterization_pkg::NB_POINTS, // nombre de points stockés en dur, prochainement chargé au début du calcul <= 2**ADDR_W
    parameter int NB_ITER      = 50,                            // nombre d'itérations
    parameter int COORD_W      = 16,                            // largeur des coordonnees
    parameter int ADDR_W       = $clog2(NB_POINTS),             // largeur des adresses points Xf
    parameter int P_IJ_W       = 16,                            // largeur des P_ij, fixed-point SIGNE
    parameter int ADDR_P_IJ_W  = $clog2(NB_POINTS),             // largeur des adresses P_ij
    parameter int ADDR_LUT_INV = 10,                            // largeur des adresses LUT exp
    parameter int ADDR_LUT_EXP = 14,                            // largeur des adresses LUT exp
    parameter int ACT_W        = 32,                            // largeur des valeurs d'actualisation, fixed-point SIGNE
    parameter int STEP_W       = 6,                             // largeur du compteur d'iteration (max_iter=50 -> 6 bits suffisent)
    parameter int K_W          = 16,                            // largeur de la constante K_step precalculee (signee, negative)
    parameter int SQ_W         = 2 * COORD_W,                   // dx*dx et dy*dy : produit de deux signed COORD_W bits -> 2*COORD_W bits
    parameter int D2_W         = SQ_W + 1,                      // D2 = x2 + y2
    parameter int TOL          = 422144877                      // cst TOL
	);

    logic               clk;
    logic               rst_n;
    logic               start;

    coord_mem_port_t    port_coord_b1_load;
    logic               control_mem_coord_load_b1;
    logic               we_coord_tb_b1;
    logic [ADDR_W-1:0]  addr_coord_tb_b1;
    logic [COORD_W-1:0] data_in1_coord_tb_b1;
    logic [COORD_W-1:0] data_in2_coord_tb_b1;

    coord_mem_port_t    port_coord_b2_load;
    logic               control_mem_coord_load_b2;
    logic               we_coord_tb_b2;
    logic [ADDR_W-1:0]  addr_coord_tb_b2;
    logic [COORD_W-1:0] data_in1_coord_tb_b2;
    logic [COORD_W-1:0] data_in2_coord_tb_b2;


    logic [COORD_W-1:0] coord_X;
    logic [COORD_W-1:0] coord_Y;
    
    logic               control_mem_cluster_read;
    logic [ADDR_W-1:0]  addr_cluster_read;
    logic [ADDR_W-1:0]  cluster_read;

    logic               done;


    clusterization #(
        .NB_POINTS    (NB_POINTS),
        .NB_ITER      (NB_ITER),
        .COORD_W      (COORD_W),
        .ADDR_W       (ADDR_W),
        .P_IJ_W       (P_IJ_W),
        .ADDR_P_IJ_W  (ADDR_P_IJ_W),
        .ADDR_LUT_INV (ADDR_LUT_INV),
        .ADDR_LUT_EXP (ADDR_LUT_EXP),
        .ACT_W        (ACT_W),
        .STEP_W       (STEP_W),
        .K_W          (K_W),
        .SQ_W         (SQ_W),
        .D2_W         (D2_W),
        .TOL          (TOL)
    ) dut_clusterization (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),

        .control_mem_coord_load_b1(control_mem_coord_load_b1),
        .control_mem_coord_load_b2(control_mem_coord_load_b2),
        .port_coord_b1_load       (port_coord_b1_load),
        .port_coord_b2_load       (port_coord_b2_load),

        .control_mem_cluster_read (control_mem_cluster_read),
        .addr_cluster_read        (addr_cluster_read),
        .cluster_read             (cluster_read),

        .done                     (done)
    );


    assign port_coord_b1_load.we       = we_coord_tb_b1;
    assign port_coord_b1_load.addr     = addr_coord_tb_b1;
    assign port_coord_b1_load.data_in1 = data_in1_coord_tb_b1;
    assign port_coord_b1_load.data_in2 = data_in2_coord_tb_b1;


    assign port_coord_b2_load.we       = we_coord_tb_b2;
    assign port_coord_b2_load.addr     = addr_coord_tb_b2;
    assign port_coord_b2_load.data_in1 = data_in1_coord_tb_b2;
    assign port_coord_b2_load.data_in2 = data_in2_coord_tb_b2;

    // -------------------------------------------------------------------
    // Tasks write/read memory coord bloc exp (1) et bloc grad (2)
    // -------------------------------------------------------------------
    task write_memory_coord_b1(input logic [ADDR_W-1:0] addr_task, input logic [15:0] data_in1_task, input logic [15:0] data_in2_task);
        control_mem_coord_load_b1 = 0;
        we_coord_tb_b1            = 1;
        addr_coord_tb_b1          = addr_task;
        data_in1_coord_tb_b1      = data_in1_task;
        data_in2_coord_tb_b1      = data_in2_task;

        @(posedge clk);

        we_coord_tb_b1            = 0;
        control_mem_coord_load_b1 = 1;
    endtask
    
    task write_memory_coord_b2(input logic [ADDR_W-1:0] addr_task, input logic [15:0] data_in1_task, input logic [15:0] data_in2_task);
        control_mem_coord_load_b2 = 0;
        we_coord_tb_b2            = 1;
        addr_coord_tb_b2          = addr_task;
        data_in1_coord_tb_b2      = data_in1_task;
        data_in2_coord_tb_b2      = data_in2_task;

        @(posedge clk);

        we_coord_tb_b2            = 0;
        control_mem_coord_load_b2 = 1;
    endtask

    /*
    task read_memory_coord(input logic [ADDR_W-1:0] addr_task);
        control_mem_coord_load_b1 = 0;
        control_mem_coord_load_b2 = 0;
        addr_coord_tb_b1 = addr_task;
        addr_coord_tb_b2 = addr_task;
        @(posedge clk);
        $display("lecture mémoire addr_coord_b1=%0d coord_X=%0d coord_Y=%0d",
        addr_coord_tb_b1, coord_X, coord_Y);
        control_mem_coord_load_b1 = 1;
        control_mem_coord_load_b2 = 1;
    endtask*/

    task read_memory_coord(input logic [ADDR_W-1:0] addr_task);
        control_mem_coord_load_b1 = 0;
        control_mem_coord_load_b2 = 0;
        addr_coord_tb_b1 = addr_task;
        addr_coord_tb_b2 = addr_task;
        @(posedge clk);
        $display("lecture mémoire addr_task=%0d owner_b1=%0d addr_coord_b1(DUT)=%0d we_coord_b1(DUT)=%0d coord_X=%0d coord_Y=%0d",
            addr_task,
            dut_clusterization.owner_b1,
            dut_clusterization.addr_coord_b1,
            dut_clusterization.we_coord_b1,
            dut_clusterization.coord_X_b1,
            dut_clusterization.coord_Y_b1);
        control_mem_coord_load_b1 = 1;
        control_mem_coord_load_b2 = 1;
    endtask

    task read_memory_cluster(input logic [ADDR_W-1:0] addr_task);
        control_mem_cluster_read = 0;
        addr_cluster_read   = addr_task;

        @(posedge clk);
        $display("lecture mémoire cluster cluster[%0d] = %0d",
        addr_cluster_read, cluster_read);
        
        control_mem_cluster_read = 1;
    endtask

    task save_memory_cluster(input logic [ADDR_W-1:0] addr_task);
        control_mem_cluster_read = 0;
        addr_cluster_read   = addr_task;

        @(posedge clk);
        $display("lecture mémoire cluster cluster[%0d] = %0d",
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
    int addr_file;
    int addr_mem_coord;
    initial begin


        $display("\n=== début de la simulation ===");

        // init
        clk                       =  0;
        rst_n                     =  0;
        start                     =  0;

        control_mem_coord_load_b1 =  0;
        control_mem_coord_load_b2 =  0;
        we_coord_tb_b1            =  0;
        we_coord_tb_b2            =  0;
        addr_coord_tb_b1          = '0;
        addr_coord_tb_b2          = '0;

        control_mem_cluster_read  =  1;
        addr_cluster_read    = '0;

        @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        
        // Écriture des vecteurs X_f et Y_f en mémoire
        fd = $fopen("cluster_fixed_full_benchmark.txt", "r");

        if (fd == 0) begin
            $fatal(1, "Impossible d'ouvrir cluster_fixed_full_benchmark.txt");
        end

        // on jette l'entete
        ret = $fscanf(fd, "%f %f %f", scale, xmin, ymin);
        addr_file = 0;

        while (addr_file < NB_POINTS) begin

            ret = $fscanf(fd, "%d %d", xf, yf);

            if (ret != 2)
                break;

            write_memory_coord_b1(addr_file[ADDR_W-1:0], xf[15:0], yf[15:0]);
            write_memory_coord_b2(addr_file[ADDR_W-1:0], xf[15:0], yf[15:0]);

            addr_file++;
        end

        $fclose(fd);

        $display("%0d points chargés depuis cluster_fixed_full_benchmark.txt", addr_file);
        
        @(posedge clk);
        for (int i = 0; i < NB_POINTS; i++) begin
            read_memory_coord(i);
        end
        #10;
        $display("\n=== Fin de la simulation ===");
        $finish;
        
        // lancement calcul
        control_mem_coord_load_b1 = 1;
        control_mem_coord_load_b2 = 1;
        start = 1;
        @(posedge clk);
        start = 0;

        // attente de fin du calcul
        wait (done);

        @(posedge clk);
        for (int i = 0; i < NB_POINTS; i++) begin
            read_memory_cluster(i);
        end

        fd_cluster = $fopen("resultats.txt", "w");
        fd         = $fopen("cluster_fixed_full_benchmark.txt", "r");

        if (fd_cluster == 0) begin
            $display("Erreur : impossible d'ouvrir le fichier");
            $finish;
        end
        if (fd == 0) begin
            $fatal(1, "Impossible d'ouvrir cluster_fixed_full_benchmark.txt");
        end


        ret = $fscanf(fd, "%f %f %f", scale, xmin, ymin);

        if (ret != 3) begin
            $fatal(1, "Erreur lecture en-tête : scale/xmin/ymin");
        end

        $display("scale=%f xmin=%f ymin=%f", scale, xmin, ymin);

        addr_file = 0;
        while (addr_file < NB_POINTS) begin

            ret = $fscanf(fd, "%d %d", xf, yf);

            if (ret != 2)
                break;

            xf_real = (xf / 256.0) / scale + xmin;
            yf_real = (yf / 256.0) / scale + ymin;
            $fwrite(fd_cluster, "%f %f ", xf_real, yf_real);
            save_memory_cluster(addr_file);

            addr_file++;
        end

        $fclose(fd);
        $fclose(fd_cluster);


        #10;
        $display("\n=== Fin de la simulation ===");
        $finish;
    end



endmodule
