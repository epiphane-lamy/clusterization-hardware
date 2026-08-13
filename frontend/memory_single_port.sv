
module memory_single_port #(
    parameter int ADDR_W = 7,   // largeur de l'adresse
    parameter int DATA_W = 8
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

    // structure du memory 8 voies à 2 index
    logic [DATA_W - 1:0] memory [0:2**ADDR_W - 1];


    always_ff @(posedge clk) begin
        data_out <= memory[addr];
        if (we) begin
            memory[addr] <= data_in;
        end
    end
endmodule