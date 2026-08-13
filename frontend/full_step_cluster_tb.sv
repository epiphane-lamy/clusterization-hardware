

module full_step_cluster_tb #(
    parameter int NB_POINTS    = 1100,              // nombre de points stockés en dur, prochainement chargé au début du calcul <= 2**ADDR_W
    parameter int NB_ITER      = 50,                // nombre d'itérations

    parameter int COORD_W      = 16,                // largeur des coordonnees
    parameter int ADDR_W       = $clog2(NB_POINTS), // largeur des adresses points Xf

    parameter int P_IJ_W       = 16,                // largeur des P_ij, fixed-point SIGNE
    parameter int ADDR_P_IJ_W  = $clog2(NB_POINTS), // largeur des adresses P_ij
    parameter int SUM_ROW_P_W  = 32,                // largeur de sum_row_P

    parameter int ADDR_LUT_INV = 10,                // largeur des adresses LUT exp
    parameter int ADDR_LUT_EXP = 14,                // largeur des adresses LUT exp

    parameter int ACT_W        = 32,                // largeur des valeurs d'actualisation, fixed-point SIGNE

    parameter int ENTH_W       = 32,                // largeur des valeurs d'enthropie, fixed-point SIGNE

    parameter int STEP_W       = $clog2(NB_ITER),   // largeur du compteur d'iteration (max_iter=50 -> 6 bits suffisent)
    parameter int K_W          = 16,                // largeur de la constante K_step precalculee (signee, negative)
    parameter int SQ_W         = 2 * COORD_W,       // dx*dx et dy*dy : produit de deux signed COORD_W bits -> 2*COORD_W bits
    parameter int D2_W         = SQ_W + 1,          // D2 = x2 + y2
    parameter int TOL          = 422144877          // cst TOL
	);


    typedef struct packed {

        logic               we;
        logic [ADDR_W-1:0]  addr;

        logic [COORD_W-1:0] data_in1;
        logic [COORD_W-1:0] data_in2;

    } coord_mem_port_t;

    typedef enum logic [1:0] {
        OWNER_TB,
        OWNER_COMPUTE,
        OWNER_ACT,
        OWNER_CLUSTER_ASSIGN
    } coord_owner_t;

    // petite fonction de mux réutilisable pour les deux mémoires
    function automatic coord_mem_port_t mux_coord_port(
        input coord_owner_t     owner,
        input coord_mem_port_t  tb,
        input coord_mem_port_t  compute,
        input coord_mem_port_t  act,
        input coord_mem_port_t  cluster
    );
        unique case (owner)
            OWNER_TB:             mux_coord_port = tb;
            OWNER_COMPUTE:        mux_coord_port = compute;
            OWNER_ACT:            mux_coord_port = act;
            OWNER_CLUSTER_ASSIGN: mux_coord_port = cluster;
            default:       mux_coord_port = tb;
        endcase
    endfunction



    logic       clk;
    logic       rst_n;

    // -------------------------------------------------------------------
    // Déclaration des ports mémoire coord_b1
    // -------------------------------------------------------------------
    coord_owner_t     owner_b1;
    coord_mem_port_t  port_tb_b1, port_compute_b1, port_act_b1, port_cluster_b1, port_mux_b1;

    // -------------------------------------------------------------------
    // Déclaration des ports mémoire coord_b2
    // -------------------------------------------------------------------
    coord_owner_t     owner_b2;
    coord_mem_port_t  port_tb_b2, port_compute_b2, port_act_b2, port_cluster_b2, port_mux_b2;
    
    // -------------------------------------------------------------------
    // Déclaration bloc exp et annexes
    // -------------------------------------------------------------------
    logic              start_b1;     // lance le balayage complet d'un step
    logic              start_tb_b1;
    logic              start_compute_b1;
    logic [STEP_W-1:0] step_idx;  // index de l'iteration courante

    // --- Port BRAM point (adresse incrementee chaque cycle) ---
    
    logic [ADDR_W-1:0] addr_coord_b1;

    logic              control_mem_coord_b1;
    logic [ADDR_W-1:0] addr_coord_tb_b1;
    logic [ADDR_W-1:0] addr_coord_compute_b1;

    logic [COORD_W-1:0] coord_X_b1;
    logic [COORD_W-1:0] coord_Y_b1;

    logic signed [ADDR_LUT_EXP-1:0] index_LUT_exp;
    logic signed [COORD_W-1:0] result_exp;

	// --- Sortie vers le bloc exponentiel ---
    logic [COORD_W-1:0] P_ij_b1;   // D2_ij * K_step
    logic [ADDR_W-1:0]          out_i_b1;
    logic [ADDR_W-1:0]          out_j_b1;
    logic                       valid_out_b1;

    logic [SUM_ROW_P_W-1:0] sum_row_P;
    logic        valid_sum_row_P;


    logic credit_avail;
    logic done_b1;

    // DUT bloc exp
    dist_mat_arg_exp #(
        .NB_POINTS (NB_POINTS),
        .COORD_W   (COORD_W),
        .ADDR_W    (ADDR_W),
        .ADDR_LUT_EXP    (ADDR_LUT_EXP),
        .STEP_W    (STEP_W),
        .K_W       (K_W)
    ) bloc_exp (
        .clk(clk),
        .rst_n(rst_n),

        .start(start_b1),
        .step_idx(step_idx),

        .addr(addr_coord_compute_b1),
        .coord_X(coord_X_b1),
        .coord_Y(coord_Y_b1),

        .index_LUT_exp(index_LUT_exp),
        .result_exp(result_exp),

        .P_ij(P_ij_b1),
        .out_i(out_i_b1),
        .out_j(out_j_b1),
        .valid_out(valid_out_b1),

        .sum_row_P(sum_row_P),
        .valid_sum_row_P(valid_sum_row_P),

        .credit_avail(credit_avail),
        .done(done_b1)
    );

    // memory access
    logic               we_coord_b1;
    logic               we_coord_tb_b1;
    logic [COORD_W-1:0] data_in1_coord_b1;
    logic [COORD_W-1:0] data_in2_coord_b1;
    logic [COORD_W-1:0] data_in1_coord_tb_b1;
    logic [COORD_W-1:0] data_in2_coord_tb_b1;
    

    // DUT memory coord points
    memory_dual_port #(
        .ADDR_W (ADDR_W),
        .DATA_W (COORD_W)
    ) memory_coord_b1 (
        .clk(clk),
        .rst_n(rst_n),

        .we(we_coord_b1),
        .addr(addr_coord_b1),
        .data_in1(data_in1_coord_b1),
        .data_in2(data_in2_coord_b1),

        .data_out1(coord_X_b1),
        .data_out2(coord_Y_b1)
    );

    // DUT exp_LUT
    exp_LUT exp_LUT (
        .clk(clk),
        .rst_n(rst_n),

        .index(index_LUT_exp),
        .result_exp(result_exp)
    );


    // -------------------------------------------------------------------
    // Déclaration bloc grad et annexes
    // -------------------------------------------------------------------
    logic [ADDR_W-1:0]  addr_coord_b2;
    logic [COORD_W-1:0] coord_X_b2;
    logic [COORD_W-1:0] coord_Y_b2;

    logic              control_mem_coord_b2;
    logic [ADDR_W-1:0] addr_coord_tb_b2;
    logic [ADDR_W-1:0] addr_coord_compute_b2;


    // --- Port BRAM P_ij ---
    logic [ADDR_P_IJ_W-1:0]  addr_P_ij_b2;
    logic [P_IJ_W-1:0]      P_ij_b2;


    // --- Port LUT inv (inv[index = mantissa]) ---
    logic [ADDR_LUT_INV-1:0] index_LUT_inv;
    logic [COORD_W-1:0]      result_inv;

	// --- Sortie vers la mémoire d'acutalisation des coord *** ---
    logic signed [ACT_W-1:0] mult_act_X;
    logic signed [ACT_W-1:0] mult_act_Y;
    logic [ADDR_P_IJ_W-1:0]  addr_act;
    logic [ADDR_P_IJ_W-1:0]  addr_act_b2;
    logic                    valid_out_b2;
    
    logic [ENTH_W-1:0] entropy;
    logic        valid_entropy;

    logic done_b2;

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
    ) bloc_grad (
        .clk(clk),
        .rst_n(rst_n),

        .addr(addr_coord_compute_b2),
        .coord_X(coord_X_b2),
        .coord_Y(coord_Y_b2),
        
        .addr_P_ij(addr_P_ij_b2),
        .P_ij(P_ij_b2),

        .index_LUT_inv(index_LUT_inv),
        .result_inv(result_inv),

        .mult_act_X(mult_act_X),
        .mult_act_Y(mult_act_Y),
        .addr_act(addr_act_b2),
        .valid_out(valid_out_b2),

        .sum_row_P(sum_row_P),
        .out_i(out_i_b1),
        .valid_sum_row_P(valid_sum_row_P),

        .entropy(entropy),
        .valid_entropy(valid_entropy),

        .done(done_b2)
    );

    logic               we_coord_b2;
    logic               we_coord_tb_b2;
    logic [COORD_W-1:0] data_in1_coord_b2;
    logic [COORD_W-1:0] data_in2_coord_b2;
    logic [COORD_W-1:0] data_in1_coord_tb_b2;
    logic [COORD_W-1:0] data_in2_coord_tb_b2;
    

    // Memory coord pour le bloc grad
    memory_dual_port #(
        .ADDR_W (ADDR_W),
        .DATA_W (COORD_W)
    ) memory_coord_b2 (
        .clk(clk),
        .rst_n(rst_n),

        .we(we_coord_b2),
        .addr(addr_coord_b2),
        .data_in1(data_in1_coord_b2),
        .data_in2(data_in2_coord_b2),

        .data_out1(coord_X_b2),
        .data_out2(coord_Y_b2)
    );
    
    // DUT inv_LUT
    inv_LUT inv_LUT (
        .clk(clk),
        .rst_n(rst_n),

        .index(index_LUT_inv),
        .result_inv(result_inv)
    );


    // -------------------------------------------------------------------
    // Déclaration bloc ping_pong_arbitrer + doubles mémoires P_ij
    // -------------------------------------------------------------------

    logic                   we_P_ij_A;
    logic [ADDR_P_IJ_W-1:0] addr_P_ij_A;
    logic [P_IJ_W-1:0]      data_in_P_ij_A;
    logic [P_IJ_W-1:0]      P_ij_A;

    // memory P_ij bloc A
    memory_single_port #(
        .ADDR_W (ADDR_P_IJ_W),
        .DATA_W (P_IJ_W)
    ) memory_P_ij_A (
        .clk(clk),
        .rst_n(rst_n),

        .we(we_P_ij_A),
        .addr(addr_P_ij_A),
        .data_in(data_in_P_ij_A),

        .data_out(P_ij_A)
    );


    logic                   we_P_ij_B;
    logic [ADDR_P_IJ_W-1:0] addr_P_ij_B;
    logic [P_IJ_W-1:0]      data_in_P_ij_B;
    logic [P_IJ_W-1:0]      P_ij_B;

    // memory P_ij bloc B
    memory_single_port #(
        .ADDR_W (ADDR_P_IJ_W),
        .DATA_W (P_IJ_W)
    ) memory_P_ij (
        .clk(clk),
        .rst_n(rst_n),

        .we(we_P_ij_B),
        .addr(addr_P_ij_B),
        .data_in(data_in_P_ij_B),

        .data_out(P_ij_B)
    );

        // ping_pong_arbitrer
    ping_pong_arbitrer #(
        .COORD_W (COORD_W),
        .ADDR_W (ADDR_W)
    ) memory_P_ij_arbitrer (
        .clk(clk),
        .rst_n(rst_n),

        .valid_p_ij_exp(valid_out_b1),   // pulse par élément, qualifie l'écriture (= valid_out de dist_mat_arg_exp)
        .out_i_exp(out_i_b1),     // pulse de fin de ligne (= valid_sum_row_P), pour credit/config
        .line_done_grad(done_b2), // pulse de fin de ligne côté grad (= done)

        // addr P_ij + P_ij à écrire (bloc exp)
        .addr_P_ij_w(out_j_b1),
        .P_ij_w(P_ij_b1),

        // addr P_ij + P_ij à écrire (bloc grad)
        .addr_P_ij_r(addr_P_ij_b2),
        .P_ij_r(P_ij_b2),

        // BRAM P_ij A
        .addr_A(addr_P_ij_A),
        .we_A(we_P_ij_A),
        .w_data_A(data_in_P_ij_A),
        .r_data_A(P_ij_A),

        // BRAM P_ij B
        .addr_B(addr_P_ij_B),
        .we_B(we_P_ij_B),
        .w_data_B(data_in_P_ij_B),
        .r_data_B(P_ij_B),

        .credit_avail(credit_avail)
    );


    // -------------------------------------------------------------------
    // Déclaration bloc d'actualisation + mémoire actualisation
    // -------------------------------------------------------------------

    logic              start_b3;     // lance le balayage complet d'un step

    // --- Port BRAM point (adresse incrementee chaque cycle) ---

    logic [ADDR_W-1:0] addr_coord_b3;

	logic              we_coord_b3;


    logic [COORD_W-1:0] coord_X_act;
    logic [COORD_W-1:0] coord_Y_act;

    // --- Port BRAM mult_act (adresse incrementee chaque cycle) ---
    logic               control_mem_b3;
    logic [ADDR_W-1:0]  addr_act_b3;
    logic signed [ACT_W-1:0] mult_act_X_mem;
    logic signed [ACT_W-1:0] mult_act_Y_mem;

    logic done_act;

    // DUT
    act_coord #(
        .NB_POINTS (NB_POINTS),
        .COORD_W   (COORD_W),
        .ADDR_W    (ADDR_W),
        .ACT_W     (ACT_W)
    ) dut_compute (
        .clk(clk),
        .rst_n(rst_n),

        .start(start_b3),

        .addr_coord(addr_coord_b3),
        .we_coord(we_coord_b3),

        .coord_X(coord_X_b1),
        .coord_Y(coord_Y_b1),

        .coord_X_act(coord_X_act),
        .coord_Y_act(coord_Y_act),

        .addr_act(addr_act_b3),
        .mult_act_X(mult_act_X_mem),
        .mult_act_Y(mult_act_Y_mem),

        .done(done_act)
    );

    // memory mult_act
    memory_dual_port #(
        .ADDR_W (ADDR_W),
        .DATA_W (ACT_W)
    ) memory_act (
        .clk(clk),
        .rst_n(rst_n),

        .we(valid_out_b2),
        .addr(addr_act),
        .data_in1(mult_act_X),
        .data_in2(mult_act_Y),

        .data_out1(mult_act_X_mem),
        .data_out2(mult_act_Y_mem)
    );

    // -------------------------------------------------------------------
    // Déclaration bloc de recherche de clusters + mémoire cluster
    // -------------------------------------------------------------------

    logic start_b4;     // lance le bloc cluster_assign

    // --- Port BRAM point (adresse incrementee chaque cycle) ---
    logic [ADDR_W-1:0] addr_coord_compute_b4;
    logic [COORD_W-1:0] coord_X_b4;
    logic [COORD_W-1:0] coord_Y_b4;

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

        .addr_coord    (addr_coord_compute_b4),
        .coord_X       (coord_X_b1),
        .coord_Y       (coord_Y_b1),

        .addr_cluster  (addr_cluster_compute),
        .we_cluster    (we_cluster),
        .cluster_in    (cluster_in),
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


    logic [ADDR_W-1:0] cnt_done_b2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_b3    <= 1'b0;
            cnt_done_b2 <= '0;
        end else begin
            start_b3 <= 1'b0;
            if (done_b2) begin
                if (cnt_done_b2 == NB_POINTS - 1) begin
                    start_b3    <= 1'b1;
                    cnt_done_b2 <= '0;
                end else begin
                    start_b3 <= 1'b0;
                    cnt_done_b2++;
                end
            end
        end
    end



    // if start_b3 alors le bloc 3 fait ses calculs -> basculement des droits d'ecriture et de lecture sur 
    // les 2 memoires coord pour qu'il les modifie et aussi lui donner acces a la memoire act en lecture

    // une fois qu'il a terminé alors son signal done_b3 peut etre utilisé pour le relancer un calcul sur une step
    // via l'input start_b1 et permet en même temps de rebasculer les droits w/r sur les blocs exp et grad
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            control_mem_b3 <= 1'b0;
        end else begin
            if (start_b3) control_mem_b3 <= 1'b1;
            if (done_act) control_mem_b3 <= 1'b0;
        end
    end

    assign addr_act = (control_mem_b3) ? addr_act_b3 : addr_act_b2;


    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            step_idx <= '0;
            start_compute_b1 <= 1'b0;
        end else begin
            start_compute_b1 <= 1'b0;
            if (done_act && (step_idx != NB_ITER)) begin
                step_idx++;
                start_compute_b1 <= 1'b1;
            end
        end
    end

    assign start_b1 = start_tb_b1 || start_compute_b1;

    logic all_steps_done;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            all_steps_done <= 1'b0;
            start_b4       <= 1'b0;
        end else begin
            start_b4 <= 1'b0; // défaut : pulse d'un seul cycle
            if (done_act && (step_idx == NB_ITER) && !all_steps_done) begin
                all_steps_done <= 1'b1;
                start_b4       <= 1'b1; // pulse déclenché une seule fois, à la transition
            end
        end
    end



    always_comb begin
        if (!control_mem_coord_b1) owner_b1 = OWNER_TB;
        else if (control_mem_b3)   owner_b1 = OWNER_ACT;
        else if (all_steps_done)   owner_b1 = OWNER_CLUSTER_ASSIGN;
        else                       owner_b1 = OWNER_COMPUTE;
    end

    assign port_tb_b1.we       = we_coord_tb_b1;
    assign port_tb_b1.addr     = addr_coord_tb_b1;
    assign port_tb_b1.data_in1 = data_in1_coord_tb_b1;
    assign port_tb_b1.data_in2 = data_in2_coord_tb_b1;

    assign port_compute_b1.we       = 1'b0;               // bloc_exp ne fait que lire
    assign port_compute_b1.addr     = addr_coord_compute_b1;
    assign port_compute_b1.data_in1 = '0;
    assign port_compute_b1.data_in2 = '0;

    assign port_act_b1.we       = we_coord_b3;
    assign port_act_b1.addr     = addr_coord_b3;
    assign port_act_b1.data_in1 = coord_X_act;
    assign port_act_b1.data_in2 = coord_Y_act;

    assign port_cluster_b1.we       = 1'b0;
    assign port_cluster_b1.addr     = addr_coord_compute_b4;
    assign port_cluster_b1.data_in1 = '0;
    assign port_cluster_b1.data_in2 = '0;

    assign port_mux_b1 = mux_coord_port(owner_b1, port_tb_b1, port_compute_b1, port_act_b1, port_cluster_b1);

    assign we_coord_b1       = port_mux_b1.we;
    assign addr_coord_b1     = port_mux_b1.addr;
    assign data_in1_coord_b1 = port_mux_b1.data_in1;
    assign data_in2_coord_b1 = port_mux_b1.data_in2;



    always_comb begin
        if (!control_mem_coord_b2) owner_b2 = OWNER_TB;
        else if (control_mem_b3)   owner_b2 = OWNER_ACT;
        else                       owner_b2 = OWNER_COMPUTE;
    end

    assign port_tb_b2.we       = we_coord_tb_b2;
    assign port_tb_b2.addr     = addr_coord_tb_b2;
    assign port_tb_b2.data_in1 = data_in1_coord_tb_b2;
    assign port_tb_b2.data_in2 = data_in2_coord_tb_b2;

    assign port_compute_b2.we       = 1'b0;               // bloc_grad ne fait que lire
    assign port_compute_b2.addr     = addr_coord_compute_b2;
    assign port_compute_b2.data_in1 = '0;
    assign port_compute_b2.data_in2 = '0;

    assign port_act_b2.we       = we_coord_b3;
    assign port_act_b2.addr     = addr_coord_b3;
    assign port_act_b2.data_in1 = coord_X_act;
    assign port_act_b2.data_in2 = coord_Y_act;

    assign port_mux_b2 = mux_coord_port(owner_b2, port_tb_b2, port_compute_b2, port_act_b2, port_cluster_b2);

    assign we_coord_b2       = port_mux_b2.we;
    assign addr_coord_b2     = port_mux_b2.addr;
    assign data_in1_coord_b2 = port_mux_b2.data_in1;
    assign data_in2_coord_b2 = port_mux_b2.data_in2;



    assign addr_cluster = (control_mem_cluster) ? addr_cluster_compute : addr_cluster_tb;

    // -------------------------------------------------------------------
    // Tasks write/read memory coord bloc exp (1) et bloc grad (2)
    // -------------------------------------------------------------------
    task write_memory_coord_b1(input logic [ADDR_W-1:0] addr_task, input logic [15:0] data_in1_task, input logic [15:0] data_in2_task);
        control_mem_coord_b1   = 0;
        we_coord_tb_b1      = 1;
        addr_coord_tb_b1 = addr_task;
        data_in1_coord_tb_b1      = data_in1_task;
        data_in2_coord_tb_b1      = data_in2_task;

        @(posedge clk);

        we_coord_tb_b1    = 0;
        control_mem_coord_b1 = 1;
    endtask
    
    task write_memory_coord_b2(input logic [ADDR_W-1:0] addr_task, input logic [15:0] data_in1_task, input logic [15:0] data_in2_task);
        control_mem_coord_b2 = 0;
        we_coord_tb_b2       = 1;
        addr_coord_tb_b2     = addr_task;
        data_in1_coord_tb_b2    = data_in1_task;
        data_in2_coord_tb_b2    = data_in2_task;

        @(posedge clk);

        we_coord_tb_b2       = 0;
        control_mem_coord_b2 = 1;
    endtask

    task read_memory_coord(input logic [ADDR_W-1:0] addr_task);
        control_mem_coord_b1 = 0;
        control_mem_coord_b2 = 0;
        addr_coord_tb_b1 = addr_task;
        addr_coord_tb_b2 = addr_task;
        @(posedge clk);
        $display("lecture mémoire addr_coord_b1=%0d coord_X_b1=%0d coord_Y_b1=%0d addr_coord_b2=%0d coord_X_b2=%0d coord_Y_b2=%0d",
        addr_coord_b1, coord_X_b1, coord_Y_b1, addr_coord_b2, coord_X_b2, coord_Y_b2);
        control_mem_coord_b1 = 1;
        control_mem_coord_b2 = 1;
    endtask

    task read_memory_cluster(input logic [ADDR_W-1:0] addr_task);
        control_mem_cluster = 0;
        addr_cluster_tb = addr_task;
        @(posedge clk);
        $display("lecture mémoire cluster cluster[%0d] = %0d",
        addr_cluster, cluster_in);
        control_mem_cluster = 1;
    endtask

    task save_memory_cluster(input logic [ADDR_W-1:0] addr_task);
        control_mem_cluster = 0;
        addr_cluster_tb = addr_task;
        @(posedge clk);
        $display("lecture mémoire cluster cluster[%0d] = %0d",
        addr_cluster, cluster_in);
        $fdisplay(fd_cluster, "%0d", cluster_in);
        control_mem_cluster = 1;
    endtask

    // -------------------------------------------------------------------
    // Task automatic pour afficher les résultats
    // -------------------------------------------------------------------
    task automatic monitor_results();
        int result_count = 0;

        forever begin
            @(posedge clk);

            /*
            if (valid_sum_row_P) begin
                $display("[%0t] RESULT sum_row_P i=%0d j=%0d sum_row_P=%0d",
                        $time,
                        out_i_b1,
                        out_j_b1,
                        sum_row_P);
            end*/
            
            if (start_compute_b1) begin
                $display("\n=== step_idx = %0d ===", step_idx);
            end
            /*
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

            if (we_coord_b3) begin
                $display("[%0t] RESULT coord_act coord_X_act=%0d coord_Y_act=%0d",
                        $time,
                        coord_X_act,
                        coord_Y_act);
            end*/
        end
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
        clk                  =  0;
        rst_n                =  0;
        we_coord_tb_b1          =  0;
        we_coord_tb_b2          =  0;
        addr_coord_tb_b1     = '0;
        addr_coord_tb_b2     = '0;
        control_mem_coord_b1 =  0;
        control_mem_coord_b2 =  0;
        control_mem_cluster  =  1;
        addr_cluster_tb      = '0;


        start_tb_b1       =  0;

        fork
            monitor_results();
        join_none

        @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        
        // Écriture des vecteurs X_f et Y_f en mémoire (100 points)
        fd = $fopen("cluster_fixed_full_benchmark.txt", "r");

        if (fd == 0) begin
            $fatal(1, "Impossible d'ouvrir cluster_fixed_full_benchmark.txt");
        end

        addr_file = 1;

        while (addr_file < NB_POINTS+1) begin

            ret = $fscanf(fd, "%d %d", xf, yf);

            if (ret != 2)
                break;

            write_memory_coord_b1(addr_file[ADDR_W-1:0], xf[15:0], yf[15:0]);
            write_memory_coord_b2(addr_file[ADDR_W-1:0], xf[15:0], yf[15:0]);

            //$display("point[%0d] Xf=%0d Yf=%0d", addr_file, xf, yf);

            addr_file++;
        end

        $fclose(fd);

        $display("\n%0d points chargés depuis cluster_fixed_full_benchmark.txt", NB_POINTS);



        
        // lancement calcul
        control_mem_coord_b1 = 1;
        control_mem_coord_b2 = 1;
        start_tb_b1 = 1;
        @(posedge clk);
        start_tb_b1 = 0;


        // attente de fin du calcul 2 premières lignes
        // wait (cnt_done_b2 == 3);
        //wait (done_act);
        //wait (step_idx == NB_ITER);
        wait (done_cluster);

        @(posedge clk);


        fd_cluster = $fopen("resultats.txt", "w");
        fd         = $fopen("cluster_fixed_full_benchmark.txt", "r");

        if (fd_cluster == 0) begin
            $display("Erreur : impossible d'ouvrir le fichier");
            $finish;
        end
        if (fd == 0) begin
            $fatal(1, "Impossible d'ouvrir cluster_fixed_full_benchmark.txt");
        end


        addr_file = 0;
        ret = $fscanf(fd, "%f %f %f", scale, xmin, ymin);
        addr_file++;

        addr_file = 1;
        while (addr_file < NB_POINTS+1) begin

            ret = $fscanf(fd, "%d %d", xf, yf);

            if (ret != 2)
                break;

            xf_real = (xf / 256.0) / scale + xmin;
            yf_real = (yf / 256.0) / scale + ymin;
            $fwrite(fd_cluster, "%f %f ", xf_real, yf_real);
            save_memory_cluster(addr_file-1);

            addr_file++;
        end

        $fclose(fd);
        $fclose(fd_cluster);


        #10;
        $display("\n=== Fin de la simulation ===");
        $finish;
    end



