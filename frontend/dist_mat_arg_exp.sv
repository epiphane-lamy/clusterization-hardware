

module dist_mat_arg_exp #(
    parameter int NB_POINTS    = 8,           // nombre de points stockés en dur, prochainement chargé au début du calcul <= 2**ADDR_W
    parameter int COORD_W      = 16,           // largeur des coordonnees, fixed-point SIGNE
    parameter int ADDR_W       = 7,           // largeur des adresses points Xf
    parameter int ADDR_LUT_EXP = 14,           // largeur des adresses LUT exp
    parameter int STEP_W       = 6,           // largeur du compteur d'iteration (max_iter=50 -> 6 bits suffisent)
    parameter int K_W          = 16,          // largeur de la constante K_step precalculee (signee, negative)
    parameter int D2_W         = 2 * COORD_W // dx*dx et dy*dy : produit de deux signed COORD_W bits -> 2*COORD_W bits
	)(
	input  logic             clk,
	input  logic             rst_n,
 
    input logic              start,     // lance le balayage complet d'un step
    input logic [STEP_W-1:0] step_idx,  // index de l'iteration courante

    // --- Port BRAM point (adresse incrementee chaque cycle) ---
    output logic [ADDR_W-1:0]  addr,
    input  logic [COORD_W-1:0] coord_X,
    input  logic [COORD_W-1:0] coord_Y,

    // --- Port LUT exp (exp[index = arg + 10 240]) ---
    output logic [ADDR_LUT_EXP-1:0] index_LUT_exp,
    input  logic [COORD_W-1:0]      result_exp,

	// --- Sortie vers le bloc *** ---
    output logic [COORD_W - 1:0] P_ij,   // D2_ij * K_step
    output logic [ADDR_W-1:0]          out_i,
    output logic [ADDR_W-1:0]          out_j,
    output logic                       valid_out,

    output logic [31:0] sum_row_P,
    output logic        valid_sum_row_P,

 
    input logic  credit_avail,
    output logic done
);
    // -------------------------------------------------------------------
    // ROM des constantes K_step = -1/(2*T^2), precalculees cote logiciel.
    // A completer avec les vraies valeurs quantifiees.
    // -------------------------------------------------------------------
    logic signed [K_W-1:0] K_rom [0:(2**STEP_W)-1];
    logic signed [K_W-1:0] K_step_r;
    initial $readmemh("k_step_rom.hex", K_rom);

	// -------------------------------------------------------------------
    // FSM de sequencement
    // -------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE,       // état initial
        S_FETCH_I,    // emission addr = cnt_i
        S_FETCH_WAIT, // emission addr = cnt_j(=0) + capture de coord_X_i/Y_i
        S_RUN,        // calcul en cours
        S_LAST_WAIT,  // reception de la derniere donnee j de la ligne
        S_DRAIN,      // laisse le temps au pipeline de se vider
        S_DONE        // calcul terminé
    } state_t;
 
    state_t current_state, next_state;
 
    logic [ADDR_W-1:0] cnt_i;
    logic [ADDR_W-1:0] cnt_j;
    
    logic issue_i;       // 1 quand addr_i correspond a un i valide ce cycle
    logic issue_j;       // 1 quand addr_j correspond a un j valide ce cycle

    assign issue_i = (current_state == S_FETCH_I);
    assign issue_j = (current_state == S_FETCH_WAIT) || (current_state == S_RUN);

 
    // -------------------------------------------------------------------
    // Adressage BRAM
    // -------------------------------------------------------------------
    assign addr = issue_i ? cnt_i : cnt_j;
 
    // -------------------------------------------------------------------
    // Gestiond des compteurs i / j pour adressage
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_i <= '0;
            cnt_j <= '0;
        end else begin
            case (current_state)
                S_IDLE: begin
                    if (start) cnt_i <= '0;
                end

                S_FETCH_I: begin
                    cnt_j <= '0;
                end

                S_FETCH_WAIT: begin
                    cnt_j <= cnt_j + 1'b1;   // j=0 vient d'etre emis par la sram, on prepare j=1
                end
 
                S_RUN: begin
                    if (cnt_j != NB_POINTS - 1)
                        cnt_j <= cnt_j + 1'b1;
                    // si cnt_j == NB_POINTS-1 : derniere adresse deja emise, on fige
                end

                S_LAST_WAIT: begin
                    /*on ajoute la condition d'incrémentation credit_avail pour
                    pas que le cnt s'incrémente tant que le bloc grad n'estr pas prêt*/
                    if ((cnt_i != NB_POINTS - 1) && credit_avail)
                    
                        cnt_i <= cnt_i + 1'b1;   // ligne suivante
                end
 
                default: begin
                    // cnt_i/cnt_j fixe pendant S_DRAIN/S_DONE
                end
            endcase
        end
    end

    // Compteur de vidage du pipeline
    localparam int PIPE_DEPTH = 8; // nb d'etages du pipeline
    logic [$clog2(PIPE_DEPTH+1)-1:0] drain_cnt;
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) drain_cnt <= '0;
        else if (current_state == S_DRAIN) drain_cnt <= drain_cnt + 1'b1;
        else drain_cnt <= '0;
    end
 
    // -------------------------------------------------------------------
    // FSM : transitions
    // -------------------------------------------------------------------
    always_comb begin
        next_state = current_state;
        unique case (current_state)
            S_IDLE       : next_state = start ? S_FETCH_I : S_IDLE;
            S_FETCH_I    : next_state = S_FETCH_WAIT;
            S_FETCH_WAIT : next_state = S_RUN;
            S_RUN        : next_state = (cnt_j == NB_POINTS - 1) ? S_LAST_WAIT : S_RUN;
            //S_LAST_WAIT  : next_state = (cnt_i == NB_POINTS - 1) ? S_DRAIN : S_FETCH_I;
            S_LAST_WAIT  : next_state = (cnt_i == NB_POINTS - 1) ? S_DRAIN : (credit_avail == 1) ? S_FETCH_I : S_LAST_WAIT;
            S_DRAIN      : next_state = (drain_cnt == PIPE_DEPTH - 1) ? S_DONE : S_DRAIN;
            S_DONE       : next_state = S_IDLE;
            default      : next_state = S_IDLE;
        endcase
    end
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) current_state <= S_IDLE;
        else        current_state <= next_state;
    end
 
    assign done = (current_state == S_DONE);
 
    // Verrouillage de K_step au debut du step (constant pendant tout le balayage)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) K_step_r <= '0;
        else if (current_state == S_IDLE && start) K_step_r <= K_rom[step_idx];
    end
 

    // -------------------------------------------------------------------
    // Tags de decalage : independants de l'etat courant, calcules a partir
    // de "quelle adresse a ete emise au cycle precedent"
    // -------------------------------------------------------------------
    logic              i_capture_d;   // 1 : le bus porte la donnee de i ce cycle
    logic              j_valid_d;     // 1 : le bus porte une donnee j valide ce cycle
    logic [ADDR_W-1:0] j_idx_d;       // index j correspondant a la donnee sur le bus
    logic [ADDR_W-1:0] i_idx_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_capture_d <= 1'b0;
            j_valid_d   <= 1'b0;
            j_idx_d     <= '0;
            i_idx_d     <= '0;
        end else begin
            i_capture_d <= issue_i;
            j_valid_d   <= issue_j;
            j_idx_d     <= cnt_j;
            i_idx_d <= cnt_i;
        end
    end

    // -------------------------------------------------------------------
    // Capture de coord_X_i / coord_Y_i (independante de l'avancee du pipeline)
    // -------------------------------------------------------------------
    logic [COORD_W-1:0] coord_X_i, coord_Y_i;
    logic [6:0] debug_count;

    always_ff @(posedge clk) begin
        if (i_capture_d) begin
            coord_X_i <= coord_X;
            coord_Y_i <= coord_Y;
        end
    end


    // -------------------------------------------------------------------
    // Pipeline de calcul
    // -------------------------------------------------------------------
    logic signed [COORD_W:0]   dx, dy;
    logic [ADDR_W-1:0]         i_1, j_1;
    logic                      valid_1;
 
    // Etage 1 -> 2 : carres
    logic [2*COORD_W-1:0] x_2, y_2;
    logic [ADDR_W-1:0]      i_2, j_2;
    logic                   valid_2;

    // Etage 2 -> 3 : D2 = x2 + y2
    logic [2*COORD_W:0] D2_ij;
    logic [ADDR_W-1:0]      i_3, j_3;
    logic                   valid_3;

    // Etage 3 -> 4 : arg_exp_brut = D2 * K_fixed (négatif)
    logic signed [D2_W + K_W - 1:0] arg_exp_brut;
    logic [ADDR_W-1:0]      i_4, j_4;
    logic                   valid_4;

    // Etage 4 -> 5 : arg_exp_q6_10 = arg_exp_brut >> 16
    logic [D2_W + K_W - 1:0] arg_exp_q6_10;
    logic signed [21:0] arg_shifted;
    logic [ADDR_W-1:0]      i_5, j_5;
    logic                   valid_5;

    // Etage 5 -> 6 : P_ij = exp_LUT[index]
    logic                   flag_exp;
    logic [ADDR_W-1:0]      i_6, j_6;
    logic                   valid_6;

    // Etage 6 -> 7 : on attend que la LUT reponde (latence 1 cycle),
    // on retarde flag_exp/i/j/valid d'un cran de plus pour rester
    // synchrones avec result_exp
    logic              flag_exp_d;
    logic [ADDR_W-1:0] i_7, j_7;
    logic              valid_7;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_1   <= 1'b0;
            valid_2   <= 1'b0;
            valid_3   <= 1'b0;
            valid_4   <= 1'b0;
            valid_5   <= 1'b0;
            flag_exp  <= 1'b0;
            valid_6   <= 1'b0;
            valid_out <= 1'b0;
            debug_count <= 0;
        end else begin
                        
            //dx      <= coord_X_i - coord_X;
            //dy      <= coord_Y_i - coord_Y;
            dx <= $signed({1'b0,coord_X_i}) - $signed({1'b0,coord_X});
            dy <= $signed({1'b0,coord_Y_i}) - $signed({1'b0,coord_Y});
            i_1     <= cnt_i;
            j_1     <= j_idx_d;
            valid_1 <= j_valid_d;
            
            x_2     <= dx * dx;
            y_2     <= dy * dy;
            i_2     <= i_1;
            j_2     <= j_1;
            valid_2 <= valid_1;
            
            if (j_valid_d && j_idx_d < 20 && debug_count < 100) begin
                /*
                $display("[%0t] INPUT j=%0d Xi_reg=%0d Yi_reg=%0d Xj=%0d Yj=%0d",
                    $time,
                    j_idx_d,
                    coord_X_i,
                    coord_Y_i,
                    coord_X,
                    coord_Y
                );*/
            end
            
            D2_ij   <= x_2 + y_2;
            i_3     <= i_2;
            j_3     <= j_2;
            valid_3 <= valid_2;

            //arg_exp_brut <= D2_ij * K_step_r;
            //arg_exp_brut <= $signed(D2_ij) * $signed(K_step_r);
            arg_exp_brut <= $signed({1'b0,D2_ij}) * K_step_r;
            i_4          <= i_3;
            j_4          <= j_3;
            valid_4      <= valid_3;
            /*
            $display("X_i=%d X=%d Y_i=%d Y=%d dx=%d dy=%d",
                coord_X_i,
                coord_X,
                coord_Y_i,
                coord_Y,
                dx,
                dy
            );

            $display("D2=%d K=%d arg_brut=%d arg_q6_10 signed=%0d hex=%h",
                D2_ij,
                K_step_r,
                arg_exp_brut,
                $signed(arg_exp_q6_10),
                arg_exp_q6_10);*/

            //arg_exp_q6_10 <= arg_exp_brut >> 16;
            arg_exp_q6_10 <= $signed(arg_exp_brut) >>> 22;
            i_5            <= i_4;
            j_5            <= j_4;
            valid_5        <= valid_4;
            /*
            if (valid_5 && debug_count < 100) begin
                $display("j=%0d arg=%0d index=%0d",
                        j_5,
                        $signed(arg_exp_q6_10),
                        index_LUT_exp);
            end*/

            //if ((arg_exp_q6_10 >= -10240) && (arg_exp_q6_10 <= 0) && valid_5) begin
            if (($signed(arg_exp_q6_10) >= -10240) && ($signed(arg_exp_q6_10) <= 0) && valid_5) begin
                arg_shifted <= arg_exp_q6_10[21:0] + 22'sd10240;
                flag_exp      <= 1'b0;
            end else begin
                arg_shifted <= '0;
                flag_exp <= 1'b1;
            end
            i_6           <= i_5;
            j_6           <= j_5;
            valid_6       <= valid_5;
/*
            if(valid_5) begin
                $display("arg_q6_10 signed=%0d hex=%h shifted=%d flag=%b index=%d exp=%d",
                    $signed(arg_exp_q6_10),
                    arg_exp_q6_10,
                    arg_shifted,
                    flag_exp,
                    index_LUT_exp,
                    result_exp
                );
            end*/
            
            // etage 7 : simple retard d'1 cycle pour matcher la latence LUT
            flag_exp_d <= flag_exp;
            i_7        <= i_6;
            j_7        <= j_6;
            valid_7    <= valid_6;


            // etage 7 -> sortie : maintenant result_exp EST bien synchrone
            // avec flag_exp_d/i_7/j_7/valid_7
            P_ij      <= flag_exp_d ? '0 : result_exp;
            out_i     <= i_7;
            out_j     <= j_7;
            valid_out <= valid_7;
            
            debug_count <= debug_count + 1'b1;
        end
    end

    assign index_LUT_exp = arg_shifted[ADDR_LUT_EXP - 1:0];
     
/*
    logic [15:0] sum_row_P_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_row_P       <= '0;
            sum_row_P_count <= 0;
        end else begin
            if(valid_out && sum_row_P_count < NB_POINTS) begin
                sum_row_P       <= sum_row_P + P_ij;
                sum_row_P_count <= sum_row_P_count + 1'b1;
            end else begin
                sum_row_P       <= '0;
                sum_row_P_count <= 0;

            end
        end
    end
    assign valid_sum_row_P = (sum_row_P_count == NB_POINTS) ? 1 : 0;
    */
    logic [31:0] sum_row_P_reg;
    logic [31:0] sum_row_P_next;

    assign sum_row_P_next = sum_row_P_reg + P_ij;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_row_P_reg   <= '0;
            valid_sum_row_P <= 1'b0;
            sum_row_P       <= '0;
        end else begin
            valid_sum_row_P <= 1'b0;
            if (valid_out) begin
                if (out_j == NB_POINTS-1) begin
                    sum_row_P       <= sum_row_P_next; // somme complete, incluant ce dernier P_ij
                    valid_sum_row_P <= 1'b1;
                    sum_row_P_reg   <= '0;               // reset pour ligne suivante
                end else begin
                    sum_row_P_reg <= sum_row_P_next;
                end
            end
        end
    end
    /*
    always_ff @(posedge clk) begin
        $display("BRAM addr=%d dataX=%d dataY=%d",
                addr,
                coord_X,
                coord_Y);
    end
    */

endmodule

