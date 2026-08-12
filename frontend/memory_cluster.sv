
module memory_cluster #(
    parameter int ADDR_W = 7           // largeur des adresses clusters
	)(
    input  logic       clk,
    input  logic       rst_n,

    input  logic              we,
    input  logic [ADDR_W-1:0] addr,
    input  logic [ADDR_W-1:0] data_in,

    output logic              valid_cluster,
    output logic [ADDR_W-1:0] data_out
    );

    //------------------------------------------------------------------------------
    // Memory cluster
    //
    // Stores the number of each cluster
    //
    // Memory accesses are synchronous. The read address is registered so that the
    // data is available with a one-cycle read latency.
    //
    // Valid bits are stored separately from the cache data so that they can be
    // reset independently (valid_cluster = 0 means cluster non initialised)
    //------------------------------------------------------------------------------
    
    logic [ADDR_W-1:0] cluster [0:(2**ADDR_W)-1];

    // Separate resettable storage for the valid bits
    logic valid_array [0:(2**ADDR_W)-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < (2**ADDR_W); i++) begin
                valid_array[i] <= 1'b0;
            end
            valid_cluster <= 1'b0;
            data_out      <= '0;
        end else begin
            valid_cluster <= valid_array[addr];
            data_out      <= cluster[addr];

            if (we) begin
                cluster[addr] <= data_in;
                valid_array[addr] <= 1'b1;
            end
        end
    end


endmodule

