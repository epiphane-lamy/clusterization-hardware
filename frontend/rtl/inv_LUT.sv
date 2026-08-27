//=============================================================================
// Module: inv_LUT (simulation / behavioral)
//
// Lookup table for 1/x, used to complete row normalization (P_ij_norm =
// (P_ij * inv[mantissa]) >> msb, see docs/blocks/grad_block.md section 5).
// Unlike exp_LUT, addressing here is by the MANTISSA of the row sum
// (top INDEX_W bits after MSB-aligning it), not by the sum's raw value --
// this is what lets a fixed 1024-entry table cover the sum's wide dynamic
// range (see ADR-0004). Content is generated in software from the same
// reference model referenced in ARCHITECTURE.md section 8, and loaded here
// via $readmemh for RTL simulation.
//
// This is the BEHAVIORAL version, used for simulation only. The
// synthesizable counterpart (same interface, same content, but expressed
// as an explicit case statement instead of $readmemh) lives under
// frontend/synth_files/inv_LUT_synth.sv and is used for synthesis / the ASIC
// flow.
//=============================================================================

module inv_LUT #(
    parameter INDEX_W = 10
)(
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic [INDEX_W-1:0]   index,
    output logic [15:0]          result_inv
);

    logic [15:0] rom [0:1023];

    initial begin
        $readmemh("data/inv_lut.hex", rom);
    end

    always_ff @(posedge clk) begin
        result_inv <= rom[index];
    end

endmodule