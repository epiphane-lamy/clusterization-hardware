//=============================================================================
// Module: RAM2P_1024X32 (macro model)
//
// NOTE: RAM2P_1024X32 as instantiated here is an opaque black box, actually
// used in synthesis / place-and-route and characterized by its .lib and .lef
// views, not this Verilog.
//=============================================================================

module RAM2P_1024X32 #(
    parameter int ADDR_W = 10,      // Logical address width
    parameter int DATA_W = 32
	)(
    input  logic              CLKA,
    input  logic              CLKB,
    input  logic              CENA, // Chip Enable Port A (active low)
    input  logic              CENB, // Chip Enable Port B (active low)
    input  logic              WENA, // Write Enable Port A (active low)
    input  logic              WENB, // Write Enable Port B (active low)
    input  logic [ADDR_W-1:0] AA,   // Address Port A
    input  logic [ADDR_W-1:0] AB,   // Address Port B
    input  logic [DATA_W-1:0] DA,   // Data in Port A
    input  logic [DATA_W-1:0] DB,   // Data in Port B
    output logic [DATA_W-1:0] QA,   // Data out Port A
    output logic [DATA_W-1:0] QB    // Data out Port B
);

endmodule