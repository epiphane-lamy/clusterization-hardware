
// mémoire macro
module RAM_4096X32 #(
    parameter int ADDR_W = 12,   // largeur de l'adresse
    parameter int DATA_W = 32
	)(
    input  logic              CLK,
    input  logic              CEN, // Chip Enable (active low)
    input  logic              WEN, // Write Enable (active low)
    input  logic [ADDR_W-1:0] A,   // Address
    input  logic [DATA_W-1:0] D,   // Data in
    output logic [DATA_W-1:0] Q    // Data out
);

    logic [DATA_W-1:0] memory [0:2**ADDR_W-1];

    always_ff @(posedge CLK) begin
        if (!CEN) begin
            Q <= memory[A];
            if (!WEN) begin
                memory[A] <= D;
            end
        end
    end

endmodule