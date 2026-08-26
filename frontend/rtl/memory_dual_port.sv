//=============================================================================
// Module: memory_dual_port (behavioral model)
//
// Simulation implementation of the coordinate-storage memory: one
// address stores a point's X and Y coordinates together (data_in1/data_in2
// in, data_out1/data_out2 out), with unconditional synchronous read and a
// write gated by we.
//
// This module shares its name and port list with the ASIC macro-backed
// wrapper (synth_files/memory_dual_port_synth.sv) so that switching targets
// requires no change anywhere else in the design. See
// docs/blocks/coord_mem_wrapper.md for the full comparison.
//=============================================================================

module memory_dual_port #(
    parameter int ADDR_W = 12, // Address width
    parameter int DATA_W = 16  // Width of a single coordinate (X or Y)
	)(
    // General
    input  logic       clk,
    input  logic       rst_n,

    // memory access
    input  logic       we,
    input  logic [ADDR_W - 1:0] addr,
    input  logic [DATA_W - 1:0] data_in1,
    input  logic [DATA_W - 1:0] data_in2,
    
    output logic [DATA_W - 1:0] data_out1,
    output logic [DATA_W - 1:0] data_out2
);

    // One address, two words (a point's X and Y coordinate stored together)
    logic [DATA_W - 1:0] memory [0:2**ADDR_W - 1][0:1];


    always_ff @(posedge clk) begin
        data_out1 <= memory[addr][0];
        data_out2 <= memory[addr][1];
        if (we) begin
            memory[addr][0] <= data_in1;
            memory[addr][1] <= data_in2;
        end
    end
endmodule