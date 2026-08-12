
module act_coord #(
    parameter int NB_POINTS    = 8,           // nombre de points stockés en dur, prochainement chargé au début du calcul <= 2**ADDR_W
    parameter int COORD_W      = 16,           // largeur des coordonnees, fixed-point SIGNE
    parameter int ADDR_W       = 7
    )(
	input  logic               clk,
	input  logic               rst_n,

    input logic                start,     // lance le balayage complet d'un step

    // --- Port BRAM point (adresse incrementee chaque cycle) ---
    output logic [ADDR_W-1:0]  addr_coord,
	output logic               we_coord,
    input  logic [COORD_W-1:0] coord_X,
    input  logic [COORD_W-1:0] coord_Y,

    output logic [COORD_W-1:0] coord_X_act,
    output logic [COORD_W-1:0] coord_Y_act,

    // --- Port BRAM mult_act (adresse incrementee chaque cycle) ---
    output logic [ADDR_W-1:0]  addr_act,
    input  logic signed [31:0] mult_act_X,
    input  logic signed [31:0] mult_act_Y,
 
    output logic done
);



    // -------------------------------------------------------------------
    // FSM de sequencement
    // -------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE,    // état initial
        S_FETCH,   // emission addr = cnt_i pour lecture points + mult_act
        S_COMPUTE, // calcul de l'actualisation
        S_WRITE,   // emission addr = cnt_i pour écriture points + mult_act
        S_DONE     // calcul terminé
    } state_t;
 
    state_t current_state, next_state;
 
 
    logic [ADDR_W-1:0] cnt_i;

 
    // -------------------------------------------------------------------
    // Adressage BRAM points / valeur d'actualisation
    // -------------------------------------------------------------------
    assign addr_coord = cnt_i;
    assign addr_act = cnt_i;

 
    // -------------------------------------------------------------------
    // Gestiond du compteur j pour adressage
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_i <= '0;
        end else begin
            case (current_state)
                S_IDLE: begin
                    cnt_i <= '0;
                end
 
                S_WRITE: begin
                    if (cnt_i != NB_POINTS - 1)
                        cnt_i <= cnt_i + 1'b1;
                end
 
                default: begin
                    // cnt_i fixe
                end
            endcase
        end
    end

    assign we_coord = (current_state == S_WRITE) ? 1 : 0;
 
    // -------------------------------------------------------------------
    // FSM : transitions
    // -------------------------------------------------------------------
    always_comb begin
        next_state = current_state;
        unique case (current_state)
            S_IDLE    : next_state = start ? S_FETCH : S_IDLE;
            S_FETCH   : next_state = S_COMPUTE;
            S_COMPUTE : next_state = S_WRITE;
            S_WRITE   : next_state = (cnt_i == NB_POINTS - 1) ? S_DONE : S_FETCH;
            S_DONE    : next_state = S_IDLE;
            default   : next_state = S_IDLE;
        endcase
    end
 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) current_state <= S_IDLE;
        else        current_state <= next_state;
    end
 
    assign done = (current_state == S_DONE);


    // -------------------------------------------------------------------
    // Compute de l'actualisation des points
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            coord_X_act <= '0;
            coord_Y_act <= '0;
        end else if (current_state == S_COMPUTE) begin
            coord_X_act <= ($signed({1'b0, coord_X}) + mult_act_X);
            coord_Y_act <= ($signed({1'b0, coord_Y}) + mult_act_Y);
        end
    end

    


endmodule