

module norm_entropy_grad_tb #(
    parameter int NB_POINTS    = 100,           // nombre de points stockés en dur, prochainement chargé au début du calcul <= 2**ADDR_W
    parameter int COORD_W      = 16,           // largeur des coordonnees, fixed-point SIGNE
    parameter int ADDR_W       = 7,           // largeur des adresses P_ij
    parameter int P_IJ_W       = 16,           // largeur des P_ij, fixed-point SIGNE
    parameter int ADDR_P_IJ_W  = 7,           // largeur des adresses P_ij
    parameter int ADDR_LUT_INV = 10,           // largeur des adresses LUT exp
    parameter int STEP_W       = 6,           // largeur du compteur d'iteration (max_iter=50 -> 6 bits suffisent)
    parameter int K_W          = 16,          // largeur de la constante K_step precalculee (signee, negative)
    parameter int D2_W         = 2 * COORD_W // dx*dx et dy*dy : produit de deux signed COORD_W bits -> 2*COORD_W bits
	);

    logic       clk;
    logic       rst_n;

    // --- Port BRAM point coord ---
    logic [ADDR_W-1:0]  addr_coord;
    logic [COORD_W-1:0] coord_X;
    logic [COORD_W-1:0] coord_Y;

    logic              control_mem_coord;
    logic [ADDR_W-1:0] addr_tb_coord;
    logic [ADDR_W-1:0] addr_compute_coord;


    // --- Port BRAM P_ij ---
    logic [ADDR_P_IJ_W-1:0]  addr_P_ij;
    logic [P_IJ_W-1:0]      P_ij;

    logic              control_mem_P_ij;
    logic [ADDR_P_IJ_W-1:0] addr_tb_P_ij;
    logic [ADDR_P_IJ_W-1:0] addr_compute_P_ij;


    // --- Port LUT inv (inv[index = mantissa]) ---
    logic [ADDR_LUT_INV-1:0] index_LUT_inv;
    logic [COORD_W-1:0]      result_inv;

	// --- Sortie vers la mémoire d'acutalisation des coord *** ---
    logic [31:0]            mult_act_X;
    logic [31:0]            mult_act_Y;
    logic [ADDR_P_IJ_W-1:0] addr_act;
    logic                   valid_out;

    logic [31:0]       sum_row_P;
    logic [ADDR_W-1:0] out_i;           // permet de savoir le numéro de la ligne
    logic              valid_sum_row_P;
    
    logic [31:0] entropy;
    logic        valid_entropy;

    logic done;

    // DUT
    norm_entropy_grad #(
        .NB_POINTS    (NB_POINTS),
        .COORD_W      (COORD_W),
        .ADDR_W       (ADDR_W),

        .P_IJ_W       (P_IJ_W),
        .ADDR_P_IJ_W  (ADDR_P_IJ_W),
        .ADDR_LUT_INV (ADDR_LUT_INV),
        
        .STEP_W (STEP_W),
        .K_W    (K_W),
        .D2_W   (D2_W)
    ) dut_compute (
        .clk(clk),
        .rst_n(rst_n),

        .addr(addr_compute_coord),
        .coord_X(coord_X),
        .coord_Y(coord_Y),
        
        .addr_P_ij(addr_compute_P_ij),
        .P_ij(P_ij),

        .index_LUT_inv(index_LUT_inv),
        .result_inv(result_inv),

        .mult_act_X(mult_act_X),
        .mult_act_Y(mult_act_Y),
        .addr_act(addr_act),
        .valid_out(valid_out),

        .sum_row_P(sum_row_P),
        .out_i(out_i),
        .valid_sum_row_P(valid_sum_row_P),

        .entropy(entropy),
        .valid_entropy(valid_entropy),

        .done(done)
    );

    // memory access coord
    logic       we_coord;
    logic [COORD_W-1:0] data_in1_coord;
    logic [COORD_W-1:0] data_in2_coord;
    

    // DUT memory coord
    memory_dual_port #(
        .ADDR_W (ADDR_W),
        .DATA_W (COORD_W)
    ) memory_coord (
        .clk(clk),
        .rst_n(rst_n),

        .we(we_coord),
        .addr(addr_coord),
        .data_in1(data_in1_coord),
        .data_in2(data_in2_coord),

        .data_out1(coord_X),
        .data_out2(coord_Y)
    );
    

    // memory access P_ij
    logic              we_P_ij;
    logic [P_IJ_W-1:0] data_in_P_ij;
    // DUT memory P_ij
    memory_dual_port #(
        .ADDR_W (ADDR_P_IJ_W),
        .DATA_W (P_IJ_W)
    ) memory_P_ij (
        .clk(clk),
        .rst_n(rst_n),

        .we(we_P_ij),
        .addr(addr_P_ij),
        .data_in1(data_in_P_ij),
        .data_in2(),

        .data_out1(P_ij),
        .data_out2()
    );

    // DUT inv_LUT
    inv_LUT inv_LUT (
        .clk(clk),
        .rst_n(rst_n),

        .index(index_LUT_inv),
        .result_inv(result_inv)
    );

    task display_state(input string label);
    $display("[%0t] %-22s | coord_X=%08b coord_Y=%08b addr_coord=%08b",
        $time, label, coord_X, coord_Y, addr_coord);
    endtask

    // write memory task coord
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

    // write memory task P_ij
    task write_memory_P_ij(input logic [ADDR_P_IJ_W-1:0] addr_task, input logic [15:0] data_in1_task, input logic [15:0] data_in2_task);
        control_mem_P_ij = 0;
        we_P_ij          = 1;
        addr_tb_P_ij     = addr_task;
        data_in_P_ij    = data_in1_task;
        //data_in2_P_ij    = data_in2_task;

        @(posedge clk);

        we_P_ij          = 0;
        control_mem_P_ij = 1;
    endtask

    task read_memory_coord(input logic [ADDR_W-1:0] addr_task);
        control_mem_coord = 0;
        addr_tb_coord = addr_task;
        @(posedge clk);
        $display("lecture mémoire addr_coord=%08b coord_X=%08b coord_Y=%08b", addr_coord, coord_X, coord_Y);
        control_mem_coord = 1;
    endtask

    task read_memory_P_ij(input logic [ADDR_P_IJ_W-1:0] addr_task);
        control_mem_P_ij = 0;
        addr_tb_P_ij = addr_task;
        @(posedge clk);
        $display("lecture mémoire addr_P_ij=%08b P_ij=%08b", addr_P_ij, P_ij);
        control_mem_P_ij = 1;
    endtask


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
                $display("[%0t] Calcul terminé", $time);
                break;
            end
        end
    endtask

    always #5 clk = ~clk;


    always_comb begin
        addr_coord = (control_mem_coord == 1) ? addr_compute_coord : addr_tb_coord;
    end

    always_comb begin
        addr_P_ij = (control_mem_P_ij == 1) ? addr_compute_P_ij : addr_tb_P_ij;
    end

    integer fd_coord;
    integer fd_P_ij;
    int ret;
    int xf, yf;
    int Pij;
    int addr_file;
    initial begin


        $display("\n=== début de la simulation ===");

        // init
        clk         =  0;
        rst_n       =  0;
        we_coord          =  0;
        addr_tb_coord     = '0;
        control_mem_coord =  0;
        we_P_ij          =  0;
        addr_tb_P_ij     = '0;
        control_mem_P_ij =  0;
        out_i =  0;

        valid_sum_row_P  =  0;

        fork
            monitor_results();
        join_none

        @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        
        // Écriture des vecteurs X_f et Y_f en mémoire (100 points)
        fd_coord = $fopen("cluster_fixed.txt", "r");

        if (fd_coord == 0) begin
            $fatal(1, "Impossible d'ouvrir cluster_fixed.txt");
        end

        addr_file = 0;

        while (addr_file < 100) begin

            ret = $fscanf(fd_coord, "%d %d", xf, yf);

            if (ret != 2)
                break;

            write_memory_coord(addr_file[ADDR_W-1:0], xf[15:0], yf[15:0]);

            //$display("point[%0d] Xf=%0d Yf=%0d", addr_file, xf, yf);

            addr_file++;
        end

        $fclose(fd_coord);

        $display("%0d points chargés depuis cluster_fixed.txt", addr_file);
        
        // Écriture des vecteurs X_f et Y_f en mémoire (100 points)
        fd_P_ij = $fopen("P_ij_fixed.txt", "r");

        if (fd_P_ij == 0) begin
            $fatal(1, "Impossible d'ouvrir P_ij_fixed.txt");
        end

        addr_file = 0;

        while (addr_file < 100) begin

            ret = $fscanf(fd_P_ij, "%d", Pij);

            if (ret != 1)
                break;

            write_memory_P_ij(addr_file[ADDR_P_IJ_W-1:0], Pij[15:0], '0);

            //$display("point[%0d] Pij=%0d, addr_file, Pij);

            addr_file++;
        end

        $fclose(fd_P_ij);

        $display("%0d points chargés depuis P_ij_fixed.txt", addr_file);


        
        // lancement calcul
        control_mem_coord = 1;
        control_mem_P_ij  = 1;

        out_i =  1;
        sum_row_P = 32'd1555704;
        valid_sum_row_P = 1;

        @(posedge clk);

        valid_sum_row_P = 0;
        // attente de fin du calcul
        wait(done);

        #10;
        $display("\n=== Fin de la simulation ===");
        $finish;
    end

endmodule