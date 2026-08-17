

module clusterization #(
    parameter int NB_POINTS    = 1250,         // nombre de points stockés en dur, prochainement chargé au début du calcul <= 2**ADDR_W
    parameter int NB_ITER      = 50,          // nombre d'itérations
    parameter int COORD_W      = 16,          // largeur des coordonnees
    parameter int ADDR_W       = $clog2(NB_POINTS),           // largeur des adresses points Xf
    parameter int P_IJ_W       = 16,          // largeur des P_ij, fixed-point SIGNE
    parameter int ADDR_P_IJ_W  = $clog2(NB_POINTS),           // largeur des adresses P_ij
    parameter int ADDR_LUT_INV = 10,          // largeur des adresses LUT exp
    parameter int ADDR_LUT_EXP = 14,          // largeur des adresses LUT exp
    parameter int ACT_W        = 32,          // largeur des valeurs d'actualisation, fixed-point SIGNE
    parameter int STEP_W       = 6,           // largeur du compteur d'iteration (max_iter=50 -> 6 bits suffisent)
    parameter int K_W          = 16,          // largeur de la constante K_step precalculee (signee, negative)
    parameter int SQ_W         = 2 * COORD_W, // dx*dx et dy*dy : produit de deux signed COORD_W bits -> 2*COORD_W bits
    parameter int D2_W         = SQ_W + 1,    // D2 = x2 + y2
    parameter int TOL          = 422144877    // cst TOL
	)(
    input  logic              clk,
    input  logic              rst_n,

    input  logic              start, // lance le clustering

    // --- Port BRAM point (Xf / Yf) ---
    input  logic              control_mem_coord_load_b1,

    input  logic               we_coord_load_b1,
    input  logic [ADDR_W-1:0]  addr_coord_load_b1,
    input  logic [COORD_W-1:0] data_in1_coord_load_b1,
    input  logic [COORD_W-1:0] data_in2_coord_load_b1,

    input  logic              control_mem_coord_load_b2,

    input  logic               we_coord_load_b2,
    input  logic [ADDR_W-1:0]  addr_coord_load_b2,
    input  logic [COORD_W-1:0] data_in1_coord_load_b2,
    input  logic [COORD_W-1:0] data_in2_coord_load_b2,


    // --- Port BRAM cluster ---
    input  logic              control_mem_cluster_read,
    input  logic [ADDR_W-1:0] addr_cluster_read,
    output logic [ADDR_W-1:0] cluster_read,

    output logic              done // fin du clustering
    );

    typedef struct packed {
        logic                  we;
        logic [ADDR_W-1:0]     addr;
        logic [COORD_W-1:0]    data_in1;
        logic [COORD_W-1:0]    data_in2;
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

    // -------------------------------------------------------------------
    // Déclaration des ports mémoire coord_b1
    // -------------------------------------------------------------------
    coord_owner_t     owner_b1;
    coord_mem_port_t  port_coord_b1_load, port_compute_b1, port_act_b1, port_cluster_b1, port_mux_b1;

    // -------------------------------------------------------------------
    // Déclaration des ports mémoire coord_b2
    // -------------------------------------------------------------------
    coord_owner_t     owner_b2;
    coord_mem_port_t  port_coord_b2_load, port_compute_b2, port_act_b2, port_cluster_b2, port_mux_b2;
    
    // -------------------------------------------------------------------
    // Déclaration bloc exp et annexes
    // -------------------------------------------------------------------
    logic              start_b1;     // lance le balayage complet d'un step
    logic              start_compute_b1;
    logic [STEP_W-1:0] step_idx;  // index de l'iteration courante

    // --- Port BRAM point (adresse incrementee chaque cycle) ---
    
    logic [ADDR_W-1:0] addr_coord_b1;
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

    logic [31:0] sum_row_P;
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
    logic [COORD_W-1:0] data_in1_coord_b1;
    logic [COORD_W-1:0] data_in2_coord_b1;
    

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

    logic [ADDR_W-1:0] addr_coord_compute_b2;


    // --- Port BRAM P_ij ---
    logic [ADDR_P_IJ_W-1:0]  addr_P_ij_b2;
    logic [P_IJ_W-1:0]      P_ij_b2;


    // --- Port LUT inv (inv[index = mantissa]) ---
    logic [ADDR_LUT_INV-1:0] index_LUT_inv;
    logic [COORD_W-1:0]      result_inv;

	// --- Sortie vers la mémoire d'acutalisation des coord *** ---
    logic signed [31:0]            mult_act_X;
    logic signed [31:0]            mult_act_Y;
    logic [ADDR_P_IJ_W-1:0] addr_act;
    logic [ADDR_P_IJ_W-1:0] addr_act_b2;
    logic                   valid_out_b2;
    
    logic [31:0] entropy;
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
    logic signed [31:0] mult_act_X_mem;
    logic signed [31:0] mult_act_Y_mem;

    logic done_act;

    // DUT
    act_coord #(
        .NB_POINTS (NB_POINTS),
        .COORD_W   (COORD_W),
        .ADDR_W    (ADDR_W)
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
    logic [ADDR_W-1:0] addr_cluster;
    logic [ADDR_W-1:0] addr_cluster_compute;
    logic              we_cluster;
    logic              valid_cluster;
    logic [ADDR_W-1:0] cluster_out;


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
        .valid_cluster (valid_cluster),
        .cluster_out   (cluster_out),

        .done          (done)
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
        .data_out(cluster_read)
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
                    cnt_done_b2 <= cnt_done_b2 + 1'b1;
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
                step_idx <= step_idx + 1'b1;
                start_compute_b1 <= 1'b1;
            end
        end
    end

    assign start_b1 = start || start_compute_b1;

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
        if (!control_mem_coord_load_b1) owner_b1 = OWNER_TB;
        else if (control_mem_b3)   owner_b1 = OWNER_ACT;
        else if (all_steps_done)   owner_b1 = OWNER_CLUSTER_ASSIGN;
        else                       owner_b1 = OWNER_COMPUTE;
    end

    assign port_coord_b1_load.we       = we_coord_load_b1;
    assign port_coord_b1_load.addr     = addr_coord_load_b1;
    assign port_coord_b1_load.data_in1 = data_in1_coord_load_b1;
    assign port_coord_b1_load.data_in2 = data_in2_coord_load_b1;

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

    assign port_mux_b1 = mux_coord_port(owner_b1, port_coord_b1_load, port_compute_b1, port_act_b1, port_cluster_b1);

    assign we_coord_b1       = port_mux_b1.we;
    assign addr_coord_b1     = port_mux_b1.addr;
    assign data_in1_coord_b1 = port_mux_b1.data_in1;
    assign data_in2_coord_b1 = port_mux_b1.data_in2;



    always_comb begin
        if (!control_mem_coord_load_b2) owner_b2 = OWNER_TB;
        else if (control_mem_b3)   owner_b2 = OWNER_ACT;
        else                       owner_b2 = OWNER_COMPUTE;
    end


    assign port_coord_b2_load.we       = we_coord_load_b2;
    assign port_coord_b2_load.addr     = addr_coord_load_b2;
    assign port_coord_b2_load.data_in1 = data_in1_coord_load_b2;
    assign port_coord_b2_load.data_in2 = data_in2_coord_load_b2;

    assign port_compute_b2.we       = 1'b0;               // bloc_grad ne fait que lire
    assign port_compute_b2.addr     = addr_coord_compute_b2;
    assign port_compute_b2.data_in1 = '0;
    assign port_compute_b2.data_in2 = '0;

    assign port_act_b2.we       = we_coord_b3;
    assign port_act_b2.addr     = addr_coord_b3;
    assign port_act_b2.data_in1 = coord_X_act;
    assign port_act_b2.data_in2 = coord_Y_act;

    assign port_cluster_b2.we       = 1'b0;
    assign port_cluster_b2.addr     = '0;
    assign port_cluster_b2.data_in1 = '0;
    assign port_cluster_b2.data_in2 = '0;

    assign port_mux_b2 = mux_coord_port(owner_b2, port_coord_b2_load, port_compute_b2, port_act_b2, port_cluster_b2);

    assign we_coord_b2       = port_mux_b2.we;
    assign addr_coord_b2     = port_mux_b2.addr;
    assign data_in1_coord_b2 = port_mux_b2.data_in1;
    assign data_in2_coord_b2 = port_mux_b2.data_in2;



    assign addr_cluster = (control_mem_cluster_read) ? addr_cluster_compute : addr_cluster_read;


    // -------------------------------------------------------------------
    // Print results
    // -------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (valid_sum_row_P) begin
            $display("[%0t] RESULT sum_row_P i=%0d j=%0d sum_row_P=%0d",
                    $time,
                    out_i_b1,
                    out_j_b1,
                    sum_row_P);
        end
        
        if (start_b4) begin
            $display("\n=== start_b4 ===");
        end

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
        end
    end


endmodule