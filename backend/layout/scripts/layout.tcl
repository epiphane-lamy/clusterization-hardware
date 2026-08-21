
#----------------------------------------------------------------------------- 
# Fetch Dynamic Environment Variables from Makefile
#----------------------------------------------------------------------------- 
set design      $env(DESIGNS)
set freq        $env(FREQ_MHZ)
set lib         $env(LIB_TYPE)
set runtime     $env(RUNTIME)
set PROJECT_DIR $env(PROJECT_DIR)
set BACKEND_DIR $env(BACKEND_DIR)
set LAYOUT_DIR  $env(LAYOUT_DIR)

# Define dynamic output paths
set OUT_DELIV   "${LAYOUT_DIR}/deliverables/${design}_${lib}_${freq}_${runtime}"
set OUT_RPT     "${LAYOUT_DIR}/reports/${design}_${lib}_${freq}_${runtime}"

#----------------------------------------------------------------------------- 
# Load Path, Variables, and Tech files
#----------------------------------------------------------------------------- 
source ${PROJECT_DIR}/backend/synthesis/scripts/common/path.tcl 
source ${PROJECT_DIR}/backend/synthesis/scripts/common/variables.tcl

#----------------------------------------------------------------------------- 
# Suppressing messages (use with caution) 
#----------------------------------------------------------------------------- 
set_message -id TECHLIB-302 -suppress 
set_message -id IMPDB-6501 -suppress  
set_message -id IMPFP-3961 -suppress  
set_message -id IMPOPT-3195 -suppress 
set_message -id IMPSP-9025 -suppress  
set_message -id IMPLF-200 -suppress  
set_message -id IMPEXT-3493 -suppress  
set_message -id IMPEXT-6166 -suppress  
set_message -id IMPSP-5217 -suppress  


set_multi_cpu_usage -local_cpu 8

#----------------------------------------------------------------------------- 
# Initiates the design files (netlist, LEFs, timing libraries) 
#----------------------------------------------------------------------------- 
set_db init_power_nets $NET_ONE 
set_db init_ground_nets $NET_ZERO 
read_mmmc ${LAYOUT_DIR}/scripts/${design}.view 
read_physical -lef $LEF_LIST 

# Read from the dynamic Synthesis output directory
read_netlist ../../synthesis/deliverables/${design}_${lib}_${freq}_0/${design}.v 
init_design 
check_design -type netlist
check_design -type netlist -format detail
#----------------------------------------------------------------------------- 
# General settings 
#----------------------------------------------------------------------------- 
set_db design_top_routing_layer 11 
set_db design_process_node 45 

#----------------------------------------------------------------------------- 
# Net connections 
#----------------------------------------------------------------------------- 
delete_global_net_connections
connect_global_net $NET_ONE -type pg_pin -pin_base_name $NET_ONE -inst_base_name *
connect_global_net $NET_ZERO -type pg_pin -pin_base_name $NET_ZERO -inst_base_name *
connect_global_net $NET_ONE -type tie_hi
connect_global_net $NET_ZERO -type tie_lo
connect_global_net $NET_ONE -type tie_hi -pin $NET_ONE -inst *
connect_global_net $NET_ZERO -type tie_lo  -pin $NET_ZERO -inst *
#----------------------------------------------------------------------------- 
# Specify floorplan and pins
#----------------------------------------------------------------------------- 
create_floorplan -core_margins_by die -core_density_size 1 0.7 2.5 2.5 2.5 2.5
gui_show
suspend
check_floorplan

edit_pin -fixed_pin 1 -unit micron -spread_direction clockwise -side Left -layer 1 -spread_type center -spacing 1.0 -pin $LEFT_CORE_PINS 
edit_pin -fixed_pin 1 -unit micron -spread_direction clockwise -edge 1 -layer 1 -spread_type center -spacing 1.0 -pin $TOP_CORE_PINS 
edit_pin -fixed_pin 1 -unit micron -spread_direction clockwise -edge 2 -layer 1 -spread_type center -spacing 1.0 -pin $RIGHT_CORE_PINS 
edit_pin -fixed_pin 1 -unit micron -spread_direction clockwise -edge 3 -layer 1 -spread_type center -spacing 1.0 -pin $BOTTOM_CORE_PINS 

