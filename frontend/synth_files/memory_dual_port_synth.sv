//=============================================================================
// Module: memory_dual_port (ASIC macro-backed wrapper)
//
// Backs the same interface as the behavioral coordinate memory
// (rtl/memory_dual_port.sv) using the RAM_4096X32 ASIC
// memory macro. The macro is a single 32-bit-wide word with no notion of
// "two 16-bit fields" on its own -- this wrapper's only job is to pack a
// point's X/Y coordinates into (and back out of) that 32-bit word, and to
// translate the active-high `we` convention into the macro's active-low
// CEN/WEN control signals.
//
// See docs/blocks/coord_mem_wrapper.md for the full packing scheme, the
// CEN/WEN mapping, and the read/write timing equivalence with the
// behavioral model that this wrapper was resimulated against.
//
//=============================================================================

module memory_dual_port #(
    parameter int ADDR_W = 12, // Address width, fixed by the RAM_4096X32 macro's physical size
    parameter int DATA_W = 16  // Width of a single coordinate (X or Y)
	)(
    // General
    input  logic       clk,
    input  logic       rst_n,

    // memory access
    input  logic                we,
    input  logic [ADDR_W - 1:0] addr,
    input  logic [DATA_W - 1:0] data_in1,
    input  logic [DATA_W - 1:0] data_in2,
    
    output logic [DATA_W - 1:0] data_out1,
    output logic [DATA_W - 1:0] data_out2
);

    logic [31:0]  write_data;
    logic [31:0]  read_data;

    RAM_4096X32 u_ram (
        .CLK (clk),
        .CEN (1'b0),       // Permanently enabled
        .WEN (~we),        // we=1 -> WEN=0 -> write enabled
        .A   (addr),
        .D   (write_data),
        .Q   (read_data)
    );

    // Pack X (data_in1) into the upper half, Y (data_in2) into the lower half
    assign write_data[31:16] = data_in1;
    assign write_data[15:0]  = data_in2;

    assign data_out1 = read_data[31:16];
    assign data_out2 = read_data[15:0];

endmodule