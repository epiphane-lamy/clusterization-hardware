//=============================================================================
// Module: exp_LUT (simulation / behavioral)
//
// Lookup table for exp(x), used to compute the P_ij coefficient, see
// docs/blocks/exp_block.md section 5). The addressi is derived directly from
// the argument's raw value. Content is generated in software from the same
// reference model referenced in ARCHITECTURE.md section 8, and loaded here
// via $readmemh for RTL simulation.
//
// This is the BEHAVIORAL version, used for simulation only. The
// synthesizable counterpart (same interface, same content, but expressed
// as an explicit case statement instead of $readmemh) lives under
// frontend/synth_files/exp_LUT_synth.sv and is used for synthesis / the ASIC
// flow.
//=============================================================================

module exp_LUT #(
    parameter INDEX_W = 14
)(
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic [INDEX_W-1:0]   index,
    output logic [15:0]          result_exp
);

    logic [15:0] rom [0:10240];

    initial begin
        $readmemh("data/exp_lut.hex", rom);
    end

    always_ff @(posedge clk) begin
        result_exp <= rom[index];
    end

endmodule