//=============================================================================
// Module: ping_pong_arbiter
//
// Arbitrates access to the two P_ij row buffers (A / B) that implement the
// ping-pong scheme between the exp block (writer) and the grad block
// (reader): while exp writes the row currently in flight into one buffer,
// grad reads the previous, already-completed row out of the other one.
//
// This module owns no storage itself. It only:
//   - routes exp's write requests to the correct physical buffer, based on
//     the parity of the row index currently being written (see write_buf_sel
//     below);
//   - routes grad's read requests to the correct physical buffer, toggled
//     each time grad finishes reading a row (see read_buf_sel below);
//   - tracks, via a 2-credit counter, how many buffers are currently free
//     for exp to write into, exposed as credit_avail.
//
// credit_avail directly gates exp's row advancement (see dist_mat_arg_exp,
// state S_LAST_WAIT) -- exp is not allowed to start writing a new row until
// this arbiter confirms a buffer is free.
//
// Related design decision: ADR-0003 (ping-pong buffering / credit-based
// flow control). See docs/blocks/ping_pong_arbiter.md for the full
// block-level documentation.
//=============================================================================


module ping_pong_arbiter #(
    parameter int ADDR_W = 16,
    parameter int P_IJ_W = 16,
    parameter int ADDR_P_IJ_W  = 7
)(
    input  logic clk,
    input  logic rst_n,

    input  logic                   valid_p_ij_exp, // valid_out from dist_mat_arg_exp
    input  logic [ADDR_W-1:0]      out_i_exp,      // out_i from dist_mat_arg_exp
    input  logic                   line_done_grad, // done from norm_entropy_grad

    input  logic [ADDR_P_IJ_W-1:0] addr_P_ij_w,
    input  logic [P_IJ_W-1:0]      P_ij_w,

    input  logic [ADDR_P_IJ_W-1:0] addr_P_ij_r,
    output logic [P_IJ_W-1:0]      P_ij_r,

    output logic [ADDR_P_IJ_W-1:0] addr_A,
    output logic                   we_A,
    output logic [P_IJ_W-1:0]      w_data_A,
    input  logic [P_IJ_W-1:0]      r_data_A,

    output logic [ADDR_P_IJ_W-1:0] addr_B,
    output logic                   we_B,
    output logic [P_IJ_W-1:0]      w_data_B,
    input  logic [P_IJ_W-1:0]      r_data_B,

    output logic credit_avail
);

    logic [1:0] cnt_credit;
    logic       write_buf_sel; // Derived directly from the parity of out_i: no dedicated
                               // register, so it can never drift out of sync with the row
                               // actually being written.
    logic       read_buf_sel;  // Registered toggle, flipped only when grad has genuinely
                               // finished reading its current row.
    logic       row_start_exp; // One-cycle pulse: first element (j=0) of a new row being
                               // written by exp.


    assign row_start_exp = valid_p_ij_exp && (addr_P_ij_w == '0);
    assign write_buf_sel = out_i_exp[0];

    // -------------------------------------------------------------------
    // Credit counter: consumed at the START of a row (input side, in sync
    // with exp's own FSM), never on a signal delayed further down the
    // pipeline -- no skew possible between "a new row starts" and "a
    // credit is spent". Released when grad reports a row fully consumed.
    // -------------------------------------------------------------------
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
    assign credit_avail = (cnt_credit != 2'd0); // Level signal, not a pulse


    // -------------------------------------------------------------------
    // Read-side buffer toggle: only ever moved by grad's actual completion
    // of a row, never inferred or predicted.
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) read_buf_sel <= 1'b0;
        else if (line_done_grad) read_buf_sel <= ~read_buf_sel;
    end

    // -------------------------------------------------------------------
    // Address / write-enable mux per buffer. Default each buffer's address
    // to the current read request if it is the buffer currently selected
    // for reading; then, if that same buffer is also the one currently
    // selected for writing, override with the write request -- write
    // always takes priority on a buffer's shared bus when active.
    // -------------------------------------------------------------------
    always_comb begin
        addr_A = (read_buf_sel == 1'b0) ? addr_P_ij_r : '0;
        addr_B = (read_buf_sel == 1'b1) ? addr_P_ij_r : '0;
        we_A   = 1'b0; we_B = 1'b0;
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


endmodule
