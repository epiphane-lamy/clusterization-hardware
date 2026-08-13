#!/bin/bash

gnuplot << 'EOF'
set terminal svg size 900,900 enhanced
set output "clusters_colored.svg"

set object 1 rectangle from screen 0,0 to screen 1,1 behind fillcolor rgb "white" fillstyle solid noborder

unset grid
unset key

plot "cluster.txt" using 1:2:3 with points pt 7 palette

set output
EOF


gnuplot << 'EOF'
set terminal svg size 900,900 enhanced
set output "clusters_black.svg"

set object 1 rectangle from screen 0,0 to screen 1,1 behind fillcolor rgb "white" fillstyle solid noborder

unset grid
unset key

plot "cluster.txt" using 1:2 with points pt 7 ps 1.5 lc rgb "black"

set output
EOF