endmodule

/*
| addr_act | mult_act_X | mult_act_Y |
| -------- | ---------: | ---------: |
| 0        |        907 |       3285 |
| 1        |      -6667 |      -4866 |
| 2        |       2902 |       2163 |
| 3        |      -4607 |       1972 |
| 4        |      -5212 |       2942 |
| 5        |      -7389 |        702 |
| 6        |      -3344 |       1333 |
| 7        |       1482 |      -2270 |
| 8        |      -1996 |      -1928 |
| 9        |      -7740 |      -5253 |
| 10       |       -646 |      -3799 |
| 11       |       -567 |      -2138 |
| 12       |       -509 |      -1161 |
| 13       |        911 |      -1932 |
| 14       |      -2420 |       -369 |
| 15       |       3988 |       4677 |
| 16       |        -70 |      -4174 |
| 17       |       1440 |       3015 |
| 18       |        141 |       3386 |
| 19       |       -906 |      -5627 |
| 20       |      -3245 |      -4150 |
| 21       |      -5806 |      -7241 |
| 22       |      -4881 |      -4737 |
| 23       |      -5063 |      -7497 |
| 24       |      -2775 |      -9058 |
| 25       |      -6875 |      -6461 |
| 26       |      -2300 |        407 |
| 27       |      -3584 |        261 |
| 28       |      -1505 |      -4967 |
| 29       |       4436 |      -3021 |
| 30       |      -3869 |      -2623 |
| 31       |      -7651 |       1222 |
| 32       |       1812 |      -2995 |
| 33       |       2370 |      -3460 |
| 34       |        -15 |      -4842 |
| 35       |      -2589 |      -6201 |
| 36       |      -2312 |      -5014 |
| 37       |       1043 |      -7606 |
| 38       |      -3428 |      -2098 |
| 39       |       3660 |      -2573 |
| 40       |      -5183 |      -2989 |
| 41       |       1945 |      -5265 |
| 42       |      -1165 |      -3976 |
| 43       |      -2502 |      -8418 |
| 44       |       -327 |      -1525 |
| 45       |      -2287 |       -165 |
| 46       |      -2940 |       1936 |
| 47       |        707 |      -4498 |
| 48       |       3062 |       1813 |
| 49       |      -6442 |      -1457 |
| 50       |      -3696 |       4892 |
| 51       |      -3568 |        259 |
| 52       |       2059 |       2606 |
| 53       |      -4685 |      -2304 |
| 54       |      -5537 |      -5660 |
| 55       |        542 |       3459 |
| 56       |      -5068 |       3948 |
| 57       |      -2238 |      -4687 |
| 58       |       1033 |      -2268 |
| 59       |       1605 |      -2930 |
| 60       |      -1569 |      -4777 |
| 61       |      -1227 |       -892 |
| 62       |       3594 |      -2422 |
| 63       |       1892 |      -3691 |
| 64       |      -3777 |      -3507 |
| 65       |        606 |      -4633 |
| 66       |      -4456 |      -4901 |
| 67       |       3645 |      -6053 |
| 68       |      -1598 |      -4398 |
| 69       |      -1737 |       -574 |
| 70       |      -2853 |        669 |
| 71       |      -7418 |      -5239 |
| 72       |       1211 |      -6545 |
| 73       |      -4849 |      -2719 |
| 74       |      -1587 |        499 |
| 75       |      -1421 |       3728 |
| 76       |      -3264 |       -177 |
| 77       |      -1314 |       -570 |
| 78       |       4385 |         95 |
| 79       |       3158 |      -2729 |
| 80       |       2816 |       2003 |
| 81       |      -2857 |       1590 |
| 82       |      -8552 |      -5034 |
| 83       |      -4720 |        751 |
| 84       |      -6291 |      -3894 |
| 85       |      -3444 |       -114 |
| 86       |      -7770 |       -368 |
| 87       |      -1532 |      -7914 |
| 88       |      -1602 |      -6415 |
| 89       |      -1052 |       3495 |
| 90       |       -758 |      -1493 |
| 91       |      -2348 |      -2404 |
| 92       |      -1017 |      -3834 |
| 93       |       1261 |      -5449 |
| 94       |        838 |      -1744 |
| 95       |      -7437 |       1188 |
| 96       |      -4181 |      -2548 |
| 97       |        547 |      -1433 |
| 98       |      -4735 |        279 |
| 99       |       1502 |      -3590 |
*/