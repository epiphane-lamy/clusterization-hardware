
module norm_entropy_grad #(
    parameter int NB_POINTS    = 8,           // nombre de points stockés en dur, prochainement chargé au début du calcul <= 2**ADDR_W
    parameter int COORD_W      = 16,           // largeur des coordonnees, fixed-point SIGNE
    parameter int ADDR_W       = 7,           // largeur des adresses P_ij
    parameter int P_IJ_W       = 16,           // largeur des P_ij, fixed-point SIGNE
    parameter int ADDR_P_IJ_W  = 7,           // largeur des adresses P_ij
    parameter int SUM_ROW_P_W  = 32,                // largeur de sum_row_P
    parameter int ACT_W        = 32,                // largeur des valeurs d'actualisation, fixed-point SIGNE

    parameter int ENTH_W       = 32,                // largeur des valeurs d'enthropie, fixed-point SIGNE

    parameter int ADDR_LUT_INV = 10,           // largeur des adresses LUT exp
    parameter int STEP_W       = 6,           // largeur du compteur d'iteration (max_iter=50 -> 6 bits suffisent)
    parameter int K_W          = 16,          // largeur de la constante K_step precalculee (signee, negative)
    parameter int D2_W         = 2 * COORD_W // dx*dx et dy*dy : produit de deux signed COORD_W bits -> 2*COORD_W bits
	)(
	input  logic             clk,
	input  logic             rst_n,

    // --- Port BRAM point (adresse incrementee chaque cycle) ---
    output logic [ADDR_W-1:0]  addr,
    input  logic [COORD_W-1:0] coord_X,
    input  logic [COORD_W-1:0] coord_Y,

    // --- Port BRAM P_ij (adresse incrementee chaque cycle) ---
    output logic [ADDR_P_IJ_W-1:0] addr_P_ij,
    input  logic [P_IJ_W-1:0]      P_ij,

    // --- Port LUT inv (inv[index = mantissa]) ---
    output logic [ADDR_LUT_INV-1:0] index_LUT_inv,
    input  logic [COORD_W-1:0]      result_inv,

	// --- Sortie vers la mémoire d'acutalisation des coord *** ---
    output logic signed [ACT_W-1:0]            mult_act_X,
    output logic signed [ACT_W-1:0]            mult_act_Y,
    output logic [ADDR_P_IJ_W-1:0] addr_act,
    output logic                   valid_out,

    input logic  [SUM_ROW_P_W-1:0]      sum_row_P,
    input logic [ADDR_W-1:0] out_i,           // permet de savoir le numéro de la ligne
    input logic              valid_sum_row_P, // lance le balayage d'une ligne

    output logic [ENTH_W-1:0] entropy,
    output logic        valid_entropy,
 
    output logic done
);



    // -------------------------------------------------------------------
    // FSM de sequencement
    // -------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE,        // état initial
        S_COMPUTE_INV, // calcul de l'addr de inv[sum_row_P]
        S_INV_WAIT,    // cycle d'attente pour matcher la latence LUT inv
        S_FETCH_I,     // emission addr = cnt_i
        S_FETCH_WAIT,  // emission addr = cnt_j(=0) + capture de coord_X_i/Y_i
        S_RUN,         // calcul en cours
        S_DRAIN,       // laisse le temps au pipeline de se vider
        S_DONE         // calcul terminé
    } state_t;
 
    state_t current_state, next_state;
 
 
    logic [ADDR_W-1:0] cnt_i;
    logic [ADDR_W-1:0] cnt_j;
    
    logic issue_i;       // 1 quand addr_i correspond a un i valide ce cycle
    logic issue_j;       // 1 quand addr_j correspond a un j valide ce cycle

    assign issue_i = (current_state == S_FETCH_I);
    assign issue_j = (current_state == S_RUN);

 
    // -------------------------------------------------------------------
    // Adressage BRAM points / P_ij / valeur d'actualisation
    // -------------------------------------------------------------------
    assign addr = issue_i ? cnt_i : cnt_j;
    assign addr_P_ij = cnt_j;
    assign addr_act = cnt_i;

 
    // -------------------------------------------------------------------
    // Gestiond du compteur j pour adressage
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_j <= '0;
        end else begin
            case (current_state)
                S_IDLE: begin
                    cnt_j <= '0;
                end
 
                S_RUN: begin
                    if (cnt_j != NB_POINTS - 1)
                        cnt_j <= cnt_j + 1'b1;
                end
 
                default: begin
                    // cnt_j fixe
                end
            endcase
        end
    end

    // Compteur de vidage du pipeline
    localparam int PIPE_DEPTH = 85; // nb d'etages du pipeline
    logic [$clog2(PIPE_DEPTH+1)-1:0] drain_cnt;
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) drain_cnt <= '0;
        else if (current_state == S_DRAIN) drain_cnt <= drain_cnt + 1'b1;
        else drain_cnt <= '0;
    end

    logic last_mult_act_seen;
    logic last_entropy_seen;
    logic [ADDR_W-1:0]  out_j;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_mult_act_seen <= 1'b0;
            last_entropy_seen  <= 1'b0;
        end else begin
            if (current_state == S_FETCH_I) begin
                // reset pour chaque nouvelle ligne
                last_mult_act_seen <= 1'b0;
                last_entropy_seen  <= 1'b0;
            end else begin
                if (valid_out && (out_j == NB_POINTS-1))
                    last_mult_act_seen <= 1'b1;
                if (valid_entropy)
                    last_entropy_seen <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------
    // Capture différé de sum_row_P / out_i si bloc grad en dehors de IDLE
    // -------------------------------------------------------------------
    logic              pending;
    logic [31:0]       sum_row_P_latched;
    logic [ADDR_W-1:0] out_i_latched;
    logic              start_pulse;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= 1'b0;
        end else begin
            if (valid_sum_row_P && (current_state != S_IDLE)) begin
                // grad occupé : on mémorise le pulse pour plus tard
                pending           <= 1'b1;
                sum_row_P_latched <= sum_row_P;
                out_i_latched     <= out_i;
            end else if (start_pulse) begin
                pending <= 1'b0; // consommé
            end
        end
    end

    // pulse de démarrage "propre" : soit le pulse arrive alors qu'on est déjà idle,
    // soit on rattrape un pulse qui avait été mis en attente
    assign start_pulse = (current_state == S_IDLE) && (valid_sum_row_P || pending);
 
    // -------------------------------------------------------------------
    // FSM : transitions
    // -------------------------------------------------------------------
    always_comb begin
        next_state = current_state;
        unique case (current_state)
            S_IDLE : next_state = start_pulse ? S_COMPUTE_INV : S_IDLE;
            S_COMPUTE_INV : next_state = S_INV_WAIT;
            S_INV_WAIT    : next_state = S_FETCH_I;
            S_FETCH_I     : next_state = S_FETCH_WAIT;
            S_FETCH_WAIT  : next_state = S_RUN;
            S_RUN         : next_state = (cnt_j == NB_POINTS - 1) ? S_DRAIN : S_RUN;
            S_DRAIN : next_state = (last_mult_act_seen && last_entropy_seen) ? S_DONE : S_DRAIN;
            S_DONE        : next_state = S_IDLE;
            default       : next_state = S_IDLE;
        endcase
    end
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) current_state <= S_IDLE;
        else        current_state <= next_state;
    end
 
    assign done = (current_state == S_DONE);

 

    // -------------------------------------------------------------------
    // Tags de decalage : independants de l'etat courant, calcules a partir
    // de "quelle adresse a ete emise au cycle precedent"
    // -------------------------------------------------------------------
    logic              i_capture_d;   // 1 : le bus porte la donnee de i ce cycle
    logic              j_valid_d;     // 1 : le bus porte une donnee j valide ce cycle
    logic [ADDR_W-1:0] j_idx_d;       // index j correspondant a la donnee sur le bus

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_capture_d <= 1'b0;
            j_valid_d   <= 1'b0;
            j_idx_d     <= '0;
        end else begin
            i_capture_d <= issue_i;
            j_valid_d   <= issue_j;
            j_idx_d     <= cnt_j;
        end
    end



    // -------------------------------------------------------------------
    // Capture de out_i / sum_row_P_i / coord_X_i / coord_Y_i
    // -------------------------------------------------------------------
    logic [COORD_W-1:0] coord_X_i, coord_Y_i;
    logic [SUM_ROW_P_W-1:0] sum_row_P_i;

    always_ff @(posedge clk) begin
        if (start_pulse) begin
            sum_row_P_i <= pending ? sum_row_P_latched : sum_row_P;
            cnt_i       <= pending ? (out_i_latched) : (out_i - 1);
        end
        if (i_capture_d) begin
            coord_X_i <= coord_X;
            coord_Y_i <= coord_Y;
        end
    end


    // -------------------------------------------------------------------
    // Compute de inv[sum_row_P]
    // -------------------------------------------------------------------
    logic [$clog2(SUM_ROW_P_W)-1:0] msb_comb;
    logic [SUM_ROW_P_W-1:0] sum_row_P_inv;
    logic [$clog2(SUM_ROW_P_W)-1:0]  msb;
    logic [SUM_ROW_P_W-1:0] mantissa;

    logic [6:0]  debug_count;

    always_comb begin
        msb_comb = '0;
        for (int i = (SUM_ROW_P_W-1); i >= 0; i--)
            if (sum_row_P_i[i]) begin
                msb_comb = i[$clog2(SUM_ROW_P_W)-1:0];
                break;
            end
    end

    always_ff @(posedge clk) begin
        if (current_state == S_COMPUTE_INV) begin
            msb      <= msb_comb;
            mantissa <= sum_row_P_i << (31 - msb_comb);
        end
        
        if (current_state == S_FETCH_I) begin
            sum_row_P_inv <= result_inv;
        end
    end

    assign index_LUT_inv = mantissa[SUM_ROW_P_W-1:SUM_ROW_P_W-10];


    // -------------------------------------------------------------------
    // Pipeline de calcul
    // -------------------------------------------------------------------

    // Etage 0 -> 1 : normalisation de P_ij en P_ij_norm + capture de coord_X et coord_Y
    logic [COORD_W - 1:0] P_ij_norm;
    logic [COORD_W-1:0]   coord_X_d, coord_Y_d;
    logic [ADDR_W-1:0]    j_1;
    logic                 valid_1;

    // Etage 1 -> 2 : calcul de P_ij_norm * coord
    logic [ACT_W-1:0]       mult_X;
    logic [ACT_W-1:0]       mult_Y;
    logic [ADDR_W-1:0] j_2;
    logic              valid_2;
 
    // Etage 2 -> 3 : accumulatin de P_dot
    logic [63:0]       P_dot_X;
    logic [63:0]       P_dot_Y;
    logic [ADDR_W-1:0] j_3;
    logic              valid_grad;
 
    // Etage 3 -> 4 : calcul de grad_X et grad_Y
    logic signed [15:0]       grad_X;
    logic signed [15:0]       grad_Y;
    logic [ADDR_W-1:0] j_4;
    logic              valid_mult_act;

    // Etage 3 -> 4 :  calcul de forca * grad_x_float
    logic [15:0]        forca;
    logic signed [16:0] forca_s;
    //logic [ADDR_W-1:0]  out_j;


    logic [63:0] P_dot_X_reg;
    logic [63:0] P_dot_Y_reg;
    logic [63:0] P_dot_X_next;
    logic [63:0] P_dot_Y_next;

    assign P_dot_X_next = P_dot_X_reg + mult_X;
    assign P_dot_Y_next = P_dot_Y_reg + mult_Y;
    
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_1     <= 1'b0;
            valid_2     <= 1'b0;

            P_dot_X     <= '0;
            P_dot_Y     <= '0;
            P_dot_X_reg <= '0;
            P_dot_Y_reg <= '0;
            valid_grad  <= 1'b0;

            valid_mult_act <= 1'b0;

            valid_out      <= 1'b0;

            debug_count    <= 0;
        end else begin
            
            // etage 0 : calcul de P_ij_norm
            P_ij_norm <= (P_ij * sum_row_P_inv) >> msb;
            coord_X_d <= coord_X;
            coord_Y_d <= coord_Y;
            j_1       <= j_idx_d;
            valid_1   <= j_valid_d;
            

            // etage 1 : calcul de P_ij_norm * coord
            mult_X  <= P_ij_norm * coord_X_d;
            mult_Y  <= P_ij_norm * coord_Y_d;
            j_2     <= j_1;
            valid_2 <= valid_1;

            
            // etage 2 : accumulatin de P_dot
            if (valid_2) begin
                if (j_2 == NB_POINTS-1) begin
                    P_dot_X <= P_dot_X_next >> 16; // décalage logique final
                    P_dot_Y <= P_dot_Y_next >> 16;

                    valid_grad  <= 1'b1;

                    P_dot_X_reg <= '0;
                    P_dot_Y_reg <= '0;
                end else begin
                    P_dot_X_reg <= P_dot_X_next;
                    P_dot_Y_reg <= P_dot_Y_next;
                    valid_grad  <= 1'b1;
                end
            end else begin
                valid_grad <= 1'b0;
            end
            j_3        <= j_2;

            if (valid_grad && (j_3 == NB_POINTS-1)) begin // à vérifier pour savoir si 
                // etage 3 : calcul de grad_X et grad_Y
                
                grad_X         <= $signed(P_dot_X[15:0]) - $signed({1'b0,coord_X_i});
                grad_Y         <= $signed(P_dot_Y[15:0]) - $signed({1'b0,coord_Y_i});
                j_4            <= j_3;
                valid_mult_act <= valid_grad;
            end else begin
                valid_mult_act <= 1'b0;
            end

            if (valid_mult_act) begin
                // etage 4 : calcul de forca * grad_x_float
                mult_act_X <= (grad_X * forca_s) >>> 16;
                mult_act_Y <= (grad_Y * forca_s) >>> 16;
                out_j      <= j_4;
                valid_out  <= valid_mult_act;
            end else begin
                valid_out <= 1'b0;
            end
            
            debug_count <= debug_count + 1'b1;
        end
    end

    assign forca_s = {1'b0, forca};

    logic [31:0] entropy_reg;
    logic [31:0] entropy_next;
    logic [31:0] p_squared;

    assign p_squared    = P_ij_norm * P_ij_norm;              // 32 bits, pas d'overflow (16b*16b)
    assign entropy_next = entropy_reg + (p_squared >> 16);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            entropy_reg  <= '0;
            entropy       <= 32'h0000FFFF; // valeur par defaut, peu importe au reset
            valid_entropy <= 1'b0;
        end else begin
            valid_entropy <= 1'b0;
            if (valid_1) begin
                if (j_1 == NB_POINTS-1) begin
                    entropy       <= 32'd65536 - entropy_next; // soustraction finale, une seule fois
                    valid_entropy <= 1'b1;
                    entropy_reg  <= '0;                         // reset pour la ligne suivante
                end else begin
                    entropy_reg <= entropy_next;
                end
            end
        end
    end



    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            forca  <= 16'd22938;
        end else begin
            if (valid_entropy) begin
                if (entropy > 16'd65200) begin
                forca  <= 16'd131;
                end else begin
                    forca  <= 16'd22938;
                end
            end
        end
    end



endmodule