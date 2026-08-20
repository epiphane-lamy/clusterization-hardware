module RAM2P_1024X32 (
    input         CLKA,
    input         CLKB,
    input         CENA, // Chip Enable Port A (active low)
    input         CENB, // Chip Enable Port B (active low)
    input         WENA, // Write Enable Port A (active low)
    input         WENB, // Write Enable Port B (active low)
    input  [9:0]  AA,   // Address Port A
    input  [9:0]  AB,   // Address Port B
    input  [31:0] DA,   // Data in Port A
    input  [31:0] DB,   // Data in Port B
    output [31:0] QA,   // Data out Port A
    output [31:0] QB    // Data out Port B
);

endmodule