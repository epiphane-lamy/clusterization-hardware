
// mémoire custom pour simu rtl
module memory_dual_port #(
    parameter int ADDR_W = 12,   // largeur de l'adresse
    parameter int DATA_W = 16
	)(
    // General
    input  logic       clk,
    input  logic       rst_n,

    // memory access
    input  logic       we,
    input  logic [ADDR_W - 1:0] addr,
    input  logic [DATA_W - 1:0] data_in1,
    input  logic [DATA_W - 1:0] data_in2,
    
    output logic [DATA_W - 1:0] data_out1,
    output logic [DATA_W - 1:0] data_out2
);

    // structure du memory 8 voies à 2 index
    logic [DATA_W - 1:0] memory [0:2**ADDR_W - 1][0:1];


    always_ff @(posedge clk) begin
        data_out1 <= memory[addr][0];
        data_out2 <= memory[addr][1];
        if (we) begin
            memory[addr][0] <= data_in1;
            memory[addr][1] <= data_in2;
        end
    end
endmodule