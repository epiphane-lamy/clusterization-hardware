module inv_LUT #(
    parameter INDEX_W = 10
)(
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic [INDEX_W-1:0]   index,
    output logic [15:0]          result_inv
);

    logic [15:0] rom [0:1023];

    initial begin
        $readmemh("data/inv_lut.hex", rom);
    end

    always_ff @(posedge clk) begin
        result_inv <= rom[index];
    end

endmodule