//=============================================================================
// Module: exp_LUT_v2 (simulation / behavioral)
//
// Lookup table for exp(x), used to compute the P_ij coefficient, see
// docs/blocks/exp_block.md section 5). The addres is derived directly from
// the argument's raw value. Content is generated in software from the same
// reference model referenced in ARCHITECTURE.md section 8, and loaded here
// via $readmemh for RTL simulation. 
//
// This version provides two independent read ports, allowing two LUT values
// to be read in the same cycle. This is required by the
// dist_mat_arg_exp_v2 module (see docs/ADR/<...>.md).
//
//
// This is the BEHAVIORAL version, used for simulation only. The
// synthesizable counterpart (same interface, same content, but expressed
// as an explicit case statement instead of $readmemh) lives under
// frontend/synth_files/exp_LUT_synth.sv and is used for synthesis / the ASIC
// flow.
//=============================================================================

module exp_LUT_v2 #(
    parameter INDEX_W = 14
)(
    input  logic                 clk,
    input  logic                 rst_n,

    // exp_LUT port a
    input  logic [INDEX_W-1:0]   index_a,
    output logic [15:0]          result_exp_a,

    // exp_LUT port b
    input  logic [INDEX_W-1:0]   index_b,
    output logic [15:0]          result_exp_b
);

    logic [15:0] rom [0:10240];

    initial begin
        $readmemh("data/exp_lut.hex", rom);
    end

    always_ff @(posedge clk) begin
        result_exp_a <= rom[index_a];
        result_exp_b <= rom[index_b];
    end

endmodule