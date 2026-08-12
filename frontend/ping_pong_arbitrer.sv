

module ping_pong_arbitrer #(
    parameter int COORD_W = 16,
    parameter int ADDR_W  = 7
)(
    input  logic clk,
    input  logic rst_n,

    input  logic                valid_p_ij_exp, // valid_out de dist_mat_arg_exp
    input  logic [ADDR_W-1:0]   out_i_exp,      // out_i de dist_mat_arg_exp
    input  logic                line_done_grad, // done de norm_entropy_grad

    input  logic [ADDR_W-1:0]   addr_P_ij_w,
    input  logic [COORD_W-1:0]  P_ij_w,

    input  logic [ADDR_W-1:0]   addr_P_ij_r,
    output logic [COORD_W-1:0]  P_ij_r,

    output logic [ADDR_W-1:0]   addr_A,
    output logic                we_A,
    output logic [COORD_W-1:0]  w_data_A,
    input  logic [COORD_W-1:0]  r_data_A,

    output logic [ADDR_W-1:0]   addr_B,
    output logic                we_B,
    output logic [COORD_W-1:0]  w_data_B,
    input  logic [COORD_W-1:0]  r_data_B,

    output logic credit_avail
);

    logic [1:0] cnt_credit;
    logic       write_buf_sel; // dérivé directement de la parité de out_i : aucun registre, zéro dérive
    logic       read_buf_sel;  // toggle, ne bouge QUE quand grad a réellement fini sa ligne
    logic       row_start_exp; // pulse : 1er élément (j=0) d'une nouvelle ligne écrite par exp

    assign row_start_exp = valid_p_ij_exp && (addr_P_ij_w == '0);
    assign write_buf_sel = out_i_exp[0];

    // --- crédit : consommé AU DEMARRAGE d'une ligne (entrée, synchro avec la FSM),
    //     jamais sur un signal retardé côté sortie -> pas de skew possible
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt_credit <= 2'd2;
        else begin
            unique case ({row_start_exp, line_done_grad})
                2'b10:   cnt_credit <= cnt_credit - 1'b1;
                2'b01:   cnt_credit <= cnt_credit + 1'b1;
                default: cnt_credit <= cnt_credit;
            endcase
        end
    end
    assign credit_avail = (cnt_credit != 2'd0); // niveau permanent


    // --- bascule de lecture : uniquement pilotée par la fin réelle de grad
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) read_buf_sel <= 1'b0;
        else if (line_done_grad) read_buf_sel <= ~read_buf_sel;
    end

    // --- mux : écriture prioritaire sur le bus quand elle est active ---
    always_comb begin
        addr_A = (read_buf_sel == 1'b0) ? addr_P_ij_r : '0;
        addr_B = (read_buf_sel == 1'b1) ? addr_P_ij_r : '0;
        we_A = 1'b0; we_B = 1'b0;
        w_data_A = '0; w_data_B = '0;

        if (write_buf_sel == 1'b0) begin
            we_A = valid_p_ij_exp;
            w_data_A = P_ij_w;
            if (valid_p_ij_exp) addr_A = addr_P_ij_w;
        end else begin
            we_B = valid_p_ij_exp;
            w_data_B = P_ij_w;
            if (valid_p_ij_exp) addr_B = addr_P_ij_w;
        end
    end

    assign P_ij_r = (read_buf_sel == 1'b0) ? r_data_A : r_data_B;


/*
    logic write_buf_sel_d, read_buf_sel_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_buf_sel_d <= write_buf_sel;
            read_buf_sel_d  <= read_buf_sel;
        end else begin
            if ((write_buf_sel != write_buf_sel_d) ||
                (read_buf_sel  != read_buf_sel_d)) begin

                $display("[%0t] #####CHANGEMENT : write=%s read=%s#####",
                    $time,
                    write_buf_sel ? "B" : "A",
                    read_buf_sel  ? "B" : "A");
            end

            write_buf_sel_d <= write_buf_sel;
            read_buf_sel_d  <= read_buf_sel;
        end
    end*/

endmodule




/*
module ping_pong_arbitrer #(
    parameter int COORD_W      = 16, // largeur des P_ij
    parameter int ADDR_W       = 7   // largeur des adresses P_ij
)(
	input  logic clk,
	input  logic rst_n,

    input logic valid_p_ij_exp,   // pulse par élément, qualifie l'écriture (= valid_out de dist_mat_arg_exp)
    input logic line_done_exp,    // pulse de fin de ligne (= valid_sum_row_P), pour credit/config
    input logic line_done_grad,   // pulse de fin de ligne côté grad (= done)

    // addr P_ij + P_ij à écrire (bloc exp)
    input logic [ADDR_W-1:0]    addr_P_ij_w,
    input logic [COORD_W - 1:0] P_ij_w,

    // addr P_ij + P_ij à lire (bloc grad)
    input logic [ADDR_W-1:0]    addr_P_ij_r,
    output logic [COORD_W - 1:0] P_ij_r,

    // vers BRAM A
    output logic [ADDR_W-1:0]    addr_A,
    output logic                 we_A,
    output logic [COORD_W-1:0]   w_data_A,
    input  logic [COORD_W-1:0]   r_data_A,

    // vers BRAM B
    output logic [ADDR_W-1:0]    addr_B,
    output logic                 we_B,
    output logic [COORD_W-1:0]   w_data_B,
    input  logic [COORD_W-1:0]   r_data_B,

    output logic credit_avail
);

	// -------------------------------------------------------------------
    // FSM du ping_pong_arbitrer entre les deux blocs mémoire
    // -------------------------------------------------------------------
    typedef enum logic {
        CONFIG_1,       // mémoire 1 attribué au bloc exp && mémoire 2 attribué au bloc grad
        CONFIG_2        // mémoire 2 attribué au bloc exp && mémoire 1 attribué au bloc grad
    } state_t;
 
    state_t current_state, next_state;
 
    logic [1:0] cnt_credit;

    logic change;
    

 
    // -------------------------------------------------------------------
    // Gestiond du compteur de crédit
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_credit <= 2;
        end else begin
            if (line_done_exp == 1)
                cnt_credit -= 1;
            if (line_done_grad == 1)
                cnt_credit += 1;
        end
    end


    // -------------------------------------------------------------------
    // Adressages des BRAM A et B
    // -------------------------------------------------------------------
    always_comb begin
        we_A = 1'b0; we_B = 1'b0;
        addr_A = '0; addr_B = '0;
        w_data_A = '0; w_data_B = '0;
        unique case (current_state)
            CONFIG_1: begin
                addr_A   = addr_P_ij_w;
                we_A     = valid_p_ij_exp;
                w_data_A = P_ij_w;
                addr_B   = addr_P_ij_r;
            end
            CONFIG_2: begin
                addr_B   = addr_P_ij_w;
                we_B     = valid_p_ij_exp;
                w_data_B = P_ij_w;
                addr_A   = addr_P_ij_r;
            end
        endcase
    end

    assign P_ij_r = (current_state == CONFIG_1) ? r_data_B : r_data_A;

 
    // -------------------------------------------------------------------
    // FSM : transitions
    // -------------------------------------------------------------------
    always_comb begin
        next_state = current_state;
        unique case (current_state)
            CONFIG_1 : next_state = change ? CONFIG_2 : CONFIG_1;
            CONFIG_2 : next_state = change ? CONFIG_1 : CONFIG_2;
            default  : next_state = CONFIG_1;
        endcase
    end

    //assign change = line_done_exp; // pulse d'1 cycle en fin de ligne exp
    
    logic pending_exp;
    logic pending_grad;
    logic first_line;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_exp  <= 1'b0;
            pending_grad <= 1'b0;
            change       <= 1'b0;
            first_line   <= 1'b1;
        end else begin
            change       <= 1'b0;
            
            if (first_line) begin
                if (line_done_exp) begin
                    change     <= 1'b1;
                    first_line <= 1'b0;
                end
            end else begin
                if (line_done_exp || pending_exp) begin
                    pending_exp <= 1'b1;
                    if (line_done_grad)begin
                        change       <= 1'b1;
                        pending_exp  <= 1'b0;
                    end
                end
            end            
        end
    end

    assign credit_avail = ((cnt_credit != 2'd0) && change);
    logic pending_exp;
    logic pending_grad;
    logic first_line;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_exp  <= 1'b0;
            pending_grad <= 1'b0;
            change       <= 1'b0;
            first_line   <= 1'b1;
        end else begin
            change       <= 1'b0;
            
            if (first_line) begin
                if (line_done_exp) begin
                    change     <= 1'b1;
                    first_line <= 1'b0;
                end
            end else begin
                if (line_done_exp || pending_exp) begin
                    pending_exp <= 1'b1;
                    if (line_done_grad)begin
                        change       <= 1'b1;
                        pending_exp  <= 1'b0;
                    end
                end
            end            
        end
    end

    assign credit_avail = change;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) current_state <= CONFIG_1;
        else        current_state <= next_state;
    end

endmodule

*/