//=============================================================================
// Module: memory_cluster (ASIC macro-backed wrapper)
//
// Backs the same interface as the behavioral cluster memory
// (rtl/memory_cluster.sv) using the RAM_4096X32 ASIC memory
// macro for the cluster number field only. The valid bits deliberately stay
// outside the macro, as a separate synchronously resettable flip-flop
// array -- a macro's contents are not guaranteed to be any known value at
// reset, so keeping the valid bits as real flip-flops is what makes
// ADR-0006's "valid = 0 at reset" guarantee actually hold once a real
// macro is in the picture. See docs/blocks/cluster_mem_wrapper.md.
//
//=============================================================================

module memory_cluster #(
    parameter int ADDR_W = 12 // Cluster address width, fixed by the RAM_4096X32 macro's physical size
	)(
    input  logic       clk,
    input  logic       rst_n,

    input  logic              we,
    input  logic [ADDR_W-1:0] addr,
    input  logic [ADDR_W-1:0] data_in,

    output logic              valid_cluster,
    output logic [ADDR_W-1:0] data_out
    );

    // Separate, synchronously resettable storage for the valid bits (see header)
    logic valid_array [0:(2**ADDR_W)-1];

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

    // Cluster number occupies the lower half; upper half unused (see
    // docs/blocks/cluster_mem_wrapper.md, known limitations).
    assign write_data[31:16] = '0;
    assign write_data[15:0]  = data_in;

    assign data_out = read_data[ADDR_W-1:0];


    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < (2**ADDR_W); i++) begin
                valid_array[i] <= 1'b0;
            end
            valid_cluster <= 1'b0;
        end else begin
            valid_cluster <= valid_array[addr];
            if (we) begin
                valid_array[addr] <= 1'b1;
            end
        end
    end


endmodule

