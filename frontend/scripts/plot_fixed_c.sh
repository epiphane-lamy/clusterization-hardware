#!/bin/bash
# Script to display the hardware clustering results obtained from the C code using the quantized fixed-point
# chain (clusters_fixed_c)

gnuplot << 'EOF'
set terminal svg size 900,900 enhanced
set output "../results_clustering/clusters_fixed_c.svg"

set object 1 rectangle from screen 0,0 to screen 1,1 behind fillcolor rgb "white" fillstyle solid noborder

unset grid
unset key

plot "../data/resultats_c.txt" using 1:2:3 with points pt 7 palette

set output
EOF

gnuplot << 'EOF'
set terminal svg size 900,900 enhanced
set output "../results_clustering/clusters_float_c.svg"

set object 1 rectangle from screen 0,0 to screen 1,1 behind fillcolor rgb "white" fillstyle solid noborder

unset grid
unset key

plot "../data/resultats_c_float.txt" using 1:2:3 with points pt 7 palette

set output
EOF