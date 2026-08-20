

module memory_single_port #(
    parameter int ADDR_W = 10,   // largeur de l'adresse
    parameter int DATA_W = 16
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

    logic [ADDR_W - 1:0]  adress;
    logic [(2*DATA_W)-1:0]  write_data;
    logic [(2*DATA_W)-1:0]  read_data;

    // only port A is used
    RAM2P_1024X32 u_ram (
        .CLKA (clk),
        .CLKB (clk),
        .CENA (1'b0),
        .CENB (1'b1),
        .WENA (~we),
        .WENB (1'b1),
        .AA   (adress),
        .AB   ('0),
        .DA   (write_data),
        .DB   (),
        .QA   (read_data),
        .QB   ()
    );

    assign adress = (addr >> 1);

    logic [DATA_W - 1:0] data_reg;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_reg <= '0;
        end else begin
            if (we) begin
                if (addr[0] == 1'b0) begin
                    data_reg <= data_in;
                end
            end
        end
    end


    always_comb begin
        if (addr[0] == 1'b0) data_out = read_data[31:16];
        if (addr[0] == 1'b1) data_out = read_data[15:0];
    end

    assign write_data = {data_reg, data_in};

endmodule
