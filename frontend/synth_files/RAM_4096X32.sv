module RAM_4096X32 (
    input         CLK,
    input         CEN, // Chip Enable (active low)
    input         WEN, // Write Enable (active low)
    input  [11:0] A,   // Address
    input  [31:0] D,   // Data in
    output [31:0] Q    // Data out
);

endmodule