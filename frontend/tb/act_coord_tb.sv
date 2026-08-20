

module act_coord_tb #(
    parameter int NB_POINTS = 100,           // nombre de points stockés en dur, prochainement chargé au début du calcul <= 2**ADDR_W
    parameter int COORD_W   = 16,           // largeur des coordonnees, fixed-point SIGNE
    parameter int ACT_W     = 32,
    parameter int ADDR_W    = 7
	);

    logic       clk;
    logic       rst_n;

    logic              start;     // lance le balayage complet d'un step

    // --- Port BRAM point (adresse incrementee chaque cycle) ---
    logic [COORD_W-1:0] coord_X;
    logic [COORD_W-1:0] coord_Y;

    logic              control_mem_coord;
    logic [ADDR_W-1:0] addr_coord;
    logic [ADDR_W-1:0] addr_coord_tb;
    logic [ADDR_W-1:0] addr_coord_compute;

	logic              we_coord;
	logic              we_coord_tb;
	logic              we_coord_compute;


    logic [COORD_W-1:0] coord_X_act;
    logic [COORD_W-1:0] coord_Y_act;
    logic [COORD_W-1:0] coord_X_act_tb;
    logic [COORD_W-1:0] coord_Y_act_tb;
    logic [COORD_W-1:0] coord_X_act_compute;
    logic [COORD_W-1:0] coord_Y_act_compute;

    // --- Port BRAM mult_act (adresse incrementee chaque cycle) ---
    logic               control_mem_act;
    logic [ADDR_W-1:0]  addr_act;
    logic [ADDR_W-1:0]  addr_act_tb;
    logic [ADDR_W-1:0]  addr_act_compute;
    logic signed [31:0] mult_act_X;
    logic signed [31:0] mult_act_Y;

    logic done;

    // DUT
    act_coord #(
        .NB_POINTS (NB_POINTS),
        .COORD_W   (COORD_W),
        .ADDR_W    (ADDR_W)
    ) dut_compute (
        .clk(clk),
        .rst_n(rst_n),

        .start(start),

        .addr_coord(addr_coord_compute),
        .we_coord(we_coord_compute),

        .coord_X(coord_X),
        .coord_Y(coord_Y),

        .coord_X_act(coord_X_act_compute),
        .coord_Y_act(coord_Y_act_compute),

        .addr_act(addr_act_compute),
        .mult_act_X(mult_act_X),
        .mult_act_Y(mult_act_Y),

        .done(done)
    );
    

    // memory coord
    memory_dual_port #(
        .ADDR_W (ADDR_W),
        .DATA_W (COORD_W)
    ) memory_coord (
        .clk(clk),
        .rst_n(rst_n),

        .we(we_coord),
        .addr(addr_coord),
        .data_in1(coord_X_act),
        .data_in2(coord_Y_act),

        .data_out1(coord_X),
        .data_out2(coord_Y)
    );


    // memory access
    logic       we_act;
    logic [31:0] mult_act_X_in1;
    logic [31:0] mult_act_Y_in2;

    // memory mult_act
    memory_dual_port #(
        .ADDR_W (ADDR_W),
        .DATA_W (ACT_W)
    ) memory_act (
        .clk(clk),
        .rst_n(rst_n),

        .we(we_act),
        .addr(addr_act),
        .data_in1(mult_act_X_in1),
        .data_in2(mult_act_Y_in2),

        .data_out1(mult_act_X),
        .data_out2(mult_act_Y)
    );


    task display_state(input string label);
    $display("[%0t] %-22s | coord_X=%08b coord_Y=%08b addr=%08b",
        $time, label, coord_X, coord_Y, addr_coord);
    endtask

    // write memory task
    task write_memory_coord(input logic [ADDR_W-1:0] addr_task, input logic [15:0] data_in1_task, input logic [15:0] data_in2_task);
        control_mem_coord    = 0;
        we_coord_tb    = 1;
        addr_coord_tb        = addr_task;
        coord_X_act_tb = data_in1_task;
        coord_Y_act_tb = data_in2_task;

        @(posedge clk);

        we_coord_tb = 0;
        control_mem_coord = 1;
    endtask
    
    task write_memory_act(input logic [ADDR_W-1:0] addr_task, input logic [31:0] data_in1_task, input logic [31:0] data_in2_task);
        control_mem_act = 0;
        we_act          = 1;
        addr_act_tb     = addr_task;
        mult_act_X_in1  = data_in1_task;
        mult_act_Y_in2  = data_in2_task;

        @(posedge clk);

        we_act          = 0;
        control_mem_act = 1;
    endtask
    task read_memory_coord(input logic [ADDR_W-1:0] addr_task);
        control_mem_coord = 0;
        addr_coord_tb = addr_task;
        @(posedge clk);
        $display("lecture mémoire addr=%08b coord_X=%08b coord_Y=%08b", addr_coord, coord_X, coord_Y);
        control_mem_coord = 1;
    endtask


    task automatic monitor_results();

        forever begin
            @(posedge clk);

            if (we_coord_compute) begin
                $display("[%0t] RESULT coord_act coord_X_act=%0d coord_Y_act=%0d",
                        $time,
                        coord_X_act,
                        coord_Y_act);
            end
            if (done) begin
                $display("[%0t] Calcul terminé", $time);
                break;
            end
        end
    endtask

    always #5 clk = ~clk;


    always_comb begin
        addr_coord  = control_mem_coord ? addr_coord_compute : addr_coord_tb;
        we_coord    = control_mem_coord ? we_coord_compute   : we_coord_tb;
        coord_X_act = control_mem_coord ? coord_X_act_compute : coord_X_act_tb;
        coord_Y_act = control_mem_coord ? coord_Y_act_compute : coord_Y_act_tb;

        addr_act    = control_mem_act   ? addr_act_compute : addr_act_tb;
        
    end

    integer fd;
    int ret;
    int xf, yf;
    int mult_act_x, mult_act_y;
    int addr_file;
    initial begin


        $display("\n=== début de la simulation ===");

        // init
        clk               = 0;
        rst_n             = 0;
        we_coord_tb       = 0;
        we_act            = 0;
        addr_coord_tb     = '0;
        control_mem_coord = 0;
        control_mem_act   = 0;
        start             = 0;

        fork
            monitor_results();
        join_none

        @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        
        // Écriture des vecteurs X_f et Y_f en mémoire (100 points)
        fd = $fopen("data/cluster_fixed.txt", "r");

        if (fd == 0) begin
            $fatal(1, "Impossible d'ouvrir cluster_fixed.txt");
        end

        addr_file = 0;

        while (addr_file < 100) begin

            ret = $fscanf(fd, "%d %d", xf, yf);

            if (ret != 2)
                break;

            write_memory_coord(addr_file[ADDR_W-1:0], xf[15:0], yf[15:0]);

            //$display("point[%0d] Xf=%0d Yf=%0d", addr_file, xf, yf);

            addr_file++;
        end

        $fclose(fd);

        $display("%0d points chargés depuis cluster_fixed.txt", addr_file);

        // Écriture des vecteurs X_f et Y_f en mémoire (100 points)
        fd = $fopen("data/mult_act_fixed.txt", "r");

        if (fd == 0) begin
            $fatal(1, "Impossible d'ouvrir mult_act_fixed.txt");
        end

        addr_file = 0;

        while (addr_file < 100) begin

            ret = $fscanf(fd, "%d %d", mult_act_x, mult_act_y);

            if (ret != 2)
                break;

            write_memory_act(addr_file[ADDR_W-1:0], mult_act_x, mult_act_y);

            //$display("point[%0d] Xf=%0d Yf=%0d", addr_file, xf, yf);

            addr_file++;
        end

        $fclose(fd);

        $display("%0d points chargés depuis mult_act_fixed.txt", addr_file);



        
        // lancement calcul
        control_mem_coord = 1;
        control_mem_act   = 1;
        start = 1;
        @(posedge clk);
        start = 0;
        // attente de fin du calcul
        wait(done);

        #10;
        $display("\n=== Fin de la simulation ===");
        $finish;
    end

