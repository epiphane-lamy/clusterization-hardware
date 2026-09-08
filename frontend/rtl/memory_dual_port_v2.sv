//=============================================================================
// Module: memory_dual_port_v2 (behavioral model)
//
// Simulation model of the coordinate-storage memory. Each address stores a
// point's X and Y coordinates together (data_in1/data_in2), with the
// corresponding coordinates available on data_out1/data_out2.
//
// The memory provides synchronous read access and a write operation gated by
// 'we'.
//
// This module implements a true dual-port memory, allowing the two computing
// blocks (exp block and grad block) to access the same memory concurrently.
// Previously, the memory_dual_port module was instantiated twice, resulting
// in two separate copies of the memory. Despite its name, the previous
// module was not actually dual-port.
//
// This module shares its name and port list with the ASIC macro-backed
// wrapper (synth_files/memory_dual_port_v2_synth.sv), so that switching between
// simulation and ASIC targets requires no changes elsewhere in the design.
//
// See docs/blocks/coord_mem_wrapper.md for the full comparison.
//=============================================================================


module memory_dual_port_v2 #(
    parameter int ADDR_W = 12, // Address width
    parameter int DATA_W = 16  // Width of a single coordinate (X or Y)
	)(
    // General
    input  logic       clk,
    input  logic       rst_n,

    // memory access port a
    input  logic                we_a,
    input  logic [ADDR_W - 1:0] addr_a,
    input  logic [DATA_W - 1:0] data_in_x_a,
    input  logic [DATA_W - 1:0] data_in_y_a,
    
    output logic [DATA_W - 1:0] data_out_x_a,
    output logic [DATA_W - 1:0] data_out_y_a,

    // memory access port b
    input  logic                we_b,
    input  logic [ADDR_W - 1:0] addr_b,
    input  logic [DATA_W - 1:0] data_in_x_b,
    input  logic [DATA_W - 1:0] data_in_y_b,
    
    output logic [DATA_W - 1:0] data_out_x_b,
    output logic [DATA_W - 1:0] data_out_y_b
);

    // One address, two coordinates (a point's X and Y coordinate stored together)
    logic [DATA_W - 1:0] memory [0:2**ADDR_W - 1][0:1];


    always_ff @(posedge clk) begin
        data_out_x_a <= memory[addr_a][0];
        data_out_y_a <= memory[addr_a][1];
        if (we_a) begin
            memory[addr_a][0] <= data_in_x_a;
            memory[addr_a][1] <= data_in_y_a;
        end
    end

    always_ff @(posedge clk) begin
        data_out_x_b <= memory[addr_b][0];
        data_out_y_b <= memory[addr_b][1];
        if (we_b) begin
            memory[addr_b][0] <= data_in_x_b;
            memory[addr_b][1] <= data_in_y_b;
        end
    end

endmodule