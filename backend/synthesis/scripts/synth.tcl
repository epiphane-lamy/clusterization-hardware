

# Last update: 2026/02/26

#-----------------------------------------------------------------------------
# General Comments
#-----------------------------------------------------------------------------
puts "  "
puts "  "
puts "  "
puts "  "

#-----------------------------------------------------------------------------
# Main Custom Variables Design Dependent (set local)
#-----------------------------------------------------------------------------
set PROJECT_DIR $env(PROJECT_DIR)
set TECH_DIR $env(TECH_DIR)
set DESIGNS $env(DESIGNS)
set HDL_NAME $env(HDL_NAME)
set INTERCONNECT_MODE ple


#-----------------------------------------------------------------------------
# MAIN Custom Variables to be used in SDC (constraints file)
#-----------------------------------------------------------------------------
set MAIN_CLOCK_NAME clk
set MAIN_RST_NAME rst_n
set BEST_LIB_OPERATING_CONDITION PVT_1P32V_0C
set WORST_LIB_OPERATING_CONDITION PVT_0P9V_125C

# Read from Makefile environment and calculate period (1000 / MHz = ns)
set freq_mhz $env(FREQ_MHZ)
set period_clk [expr {1000.0 / $freq_mhz}]; # (100 ns = 10 MHz) (10 ns = 100 MHz) (2 ns = 500 MHz) (1 ns = 1 GHz)
set clk_uncertainty 0.05 ;# ns (“a guess”)
set clk_latency 0.10 ;# ns (“a guess”)
set in_delay 0.30 ;# ns
set out_delay 0.30;#ns 
set out_load 0.045 ;#pF 
set slew "146 164 264 252" ;#minimum rise, minimum fall, maximum rise and maximum fall 
set slew_min_rise 0.146 ;# ns
set slew_min_fall 0.164 ;# ns
set slew_max_rise 0.264 ;# ns
set slew_max_fall 0.252 ;# ns
#
set WORST_LIST {slow_vdd1v0_basicCells.lib} 
set BEST_LIST {fast_vdd1v2_basicCells.lib} 
set LEF_LIST {gsclib045_tech.lef gsclib045_macro.lef}
set WORST_CAP_LIST ${TECH_DIR}/gpdk045_v_6_0/soce/gpdk045.basic.CapTbl
set QRC_LIST ${TECH_DIR}/gpdk045_v_6_0/qrc/rcworst/qrcTechFile



#-----------------------------------------------------------------------------
# Load Path File
#-----------------------------------------------------------------------------
source ${PROJECT_DIR}/backend/synthesis/scripts/common/path.tcl

#-----------------------------------------------------------------------------
# Load Tech File
#-----------------------------------------------------------------------------
source ${SCRIPT_DIR}/common/tech.tcl

# Set the active library dynamically based on the Makefile parameter
set lib_type $env(LIB_TYPE)
set_db [get_db library_domain *$lib_type] .default true
#set_db [get_db library_domain *best] .default true
#set_db [get_db library_domain *worst] .default true

#-----------------------------------------------------------------------------
# Analyze RTL source (manually set; file_list.tcl is not covered in ELC1054)
#-----------------------------------------------------------------------------

#set_db init_hdl_search_path "${DEV_DIR} ${FRONTEND_DIR}"
#set rtl_files ${DESIGNS}.vhd
#read_hdl -language vhdl $rtl_files

set_db init_hdl_search_path "${DEV_DIR} ${FRONTEND_DIR}"
#set rtl_files "Util_package.vhd ${DESIGNS}.vhd"
#read_hdl -language vhdl $rtl_files 
#Da pra fazer um -f filelist
# Read VHDL files
#read_hdl -vhdl {fpupack.vhd serial_mul.vhd pre_norm_mul.vhd post_norm_mul.vhd mul_24.vhd}

# Read SystemVerilog files
read_hdl -sv {
    clusterization_pkg.sv
    clusterization.sv
    memory_single_port.sv
    memory_cluster.sv
    cluster_assign.sv
    act_coord.sv
    ping_pong_arbiter.sv
    norm_entropy_grad.sv
    inv_LUT_synth.sv
    dist_mat_arg_exp_synth.sv
    memory_dual_port.sv
    exp_LUT_synth.sv
}





#-----------------------------------------------------------------------------
# Elaborate Design
#-----------------------------------------------------------------------------
#elaborate ${HDL_NAME}
#set_top_module ${HDL_NAME}
#check_design -unresolved ${HDL_NAME}
#get_db current_design
#check_library


#-----------------------------------------------------------------------------
# Elaborate Design
#-----------------------------------------------------------------------------
elaborate ${HDL_NAME}
set_top_module ${HDL_NAME}
check_design -unresolved ${HDL_NAME}
get_db current_design
check_library

# --- AJOUT ICI : Exclure les cellules CoreSiteDouble ---
puts "FORCAGE : Exclusion des cellules multi-hauteurs (CoreSiteDouble)"
set_db [get_db lib_cells * -if {.site.name == "CoreSiteDouble"}] .avoid true
# -------------------------------------------------------


