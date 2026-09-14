

module NB_POINTS_LOADER (
        input  logic        rst_n,
        input  logic        clk,
        
        input  logic        valid_load,
        input  logic [2:0]  load,
        output logic [11:0] nb_points
    );

    logic [1:0] cnt_load;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_load <= 0;
        end else begin
            if (valid_load && (cnt_load == 0)) begin
                nb_points[2:0] <= load;
                cnt_load <= cnt_load + 1'b1;
            end
            if (valid_load && (cnt_load == 1)) begin
                nb_points[5:3] <= load;
                cnt_load <= cnt_load + 1'b1;
            end
            if (valid_load && (cnt_load == 2)) begin
                nb_points[8:6] <= load;
                cnt_load <= cnt_load + 1'b1;
            end
            if (valid_load && (cnt_load == 3)) begin
                nb_points[11:9] <= load;
                cnt_load <= 0;
            end
        end
    end

endmodule