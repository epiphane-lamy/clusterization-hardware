//=============================================================================
// Module: act_coord  ("upd block")
//
// Applies the per-point update contribution (mult_act_X/Y, produced by the
// grad block and staged in memory mult_upd) to the current coordinates, one
// point at a time: coord_act = coord + mult_act.
//
// addr_coord / we_coord / coord_X_act / coord_Y_act are broadcast at the
// toplevel to BOTH duplicated coordinate memories (the exp-side and
// grad-side copies from ADR-0003) at once -- this is what keeps the two
// copies identical without any extra synchronization step: this block reads
// from one copy and writes the same update to both.
//
// Processes points sequentially through a plain FETCH/COMPUTE/WRITE loop
// rather than a pipeline, unlike exp/grad -- because the same memory is
// alternately read from and written to for each point.
//
// See docs/blocks/upd_block.md for the full block-level documentation.
//=============================================================================


module act_coord #(
    parameter int NB_POINTS    = 8,   // Number of points. Fixed default for now, see docs/blocks/exp.md, known limitations.
    parameter int COORD_W      = 16,  // Coordinate width, signed fixed-point
    parameter int ADDR_W       = 7,
    parameter int ACT_W        = 32
    )(
    input  logic               clk,
    input  logic               rst_n,
 
    input logic                start,     // Launches the update pass over all NB_POINTS points
 
    // --- Point coordinate BRAM port (broadcast write, see header) ---
    output logic [ADDR_W-1:0]  addr_coord,
    output logic               we_coord,
    input  logic [COORD_W-1:0] coord_X,
    input  logic [COORD_W-1:0] coord_Y,
 
    output logic [COORD_W-1:0] coord_X_act,
    output logic [COORD_W-1:0] coord_Y_act,
 
    // --- mult_upd BRAM port ---
    output logic [ADDR_W-1:0]  addr_act,
    input  logic signed [ACT_W-1:0] mult_act_X,
    input  logic signed [ACT_W-1:0] mult_act_Y,
    output logic done
);


    // -------------------------------------------------------------------
    // Sequencing FSM
    // -------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE,    // Idle, waiting for start
        S_FETCH,   // Issue addr = cnt_i to read the current coordinate and mult_act
        S_COMPUTE, // Compute the updated coordinate
        S_WRITE,   // Issue addr = cnt_i to write the updated coordinate back
        S_DONE     // Update pass complete
    } state_t;
    state_t current_state, next_state;
    logic [ADDR_W-1:0] cnt_i;
 
    // -------------------------------------------------------------------
    // Point / mult_upd address generation
    // -------------------------------------------------------------------
    assign addr_coord = cnt_i;
    assign addr_act = cnt_i;
 
    // -------------------------------------------------------------------
    // i counter management
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
                    // cnt_i held
                end
            endcase
        end
    end

    assign we_coord = (current_state == S_WRITE) ? 1 : 0;
 
    // -------------------------------------------------------------------
    // FSM: transition logic
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
    // Coordinate update: coord_act = coord + mult_act (see docs/blocks/
    // upd_block.md).
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