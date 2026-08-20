#!/bin/bash

gnuplot << 'EOF'
set terminal svg size 900,900 enhanced
set output "../results_clustering/clusters_fixed.svg"

set object 1 rectangle from screen 0,0 to screen 1,1 behind fillcolor rgb "white" fillstyle solid noborder

unset grid
unset key

plot "../data/resultats.txt" using 1:2:3 with points pt 7 palette

set output
EOF
