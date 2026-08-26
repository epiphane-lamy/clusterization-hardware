//=============================================================================
// Module: memory_cluster (behavioral model)
//
// Stores the cluster number assigned to each point (see docs/blocks/
// cluster_assign.md). Valid bits are stored separately from the cluster
// data so that they can be reset independently (valid_cluster = 0 means
// the point's cluster is not yet assigned, see ADR-0006).
//
// Memory accesses are synchronous. The read address is registered so that
// data is available with a one-cycle read latency.
//
// Shares its name and port list with the ASIC macro-backed wrapper
// (synth_files/memory_cluster_synth.sv) so that switching targets requires no
// change anywhere else in the design. See docs/blocks/cluster_mem_wrapper.md
// for the full comparison, including why the valid bits specifically stay
// as flip-flops rather than moving into the macro.
//=============================================================================

module memory_cluster #(
    parameter int ADDR_W = 7   // Address width
	)(
    input  logic       clk,
    input  logic       rst_n,

    input  logic              we,
    input  logic [ADDR_W-1:0] addr,
    input  logic [ADDR_W-1:0] data_in,

    output logic              valid_cluster,
    output logic [ADDR_W-1:0] data_out
    );

    logic [ADDR_W-1:0] cluster [0:(2**ADDR_W)-1];

    // Separate, synchronously resettable storage for the valid bits
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

