# power_genus.tcl

#-----------------------------------------------------------------------------
# Fetch Dynamic Environment Variables
#-----------------------------------------------------------------------------
set design      $env(DESIGNS)
set freq        $env(FREQ_MHZ)
set lib         $env(LIB_TYPE)
set runtime     $env(RUNTIME)
set PROJECT_DIR $env(PROJECT_DIR)
set BACKEND_DIR $env(BACKEND_DIR)
set SYNTH_DIR   "${BACKEND_DIR}/synthesis"

# Define dynamic input/output paths based on the base configuration (RUNTIME=0)
set BASE_DELIV  "${SYNTH_DIR}/deliverables/${design}_${lib}_${freq}_0"
set RUN_RPT_DIR "${SYNTH_DIR}/reports/${design}_${lib}_${freq}_${runtime}"

#-----------------------------------------------------------------------------
# Load Existing Synthesis Database
#-----------------------------------------------------------------------------
set db_path "${BASE_DELIV}/${design}_mapped.db"

if { [file exists $db_path] } {
    puts "==============================================================="
    puts "Loading existing synthesis database from $db_path"
    puts "==============================================================="
    read_db $db_path
} else {
    puts "ERROR: Synthesis database not found at $db_path. Run base synthesis first."
    exit
}

#-----------------------------------------------------------------------------
# Post-Synthesis Power Analysis
#-----------------------------------------------------------------------------
set vcd_path "${PROJECT_DIR}/frontend/VCDs/${design}_${lib}_${freq}_${runtime}.vcd"

if { [file exists $vcd_path] } {
    puts "==============================================================="
    puts "VCD found! Running post-synthesis power analysis..."
    puts "==============================================================="
    
    read_stimulus -allow_n_nets -format vcd -file $vcd_path
    
    set_db power_engine joules
    report_sdb_annotation > ${RUN_RPT_DIR}/${design}_sdb_annotation.rpt
    report_power -unit uW > ${RUN_RPT_DIR}/${design}_power.rpt

    # Extracting Specific Signal Probabilities
    #set prob_sum [get_db hnet:sum_o[7] .lp_computed_probability]
    #set tr_sum   [get_db hnet:sum_o[7] .lp_computed_toggle_rate]
    #set prob_a   [get_db hnet:a_i[1] .lp_computed_probability]
    #set tr_a     [get_db hnet:a_i[1] .lp_computed_toggle_rate]

    #set prob_file [open "${RUN_RPT_DIR}/${design}_probabilities.rpt" w]
    #puts $prob_file "sum_o[7]_prob : $prob_sum"
    #puts $prob_file "sum_o[7]_tr : $tr_sum"
    #puts $prob_file "a_i[1]_prob : $prob_a"
    #puts $prob_file "a_i[1]_tr : $tr_a"
    #close $prob_file

} else {
    puts "==================================================================="
    puts "WARNING: VCD not found at $vcd_path. Doing default power analysis."
    puts "==================================================================="

    set_db power_engine joules
    report_sdb_annotation > ${RUN_RPT_DIR}/${design}_sdb_annotation.rpt
    report_power -unit uW > ${RUN_RPT_DIR}/${design}_power.rpt
}

quit