endmodule

// [2045] RESULT coord_act coord_X_act=15755 coord_Y_act=9941
// [2075] RESULT coord_act coord_X_act=37622 coord_Y_act=37118
// [2105] RESULT coord_act coord_X_act=12118 coord_Y_act=22131
// [2135] RESULT coord_act coord_X_act=43265 coord_Y_act=14516
// [2165] RESULT coord_act coord_X_act=40356 coord_Y_act=8574
// [2195] RESULT coord_act coord_X_act=47652 coord_Y_act=15806
// [2225] RESULT coord_act coord_X_act=43760 coord_Y_act=22069
// [2255] RESULT coord_act coord_X_act=9162 coord_Y_act=27427
// [2285] RESULT coord_act coord_X_act=26164 coord_Y_act=34424
// [2315] RESULT coord_act coord_X_act=39364 coord_Y_act=35964
// [2345] RESULT coord_act coord_X_act=19322 coord_Y_act=42025
// [2375] RESULT coord_act coord_X_act=19913 coord_Y_act=35750
// [2405] RESULT coord_act coord_X_act=19203 coord_Y_act=29047
// [2435] RESULT coord_act coord_X_act=12175 coord_Y_act=29044
// [2465] RESULT coord_act coord_X_act=25996 coord_Y_act=22159
// [2495] RESULT coord_act coord_X_act=8340 coord_Y_act=8773
// [2525] RESULT coord_act coord_X_act=16570 coord_Y_act=42162
// [2555] RESULT coord_act coord_X_act=15520 coord_Y_act=12999
// [2585] RESULT coord_act coord_X_act=24717 coord_Y_act=13626
// [2615] RESULT coord_act coord_X_act=18806 coord_Y_act=46085
// [2645] RESULT coord_act coord_X_act=37459 coord_Y_act=53962
// [2675] RESULT coord_act coord_X_act=40019 coord_Y_act=54455
// [2705] RESULT coord_act coord_X_act=33519 coord_Y_act=40831
// [2735] RESULT coord_act coord_X_act=31033 coord_Y_act=47287
// [2765] RESULT coord_act coord_X_act=22057 coord_Y_act=50847
// [2795] RESULT coord_act coord_X_act=43557 coord_Y_act=50883
// [2825] RESULT coord_act coord_X_act=22532 coord_Y_act=15767
// [2855] RESULT coord_act coord_X_act=45057 coord_Y_act=30725
// [2885] RESULT coord_act coord_X_act=21791 coord_Y_act=45209
// [2915] RESULT coord_act coord_X_act=4436 coord_Y_act=44595
// [2945] RESULT coord_act coord_X_act=41955 coord_Y_act=48321
// [2975] RESULT coord_act coord_X_act=46877 coord_Y_act=12998
// [3005] RESULT coord_act coord_X_act=7956 coord_Y_act=30029
// [3035] RESULT coord_act coord_X_act=13890 coord_Y_act=54140
// [3065] RESULT coord_act coord_X_act=15857 coord_Y_act=43542
// [3095] RESULT coord_act coord_X_act=24547 coord_Y_act=47303
// [3125] RESULT coord_act coord_X_act=24824 coord_Y_act=45163
// [3155] RESULT coord_act coord_X_act=9746 coord_Y_act=45386
// [3185] RESULT coord_act coord_X_act=31132 coord_Y_act=32462
// [3215] RESULT coord_act coord_X_act=8523 coord_Y_act=48627
// [3245] RESULT coord_act coord_X_act=35521 coord_Y_act=32596
// [3275] RESULT coord_act coord_X_act=7321 coord_Y_act=38256
// [3305] RESULT coord_act coord_X_act=21363 coord_Y_act=42872
// [3335] RESULT coord_act coord_X_act=21818 coord_Y_act=50207
// [3365] RESULT coord_act coord_X_act=18617 coord_Y_act=31499
// [3395] RESULT coord_act coord_X_act=24849 coord_Y_act=20571
// [3425] RESULT coord_act coord_X_act=41860 coord_Y_act=18832
// [3455] RESULT coord_act coord_X_act=12995 coord_Y_act=41070
// [3485] RESULT coord_act coord_X_act=4086 coord_Y_act=9493
// [3515] RESULT coord_act coord_X_act=48343 coord_Y_act=31311
// [3545] RESULT coord_act coord_X_act=47504 coord_Y_act=6428
// [3575] RESULT coord_act coord_X_act=27664 coord_Y_act=16131
// [3605] RESULT coord_act coord_X_act=8970 coord_Y_act=9518
// [3635] RESULT coord_act coord_X_act=34483 coord_Y_act=30208
// [3665] RESULT coord_act coord_X_act=47712 coord_Y_act=59364
// [3695] RESULT coord_act coord_X_act=16670 coord_Y_act=8834
// [3725] RESULT coord_act coord_X_act=35124 coord_Y_act=3947
// [3755] RESULT coord_act coord_X_act=24898 coord_Y_act=44465
// [3785] RESULT coord_act coord_X_act=11785 coord_Y_act=30756
// [3815] RESULT coord_act coord_X_act=9029 coord_Y_act=31118
// [3845] RESULT coord_act coord_X_act=29919 coord_Y_act=57432
// [3875] RESULT coord_act coord_X_act=22325 coord_Y_act=27524
// [3905] RESULT coord_act coord_X_act=8970 coord_Y_act=48778
// [3935] RESULT coord_act coord_X_act=7780 coord_Y_act=33174
// [3965] RESULT coord_act coord_X_act=40255 coord_Y_act=51277
// [3995] RESULT coord_act coord_X_act=20574 coord_Y_act=57575
// [4025] RESULT coord_act coord_X_act=32152 coord_Y_act=42203
// [4055] RESULT coord_act coord_X_act=5949 coord_Y_act=51547
// [4085] RESULT coord_act coord_X_act=22722 coord_Y_act=43986
// [4115] RESULT coord_act coord_X_act=23863 coord_Y_act=24514
// [4145] RESULT coord_act coord_X_act=23515 coord_Y_act=13725
// [4175] RESULT coord_act coord_X_act=46086 coord_Y_act=46473
// [4205] RESULT coord_act coord_X_act=15547 coord_Y_act=57712
// [4235] RESULT coord_act coord_X_act=34831 coord_Y_act=32097
// [4265] RESULT coord_act coord_X_act=18637 coord_Y_act=14323
// [4295] RESULT coord_act coord_X_act=27763 coord_Y_act=8848
// [4325] RESULT coord_act coord_X_act=28224 coord_Y_act=19535
// [4355] RESULT coord_act coord_X_act=21982 coord_Y_act=24518
// [4385] RESULT coord_act coord_X_act=4897 coord_Y_act=30047
// [4415] RESULT coord_act coord_X_act=10838 coord_Y_act=51031
// [4445] RESULT coord_act coord_X_act=8192 coord_Y_act=14290
// [4475] RESULT coord_act coord_X_act=42711 coord_Y_act=21814
// [4505] RESULT coord_act coord_X_act=48024 coord_Y_act=42583
// [4535] RESULT coord_act coord_X_act=45968 coord_Y_act=21743
// [4565] RESULT coord_act coord_X_act=37485 coord_Y_act=33994
// [4595] RESULT coord_act coord_X_act=28557 coord_Y_act=18830
// [4625] RESULT coord_act coord_X_act=49062 coord_Y_act=20368
// [4655] RESULT coord_act coord_X_act=18948 coord_Y_act=49430
// [4685] RESULT coord_act coord_X_act=27326 coord_Y_act=58865
// [4715] RESULT coord_act coord_X_act=29156 coord_Y_act=11431
// [4745] RESULT coord_act coord_X_act=20746 coord_Y_act=32043
// [4775] RESULT coord_act coord_X_act=27348 coord_Y_act=36508
// [4805] RESULT coord_act coord_X_act=29191 coord_Y_act=56838
// [4835] RESULT coord_act coord_X_act=16621 coord_Y_act=57271
// [4865] RESULT coord_act coord_X_act=12358 coord_Y_act=27952
// [4895] RESULT coord_act coord_X_act=46835 coord_Y_act=13476
// [4925] RESULT coord_act coord_X_act=33195 coord_Y_act=33036
// [4955] RESULT coord_act coord_X_act=13603 coord_Y_act=26983
// [4985] RESULT coord_act coord_X_act=46465 coord_Y_act=25111
// [5015] RESULT coord_act coord_X_act=9694 coord_Y_act=35066
