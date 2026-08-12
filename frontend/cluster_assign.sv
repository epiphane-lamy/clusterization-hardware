

module cluster_assign #(
    parameter int NB_POINTS    = 8,           // nombre de points stockés en dur, prochainement chargé au début du calcul <= 2**ADDR_W
    parameter int COORD_W      = 16,           // largeur des coordonnees, fixed-point SIGNE
    parameter int ADDR_W       = 7,           // largeur des adresses points Xf
    parameter int TOL          = 422144877
	)(
	input  logic             clk,
	input  logic             rst_n,
 
    input logic              start,     // lance l'assignation des clusters

    // --- Port BRAM point (adresse incrementee chaque cycle) ---
    output logic [ADDR_W-1:0]  addr_coord,
    input  logic [COORD_W-1:0] coord_X,
    input  logic [COORD_W-1:0] coord_Y,

    // --- Port BRAM clusters (adresse incrementee chaque cycle) ---
    output logic [ADDR_W-1:0] addr_cluster,
    output logic              we_cluster,
    input  logic              valid_cluster, // (=0 => cluster=-1 else !=-1)
    input  logic [ADDR_W-1:0] cluster_in,
    output logic [ADDR_W-1:0] cluster_out,

    output logic done
);

	// -------------------------------------------------------------------
    // FSM de sequencement
    // -------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE,           // état initial
        S_FETCH_I,        // emission addr_coord = cnt_i + addr_cluster = cnt_i
        S_FETCH_WAIT,     // emission addr = cnt_j(=0) + capture de coord_X_i / coord_Y_i
        S_WRITE_I,        // écriture de cluster[i]
        S_FETCH_J,        // émet addr=cnt_j (pas d'écriture)
        S_CHOICE_COMPUTE, // lit cluster_in (valide grâce au cycle précédent), puis décide
        S_COMPUTE,        // calcul en cours
        S_WRITE,          // écriture de cluster[j]
        S_DRAIN,          // laisse le temps au pipeline de se vider
        S_DONE            // calcul terminé
    } state_t;
 
    state_t current_state, next_state;
 
    logic [ADDR_W-1:0] cnt_i;
    logic [ADDR_W-1:0] num_cluster;
    logic [ADDR_W-1:0] cluster_out_i;
    logic [ADDR_W-1:0] cnt_j;
    
    logic issue_i;       // 1 quand addr_i correspond a un i valide ce cycle
    logic issue_j;       // 1 quand addr_j correspond a un j valide ce cycle

    assign issue_i = (current_state == S_FETCH_I) || (current_state == S_FETCH_WAIT) || (current_state == S_WRITE_I);
    assign issue_j = (current_state == S_FETCH_J) || (current_state == S_CHOICE_COMPUTE) || (current_state == S_WRITE);
 
    // -------------------------------------------------------------------
    // Adressage BRAM
    // -------------------------------------------------------------------
    assign addr_coord   = issue_i ? cnt_i : cnt_j;
    assign addr_cluster = issue_i ? cnt_i : cnt_j;
 
    // -------------------------------------------------------------------
    // Gestion des compteurs i / j pour adressage coord / cluster
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_i       <= '0;
            num_cluster <= '0;
            cnt_j       <= '0;
        end else begin
            case (current_state)
                S_IDLE: begin
                    cnt_i       <= '0;
                    num_cluster <= '0;
                end

                S_FETCH_I: begin
                    cnt_j <= cnt_i + 1'b1;
                end

                S_FETCH_WAIT: begin
                    if ((cnt_i != NB_POINTS-1) && (valid_cluster == 1'b1))
                            cnt_i <= cnt_i + 1'b1;   // on invrémente cnt_i si cluster_i est déjà attribué
                end

                S_WRITE_I: begin
                    if (cnt_i == NB_POINTS-1)
                        num_cluster <= num_cluster + 1'b1;
                end

                S_CHOICE_COMPUTE: begin
                    if (valid_cluster == 1'b1) begin          // j déjà labellisé -> on saute (pas de calcul)
                        if (cnt_j != NB_POINTS-1)
                            cnt_j <= cnt_j + 1'b1;
                        else begin
                            cnt_i       <= cnt_i + 1'b1;
                            num_cluster <= num_cluster + 1'b1;
                        end
                    end
                    // si cluster_in == -1 : on part en S_COMPUTE, c'est S_WRITE qui gèrera l'avancée de cnt_j / cnt_i
                end

                S_WRITE: begin
                    if (cnt_j != NB_POINTS - 1) begin
                        cnt_j <= cnt_j + 1'b1;
                    end else begin
                        cnt_i       <= cnt_i       + 1'b1;
                        num_cluster <= num_cluster + 1'b1;
                    end
                end
 
                default: begin
                    // cnt_i/cnt_j fixe
                end
            endcase
        end
    end

    assign cluster_out_i = num_cluster;

    // Compteur de vidage du pipeline
    localparam int PIPE_DEPTH = 2; // nb d'etages du pipeline
    logic [$clog2(PIPE_DEPTH+1)-1:0] drain_cnt;
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) drain_cnt <= '0;
        else if (current_state == S_DRAIN) drain_cnt <= drain_cnt + 1'b1;
        else drain_cnt <= '0;
    end
 
    // -------------------------------------------------------------------
    // FSM : transitions
    // -------------------------------------------------------------------
    logic valid_out;

    always_comb begin
        next_state = current_state;
        unique case (current_state)
            S_IDLE           : next_state = start ? S_FETCH_I : S_IDLE;
            S_FETCH_I        : next_state = S_FETCH_WAIT;
            S_FETCH_WAIT     : next_state = (valid_cluster == 1'b0) ? S_WRITE_I : (cnt_i == NB_POINTS-1) ? S_DRAIN : S_FETCH_I; // ici, cluster est cluster_i
            S_WRITE_I        : next_state = (cnt_i == NB_POINTS-1) ? S_DRAIN : S_FETCH_J; // écriture de cluster[i]
            S_FETCH_J        : next_state = S_CHOICE_COMPUTE; // écriture de cluster[i]
            S_CHOICE_COMPUTE : next_state = (valid_cluster == 1'b0) ? S_COMPUTE : (cnt_j == NB_POINTS-1) ? S_FETCH_I : S_FETCH_J;// ici, cluster est cluster_j
            S_COMPUTE        : next_state = (valid_out) ? S_WRITE : S_COMPUTE;
            S_WRITE          : next_state = (cnt_j != NB_POINTS - 1) ? S_FETCH_J : S_FETCH_I;
            S_DRAIN          : next_state = (drain_cnt == PIPE_DEPTH - 1) ? S_DONE : S_DRAIN;
            S_DONE           : next_state = S_IDLE;
            default          : next_state = S_IDLE;
        endcase
    end
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= S_IDLE;
        end else begin
            current_state <= next_state;
        end
    end

 
    assign done = (current_state == S_DONE);
 

    // -------------------------------------------------------------------
    // Tags de decalage : independants de l'etat courant, calcules a partir
    // de "quelle adresse a ete emise au cycle precedent"
    // -------------------------------------------------------------------

    logic  j_compute_start;
    assign j_compute_start = (current_state == S_CHOICE_COMPUTE) && (valid_cluster == 1'b0);


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
            j_valid_d   <= j_compute_start;
            j_idx_d     <= cnt_j;
            i_idx_d <= cnt_i;
        end
    end

    // -------------------------------------------------------------------
    // Capture de coord_X_i / coord_Y_i (independante de l'avancee du pipeline)
    // -------------------------------------------------------------------
    logic [COORD_W-1:0] coord_X_i, coord_Y_i;

    always_ff @(posedge clk) begin
        if (i_capture_d) begin
            coord_X_i <= coord_X;
            coord_Y_i <= coord_Y;
        end
    end


    // -------------------------------------------------------------------
    // Pipeline de calcul
    // -------------------------------------------------------------------
    logic signed [COORD_W:0] dx, dy;
    logic [ADDR_W-1:0]       i_1, j_1;
    logic                    valid_1;
 
    // Etage 1 -> 2 : carres
    logic [2*COORD_W-1:0] x_2, y_2;
    logic [ADDR_W-1:0]    i_2, j_2;
    logic                 valid_2;

    // Etage 2 -> 3 : D2 = x2 + y2
    logic [2*COORD_W:0] dist_sq;
    logic [ADDR_W-1:0]  i_3, j_3;
    logic               valid_3;

    logic [ADDR_W-1:0]  out_i, out_j;
    logic [ADDR_W-1:0] cluster_out_j;

    // maintnenant on ne détecte plus un cluster non initialisé comme étant à -1 mais avec son bit de valid
    // ce qui signifie que l'on ne doit pas réécrire -1 pour un cluster non initalisé car son bit de valid
    // est déjà à 1
    logic hit_j;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_1   <= 1'b0;
            valid_2   <= 1'b0;
            valid_3   <= 1'b0;
            valid_out <= 1'b0;
            hit_j     <= 1'b0;
        end else begin
                        
            // etage 0 -> sortie : delta = coord_i - coord_j;
            dx <= $signed({1'b0,coord_X_i}) - $signed({1'b0,coord_X});
            dy <= $signed({1'b0,coord_Y_i}) - $signed({1'b0,coord_Y});
            i_1     <= cnt_i;
            j_1     <= j_idx_d;
            valid_1 <= j_valid_d;
            

            // etage 1 -> sortie : carré
            x_2     <= dx * dx;
            y_2     <= dy * dy;
            i_2     <= i_1;
            j_2     <= j_1;
            valid_2 <= valid_1;
            
            
            // etage 2 -> sortie : dist_sq au carré
            dist_sq    <= x_2 + y_2;
            i_3     <= i_2;
            j_3     <= j_2;
            valid_3 <= valid_2;
            

            // etage 3 -> sortie : comparaison
            hit_j         <= (dist_sq <= TOL);
            cluster_out_j <= num_cluster;
            out_i         <= i_3;
            out_j         <= j_3;
            valid_out     <= valid_3;
            
        end
    end

    assign we_cluster = (valid_out && hit_j) || (current_state == S_WRITE_I);

    assign cluster_out = (current_state == S_WRITE_I) ? cluster_out_i : cluster_out_j;


endmodule

