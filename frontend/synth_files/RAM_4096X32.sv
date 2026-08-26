
//=============================================================================
// Module: RAM_4096X32 (macro model)
//
// NOTE: RAM_4096X32 as instantiated here is an opaque black box, actually
// used in synthesis / place-and-route and characterized by its .lib and .lef
// views, not this Verilog.
//=============================================================================

module RAM_4096X32 (
    input         CLK,
    input         CEN, // Chip Enable (active low)
    input         WEN, // Write Enable (active low)
    input  [11:0] A,   // Address
    input  [31:0] D,   // Data in
    output [31:0] Q    // Data out
);

endmodule