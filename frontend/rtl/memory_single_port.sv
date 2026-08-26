//=============================================================================
// Module: memory_single_port (behavioral model)
//
// Simulation implementation of the P_ij row storage memory: plain
// single-port RAM, unconditional synchronous read, write gated by we.
//
// Shares its name and port list with the ASIC macro-backed wrapper
// (synth_files/memory_single_port_synth.sv) so that switching targets requires
// no change anywhere else in the design. See docs/blocks/pij_mem_wrapper.md
// for the full comparison.
//=============================================================================

module memory_single_port #(
    parameter int ADDR_W = 7, // Address width
    parameter int DATA_W = 8  // Data width (P_ij value)
	)(
    // General
    input  logic       clk,
    input  logic       rst_n,

    // memory access
    input  logic                we,
    input  logic [ADDR_W - 1:0] addr,
    input  logic [DATA_W - 1:0] data_in,
    
    output logic [DATA_W - 1:0] data_out
);

    logic [DATA_W - 1:0] memory [0:2**ADDR_W - 1];


    always_ff @(posedge clk) begin
        data_out <= memory[addr];
        if (we) begin
            memory[addr] <= data_in;
        end
    end
endmodule