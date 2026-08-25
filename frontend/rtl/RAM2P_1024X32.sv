module RAM2P_1024X32 #(
    parameter int ADDR_W = 10,   // largeur de l'adresse
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

    logic [DATA_W-1:0] memory [0:2**ADDR_W-1];

    always_ff @(posedge CLKA) begin
        if (!CENA) begin
            QA <= memory[AA];
            if (!WENA) begin
                memory[AA] <= DA;
            end
        end
    end

    always_ff @(posedge CLKB) begin
        if (!CENB) begin
            QB <= memory[AB];
            if (!WENB) begin
                memory[AB] <= DB;
            end
        end
    end


endmodule