#----------------------------------------------------------------------------- 
# Power planning (Rings & Stripes)
#----------------------------------------------------------------------------- 
set_db add_rings_skip_shared_inner_ring none 
set_db add_rings_avoid_short 1 
set_db add_rings_ignore_rows 0 
set_db add_rings_extend_over_row 0 
add_rings -type core_rings -jog_distance 0.6 -threshold 0.6 -nets "$NET_ONE $NET_ZERO" -follow core -layer {bottom Metal11 top Metal11 right Metal10 left Metal10} -width 0.7 -spacing 0.4 -offset 0.6 

add_stripes -nets "$NET_ONE $NET_ZERO" -layer Metal6 -direction vertical -width 0.28 -spacing 0.8 -set_to_set_distance 6 -start_from left -switch_layer_over_obs false -max_same_layer_jog_length 2 -pad_core_ring_top_layer_limit Metal11 -pad_core_ring_bottom_layer_limit Metal1 -block_ring_top_layer_limit Metal11 -block_ring_bottom_layer_limit Metal1 -use_wire_group 0 -snap_wire_center_to_grid none -start_offset 1

route_special -connect core_pin -layer_change_range { Metal1(1) Metal11(11) } -block_pin_target nearest_target -core_pin_target first_after_row_end -allow_jogging 1 -crossover_via_layer_range { Metal1(1) Metal11(11) } -nets "$NET_ONE $NET_ZERO" -allow_layer_change 1 -target_via_layer_range { Metal1(1) Metal11(11) } -stripe_layer_range {1 11} 

#----------------------------------------------------------------------------- 
# Placement, CTS, and Routing
#----------------------------------------------------------------------------- 
# 1. Automatic placement of macros (RAMs)
#plan_design

# 2. Re-alignment to the manufacturing grid
#snap_object -grid manufacturing [get_cells -filter "is_macro==true"]

# 3. Lock RAM positions before global placement
#set_db [get_db insts -if {.is_macro == true}] .status fixed

place_opt_design 
set_db extract_rc_engine pre_route
extract_rc 

set_db opt_drv_fix_max_cap true ; set_db opt_drv_fix_max_tran true ; set_db opt_fix_fanout_load false 
opt_design -pre_cts 

set_db timing_analysis_type best_case_worst_case
time_design -pre_cts 

set_interactive_constraint_modes {normal_genus_slow_max} 
reset_ideal_network $MAIN_CLOCK_NAME 
set_db cts_buffer_cells $BUFFERS_CTS
set_db cts_inverter_cells $INVERTERS_CTS
create_clock_tree_spec 
clock_opt_design 

set_db extract_rc_engine pre_route
extract_rc 
time_design -post_cts 
time_design -post_cts -hold 
opt_design -post_cts
opt_design -post_cts -hold

route_design 


#----------------------------------------------------------------------------- 
# Post-route optimization
#----------------------------------------------------------------------------- 
set_db timing_analysis_type ocv

time_design -post_route
time_design -post_route -hold

opt_design -post_route
opt_design -post_route -hold

route_design

#----------------------------------------------------------------------------- 
# Post-route timing verification and output writing
#----------------------------------------------------------------------------- 
time_design -post_route 
time_design -post_route -hold

set_db timing_analysis_type ocv
time_design -post_route 

set_interactive_constraint_modes {normal_genus_slow_max}
set_propagated_clock [all_clocks] 

# Write Timing Reports to OUT_RPT for Makefile grep parsing
set_db timing_analysis_check_type setup 
report_timing > ${OUT_RPT}/setup_timing.rpt 

set_db timing_analysis_check_type hold 
report_timing > ${OUT_RPT}/hold_timing.rpt 

# Fillers & Metal Fill
add_fillers -base_cells {FILL8 FILL64 FILL4 FILL32 FILL2 FILL16 FILL1} 
add_metal_fill -layers {Metal1 Metal2 Metal3 Metal4 Metal5 Metal6 Metal7 Metal8 Metal9 Metal10 Metal11} 

# Save Database, Netlist, SDF, and Gates
write_db ${OUT_DELIV}/final.enc 
write_netlist ${OUT_DELIV}/${design}.v 
write_sdf -edge check_edge -map_setuphold merge_always -map_recrem split -map_removal -version 3.0 ${OUT_DELIV}/${design}.sdf 
report_gates -out_file ${OUT_RPT}/${design}_gates_layout.rpt 

exit
exit