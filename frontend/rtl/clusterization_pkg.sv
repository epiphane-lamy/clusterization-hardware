// Package clusterization

package clusterization_pkg;

    parameter int NB_POINTS = 1250;
    parameter int COORD_W   = 16;
    parameter int ADDR_W    = $clog2(NB_POINTS);

    typedef struct packed {
        logic                  we;
        logic [ADDR_W-1:0]     addr;
        logic [COORD_W-1:0]    data_in1;
        logic [COORD_W-1:0]    data_in2;
    } coord_mem_port_t;

endpackage