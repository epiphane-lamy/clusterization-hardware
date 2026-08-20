

module memory_dual_port #(
    parameter int ADDR_W = 12,   // largeur de l'adresse
    parameter int DATA_W = 16
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
        .CEN (1'b0),
        .WEN (~we),
        .A   (addr),
        .D   (write_data),
        .Q   (read_data)
    );


    assign write_data[31:16] = data_in1;
    assign write_data[15:0]  = data_in2;

    assign data_out1 = read_data[31:16];
    assign data_out2 = read_data[15:0];

endmodule