#-----------------------------------------------------------------------------
# Constraints
#-----------------------------------------------------------------------------
read_sdc ${BACKEND_DIR}/synthesis/constraints/${HDL_NAME}.sdc
#report timing -from a_i[0] -to sum_temp_reg[7]/D
#gui_show

#-----------------------------------------------------------------------------
# Pos "Elaborate" Attributes (manually set)
#-----------------------------------------------------------------------------
set_db auto_ungroup none ;# (none|both) ungrouping will not be performed

#-----------------------------------------------------------------------------
# Generic optimization (technology independent)
#-----------------------------------------------------------------------------
syn_generic ${HDL_NAME} 

#-----------------------------------------------------------------------------
# Agressively optimization (area, timing, power) and mapping
#-----------------------------------------------------------------------------
syn_map ${HDL_NAME} 
get_db insts .base_cell.name -u ;# List all cell names used in the current design.
syn_opt ${HDL_NAME}

#-----------------------------------------------------------------------------
# Preparing and generating output data (reports, verilog netlist)
#-----------------------------------------------------------------------------
# Fetch runtime from environment early
set runtime $env(RUNTIME)

# Folders names (Ta no makefile)
set RUN_DIR "${HDL_NAME}_${lib_type}_${freq_mhz}_${runtime}"
set RUN_RPT_DIR "${RPT_DIR}/${RUN_DIR}"
set RUN_DEV_DIR "${DEV_DIR}/${RUN_DIR}"

report_design_rules > ${RUN_RPT_DIR}/${HDL_NAME}_drc.rpt
report_area > ${RUN_RPT_DIR}/${HDL_NAME}_area.rpt
report_area -normalize_with_gate NAND2X1 > ${RUN_RPT_DIR}/${HDL_NAME}_normalized_area.rpt
report_timing > ${RUN_RPT_DIR}/${HDL_NAME}_timing.rpt
report_gates > ${RUN_RPT_DIR}/${HDL_NAME}_gates.rpt
report_qor > ${RUN_RPT_DIR}/${HDL_NAME}_qor.rpt

#source ../scripts/common/sdf_width_wa.etf

# Output SDF and HDL directly to the dynamic RUN_DEV_DIR
write_sdf -edge check_edge -setuphold split -recrem split -version 3.0 -design ${HDL_NAME} > ${RUN_DEV_DIR}/${HDL_NAME}.sdf
write_hdl ${HDL_NAME} > ${RUN_DEV_DIR}/${HDL_NAME}.v

#-----------------------------------------------------------------------------
# Lab 6: Power Analysis
#-----------------------------------------------------------------------------
# Point to the dynamically generated VCD file from the Xcelium simulation
#-----------------------------------------------------------------------------
# Lab 6: Power Analysis (Conditional Execution)
#-----------------------------------------------------------------------------
set vcd_path "${PROJECT_DIR}/frontend/VCDs/${HDL_NAME}_${lib_type}_${freq_mhz}_${runtime}.vcd"

if { [file exists $vcd_path] } {
    puts "==============================================================="
    puts "INFO: VCD file found. Executing Power Analysis."
    puts "==============================================================="
    
    # Point to the dynamically generated VCD file from the Xcelium simulation
    read_stimulus -allow_n_nets -format vcd -file $vcd_path

    # Set the power engine and generate reports into the dynamic run directory
    set_db power_engine joules
    report_sdb_annotation > ${RUN_RPT_DIR}/${HDL_NAME}_sdb_annotation.rpt
    report_power -unit uW > ${RUN_RPT_DIR}/${HDL_NAME}_power.rpt

    #-----------------------------------------------------------------------------
    # Extracting Specific Signal Probabilities and Toggle Rates
    #-----------------------------------------------------------------------------
    # Fetch sum_o[7]
    #set prob_sum [get_db hnet:sum_o[7] .lp_computed_probability]
    #set tr_sum   [get_db hnet:sum_o[7] .lp_computed_toggle_rate]

    # Fetch a_i[1]
    #set prob_a   [get_db hnet:a_i[1] .lp_computed_probability]
    #set tr_a     [get_db hnet:a_i[1] .lp_computed_toggle_rate]

    # Write out using unique keys matching the Python regex
    #set prob_file [open "${RUN_RPT_DIR}/${HDL_NAME}_probabilities.rpt" w]
    #puts $prob_file "sum_o[7]_prob : $prob_sum"
    #puts $prob_file "sum_o[7]_tr : $tr_sum"
    #puts $prob_file "a_i[1]_prob : $prob_a"
    #puts $prob_file "a_i[1]_tr : $tr_a"
    #close $prob_file

} else {
    puts "==============================================================="
    puts "INFO: No VCD file found at $vcd_path. Skipping Power Analysis."
    puts "==============================================================="
}

#-----------------------------------------------------------------------------
# Save Database for Subsequent Power Analysis
#-----------------------------------------------------------------------------
set db_path "${RUN_DEV_DIR}/${HDL_NAME}_mapped.db"
puts "==============================================================="
puts "Saving Genus Database to: $db_path"
puts "==============================================================="
write_db -all_root $db_path

quit

quit