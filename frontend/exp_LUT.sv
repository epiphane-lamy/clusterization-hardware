module exp_LUT #(
    parameter INDEX_W = 14
)(
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic [INDEX_W-1:0]   index,
    output logic [15:0]          result_exp
);

    logic [15:0] rom [0:10240];

    initial begin
        $readmemh("exp_lut.hex", rom);
    end

    always_ff @(posedge clk) begin
        result_exp <= rom[index];
    end

endmodule