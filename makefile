# THIS MAKEFILE WAS MADE BY: Vinícius Rocca Ferrari dos Santos Lima

# Define bash as the shell to allow module loading
SHELL := /bin/bash

# Define default synthesis parameters
export FREQ_MHZ ?= 100
export LIB_TYPE ?= worst
export RUNTIME ?= 0

# --- Translate Frequency to Clock Half-Period and Wait Time Dynamically ---
CLEAN_FREQ = $(strip $(FREQ_MHZ))

PERIOD_CLK := $(shell awk "BEGIN {printf \"%.3f\", 1000.0 / $(CLEAN_FREQ)}")
HALF_PERIOD_PS := $(shell awk "BEGIN {printf \"%d\", 1000000.0 / (2 * $(CLEAN_FREQ))}")

# Set wait times scaling with the frequency (assuming WAIT_TIME is 1/2 of Period in ns as a base, multiplied by scaling factor)
WAIT_TIME_NS := $(shell awk "BEGIN {printf \"%d\", 500000.0 / $(CLEAN_FREQ)}")

# Calculate exact runtime required for VCD generation based on frequency (1604500 base + 101ns buffer for rounding)
CALC_RUNTIME := $(shell awk "BEGIN {printf \"%d\", (1604500.0 / $(CLEAN_FREQ)) + 101}")
CALC_RUNTIME2 := $(shell awk "BEGIN {printf \"%d\", ((1604500.0 / $(CLEAN_FREQ)) + 101) * 2}")

# Export the calculated period so variables.tcl and SDC files can read it
export period_clk = $(PERIOD_CLK)

#-----------------------------------------------------------------------------
# General design dependent variables
#-----------------------------------------------------------------------------
export DESIGNS = full_step_cluster#cluster_assign#full_step#act_coord#step#dist_mat_arg_exp#norm_entropy_grad
export HDL_NAME = $(DESIGNS)
export PROJECT_DIR := $(shell pwd)
export BACKEND_DIR = $(PROJECT_DIR)/backend
export TECH_DIR = /home/tools/design_kits/cadence/GPDK045
export LIB_DIR = $(TECH_DIR)/gsclib045_svt_v4.4/gsclib045/timing
export LEF_DIR = $(TECH_DIR)/gsclib045_svt_v4.4/gsclib045/lef
export SCRIPT_DIR = $(BACKEND_DIR)/synthesis/scripts
export LAYOUT_DIR = $(BACKEND_DIR)/layout


export RTL_FILES = $(DESIGNS).vhd
export VLOG_LIST = $(BACKEND_DIR)/synthesis/deliverables/$(DESIGNS).v $(BACKEND_DIR)/synthesis/deliverables/$(DESIGNS)_io.v $(BACKEND_DIR)/synthesis/deliverables/$(DESIGNS)_chip.v

#-----------------------------------------------------------------------------
# Custom Variables to be used in SDC (constraints file)
#-----------------------------------------------------------------------------
export MAIN_CLOCK_NAME = clk
export MAIN_RST_NAME = rst_n
export BEST_LIB_OPERATING_CONDITION = PVT_1P32V_0C
export WORST_LIB_OPERATING_CONDITION = PVT_0P9V_125C
export clk_uncertainty = 0.05
export clk_latency = 0.10
export in_delay = 0.30
export out_delay = 0.30
export out_load = 0.045
export slew = 146 164 264 252
export slew_min_rise = 0.146
export slew_min_fall = 0.164
export slew_max_rise = 0.264
export slew_max_fall = 0.252

#-----------------------------------------------------------------------------
# TECH Custom Variables
#-----------------------------------------------------------------------------
export WORST_LIST = $(LIB_DIR)/slow_vdd1v0_basicCells.lib
export BEST_LIST = $(LIB_DIR)/fast_vdd1v2_basicCells.lib
export LEF_LIST = $(LEF_DIR)/gsclib045_tech.lef $(LEF_DIR)/gsclib045_macro.lef
export WORST_CAP_LIST = $(TECH_DIR)/gpdk045_v_6_0/soce/gpdk045.basic.CapTbl
export QRC_LIST = $(TECH_DIR)/gpdk045_v_6_0/qrc/rcworst/qrcTechFile
export CAP_MAX = $(WORST_CAP_LIST)
export CAP_MIN = $(WORST_CAP_LIST)

#-----------------------------------------------------------------------------
# Layout, CTS, and Floorplan Variables
#-----------------------------------------------------------------------------
export NET_ZERO = VSS
export NET_ONE = VDD

export BUFFERS_CTS = CLKBUFX20 CLKBUFX16 CLKBUFX12 CLKBUFX8 CLKBUFX6 CLKBUFX4 CLKBUFX3 CLKBUFX2
export INVERTERS_CTS = INVX20 CLKINVX20 INVX16 INVX12 INVX8 INVX6 INVX4 INVX3 INVX2 INVX1 INVXL

#export LEFT_CORE_PINS = {a_i[0]} {a_i[1]} {a_i[2]} {a_i[3]} {a_i[4]} {a_i[5]} {a_i[6]} {a_i[7]}
#export TOP_CORE_PINS = {b_i[0]} {b_i[1]} {b_i[2]} {b_i[3]} {b_i[4]} {b_i[5]} {b_i[6]} {b_i[7]}
#export RIGHT_CORE_PINS = {sum_o[0]} {sum_o[1]} {sum_o[2]} {sum_o[3]} {sum_o[4]} {sum_o[5]} {sum_o[6]} {sum_o[7]}
#export BOTTOM_CORE_PINS = carry_i carry_o clk rst_n

# Pads of chip
#export LEFT_CORE_PINS =
#export TOP_CORE_PINS =
#export RIGHT_CORE_PINS = {cnt[0]} {cnt[1]} {cnt[2]} {cnt[3]} {cnt[4]} {cnt[5]}
#export BOTTOM_CORE_PINS = clk rst_n ena


# Pads of chip
export LEFT_CORE_PINS = clk
export TOP_CORE_PINS = rst_n ena
export RIGHT_CORE_PINS = cnt[0] cnt[1] cnt[2]
export BOTTOM_CORE_PINS = cnt[3] cnt[4] cnt[5]

#-----------------------------------------------------------------------------
# Directories & Modules
#-----------------------------------------------------------------------------
FRONTEND_DIR = frontend
HDL_TEMP_DIR = $(FRONTEND_DIR)/hdl_temp
DUMP_DIR = $(FRONTEND_DIR)/simulation
BACKEND_SYNTH_DIR = backend/synthesis/work
BACKEND_LAYOUT_DIR = $(BACKEND_DIR)/layout
CSVS_DIR = CSVs
LAYOUTKRL = backend/layout/scripts/layout.tcl

XCELIUM_MOD = cdn/xcelium/xcelium2409
GENUS_MOD = cdn/genus/genus211
INNOVUS_MOD = cdn/innovus/innovus211
INNOVUS_MOD_DDI = cdn/ddi/ddi221 #ddi251 pour gmicro01
IMC_MOD = cdn/vmanager/vmanager239

#===================================================================================================
# UVM & Verification Directories - Currently not useful for the Multiplier32FP project as the files
# for it (i.e. UVM item, sequencer, driver, monitor...) aren't implemented.
VERIF_DIR = verification
VHD_PATHS = $(FRONTEND_DIR)/$(DESIGNS).vhd
UVM_FILELIST = $(VERIF_DIR)/filelist.f

# UVM specific Xcelium flags
XRUN_UVM_FLAGS = -clean -64bit -sv -v200x -v93 -uvm -sv $(VHD_PATHS) -f $(UVM_FILELIST) -top somador_top -access +rwc $(GUI_FLAG) -coverage u -covoverwrite +VETOR_PATH=$(PROJECT_DIR)/frontend/vetor.txt
#===================================================================================================

# GUI Control
GUI ?= 0
ifeq ($(GUI), 1)
	GUI_FLAG = -gui
else
	GUI_FLAG =
endif

GUI_VCD ?= 0
ifeq ($(GUI_VCD), 1)
	GUI_FLAG_VCD = -gui
else
	GUI_FLAG_VCD = -input $(PROJECT_DIR)/frontend/generate_vcd.tcl
endif

# --- Testbench Selection ---
# VECT=1 : Usa o vetor de testes.
# VECT=0 : Usa o testbench funcional
VECT ?= 0
ifeq ($(VECT), 1)
	TB_MODULE_NAME = $(DESIGNS)_vect_tb
	TB_MAIN_FILE = $(PROJECT_DIR)/$(FRONTEND_DIR)/$(TB_MODULE_NAME).sv
else
	TB_MODULE_NAME = $(DESIGNS)_tb
	TB_MAIN_FILE = $(PROJECT_DIR)/$(FRONTEND_DIR)/$(TB_MODULE_NAME).sv
endif

# Xcelium (Frontend generic RTL simulation with filelist)
RTL_FILELIST = $(PROJECT_DIR)/$(FRONTEND_DIR)/filelist.f

# Example of the corrected parameter syntax:
XRUN_FLAGS = -clean -64bit -sv -v200x -v93 -f $(RTL_FILELIST) -top $(TB_MODULE_NAME) -access +rwc ${GUI_FLAG} -defparam $(TB_MODULE_NAME).HALF_PERIOD_PS=$(HALF_PERIOD_PS) -defparam $(TB_MODULE_NAME).WAIT_TIME_NS=$(WAIT_TIME_NS)
# Genus (Synthesis flags)
SYNTH_SCRIPT = ../scripts/synth.tcl
GENUS_FLAGS = -abort_on_error -lic_startup Genus_Synthesis -lic_startup_options Genus_Physical_Opt -log genus_$(FREQ_MHZ)MHz_$(LIB_TYPE) -overwrite -f $(SYNTH_SCRIPT)

# Post-Synthesis Monitor flags
XRUN_POST_FLAGS = -timescale 1ns/10ps -mess -64bit -sv -v200x -v93 -iocondsort -access +rwc -clean -input $(PROJECT_DIR)/frontend/monitor.tcl -defparam $(TB_MODULE_NAME).HALF_PERIOD_PS=$(HALF_PERIOD_PS) -defparam $(TB_MODULE_NAME).WAIT_TIME_NS=$(WAIT_TIME_NS) -defparam $(TB_MODULE_NAME).SIM_RUNTIME=$(RUNTIME)

# Top-level and SDF configurations for parameterized gate-level simulations
TOP_MODULE	  = -top $(TB_MODULE_NAME)
SDF_CMD		 = -sdf_cmd_file $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
SDF_FILE		= $(BACKEND_DIR)/layout/deliverables/$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_0/$(DESIGNS).sdf.X
SDF_FILE_SYNTH  = $(BACKEND_DIR)/synthesis/deliverables/$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_0/$(DESIGNS).sdf

# Tech files & netlists
TECH_V_LIB	  = $(TECH_DIR)/gsclib045_all_v4.4/gsclib045/verilog/slow_vdd1v0_basicCells.v
NETLIST_FILE	= $(BACKEND_DIR)/synthesis/deliverables/$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_0/$(DESIGNS).v
TB_FILES		= $(TB_MAIN_FILE)
NETLIST_FILE_POST_LAYOUT = $(BACKEND_DIR)/synthesis/deliverables/$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_0/$(DESIGNS).v

# Post-Synthesis VCD Generation flags
XRUN_GLS_VCD_FLAGS = -timescale 1ns/10ps -mess -64bit -sv -v200x -v93 -iocondsort -access +rwc ${GUI_FLAG_VCD} -clean -defparam $(TB_MODULE_NAME).HALF_PERIOD_PS=$(HALF_PERIOD_PS) -defparam $(TB_MODULE_NAME).WAIT_TIME_NS=$(WAIT_TIME_NS) -defparam $(TB_MODULE_NAME).SIM_RUNTIME=$(RUNTIME)

# Layout and Post-Layout Simulation flags
LAYOUT_SCRIPT = ${BACKEND_LAYOUT_DIR}/scripts/layout.tcl
POWER_SCRIPT  = ${BACKEND_LAYOUT_DIR}/scripts/power.tcl
INNOVUS_FLAGS = -stylus -no_gui -init $(LAYOUT_SCRIPT) -overwrite -log innovus_$(FREQ_MHZ)MHz_$(LIB_TYPE).log
XRUN_POST_LAYOUT_FLAGS = -timescale 1ns/10ps -mess -64bit -sv -v200x -v93 -iocondsort -access +rwc -clean ${GUI_FLAG_VCD} -defparam $(TB_MODULE_NAME).HALF_PERIOD_PS=$(HALF_PERIOD_PS) -defparam $(TB_MODULE_NAME).WAIT_TIME_NS=$(WAIT_TIME_NS) -defparam $(TB_MODULE_NAME).SIM_RUNTIME=$(RUNTIME)
GENUS_LAYOUT_FLAGS = -abort_on_error -lic_startup Genus_Synthesis -lic_startup_options Genus_Physical_Opt -log genus_$(FREQ_MHZ)MHz_$(LIB_TYPE) -overwrite -f $(LAYOUT_SCRIPT)

# Default target
all: sim_rtl

# =========================================================================
# Execution Commands
# =========================================================================

sim_rtl:
	bash -l -c "module add $(XCELIUM_MOD) && cd $(FRONTEND_DIR) && xrun $(XRUN_FLAGS)"

synth:
	@MATCHING_DIR=$$(find $(BACKEND_DIR)/synthesis/reports -maxdepth 1 -type d -name "$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_$(RUNTIME)" 2>/dev/null | head -n 1); \
	if [ -n "$$MATCHING_DIR" ] && [ "$(VCD)" != "1" ]; then \
		echo "==============================================================="; \
		echo "INFO: Synthesis folder for $(FREQ_MHZ) MHz and runtime $(RUNTIME) already exists."; \
		echo "Found: $$MATCHING_DIR"; \
		echo "Skipping Genus."; \
		echo "==============================================================="; \
	else \
		mkdir -p $(BACKEND_DIR)/synthesis/reports/$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_$(RUNTIME); \
		mkdir -p $(BACKEND_DIR)/synthesis/deliverables/$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_$(RUNTIME); \
		bash -l -c "module add $(GENUS_MOD) && cd $(BACKEND_SYNTH_DIR) && genus $(GENUS_FLAGS)"; \
	fi

power_synth:
	@mkdir -p $(BACKEND_DIR)/synthesis/reports/$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_$(RUNTIME)
	@echo "==============================================================="
	@echo "Running Fast Power Analysis via Genus DB: $(FREQ_MHZ) MHz | $(RUNTIME)ns"
	@echo "==============================================================="
	bash -l -c "module add $(GENUS_MOD) && cd $(BACKEND_SYNTH_DIR) && genus -abort_on_error -lic_startup Genus_Synthesis -lic_startup_options Genus_Physical_Opt -log genus_power_$(FREQ_MHZ)MHz_$(RUNTIME) -overwrite -f ../scripts/power_genus.tcl"



layout_innovus:
	@MATCHING_DIR=$$(find $(LAYOUT_DIR)/reports -maxdepth 1 -type d -name "$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_$(RUNTIME)" 2>/dev/null | head -n 1); \
	if [ -n "$$MATCHING_DIR" ]; then \
		echo "==============================================================="; \
		echo "INFO: Layout folder for $(FREQ_MHZ) MHz and runtime $(RUNTIME) already exists."; \
		echo "Found: $$MATCHING_DIR"; \
		echo "Skipping Innovus Layout."; \
		echo "==============================================================="; \
	else \
		mkdir -p $(LAYOUT_DIR)/work; \
		mkdir -p $(LAYOUT_DIR)/reports/$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_$(RUNTIME); \
		mkdir -p $(LAYOUT_DIR)/deliverables/$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_$(RUNTIME); \
		bash -l -c "module add $(INNOVUS_MOD_DDI) && cd $(LAYOUT_DIR)/work && innovus $(INNOVUS_FLAGS)"; \
	fi
		
layout_genus:
	@mkdir -p $(BACKEND_DIR)/synthesis/reports/$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_$(RUNTIME)
	@mkdir -p $(BACKEND_DIR)/synthesis/deliverables/$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_$(RUNTIME)
	bash -l -c "module add $(INNOVUS_MOD_DDI) && cd $(BACKEND_LAYOUT_DIR) && genus $(GENUS_LAYOUT_FLAGS)"

sim_gls_monitor: sim_rtl
	@mkdir -p $(DUMP_DIR)
	@mkdir -p $(CSVS_DIR)
	@echo "Generating dynamic SDF command file..."
	@echo 'COMPILED_SDF_FILE = "$(SDF_FILE)",' > $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'SCOPE = :DUV,' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'LOG_FILE = "sdf.log",' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'MTM_CONTROL = "MAXIMUM",' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'SCALE_FACTORS = "1.0:1.0:1.0",' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'SCALE_TYPE = "FROM_MTM";' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	bash -l -c "module add $(XCELIUM_MOD) && \
			cd $(FRONTEND_DIR) && \
			xrun $(XRUN_POST_FLAGS) \
			$(TECH_V_LIB) \
			$(NETLIST_FILE) \
			$(TB_FILES) \
			$(TOP_MODULE) \
			$(SDF_CMD)"

sim_gls_vcd: sim_rtl
	@mkdir -p $(DUMP_DIR)
	@mkdir -p $(CSVS_DIR)
	@echo "Generating dynamic SDF command file..."
	@echo 'COMPILED_SDF_FILE = "$(SDF_FILE_SYNTH)",' > $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'SCOPE = :DUV,' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'LOG_FILE = "sdf.log",' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'MTM_CONTROL = "MAXIMUM",' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'SCALE_FACTORS = "1.0:1.0:1.0",' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'SCALE_TYPE = "FROM_MTM";' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	bash -l -c "module add $(XCELIUM_MOD) && \
			cd $(FRONTEND_DIR) && \
			xrun $(XRUN_GLS_VCD_FLAGS) \
			$(TECH_V_LIB) \
			$(NETLIST_FILE) \
			$(TB_FILES) \
			$(TOP_MODULE) \
			$(SDF_CMD)"
			
# Simulation for generation of the VCD after physical synthesis
sim_post_layout: sim_rtl
	@mkdir -p $(DUMP_DIR)
	@mkdir -p $(CSVS_DIR)
	@echo "Generating dynamic SDF command file..."
	@echo 'COMPILED_SDF_FILE = "$(SDF_FILE)",' > $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'SCOPE = :DUV,' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'LOG_FILE = "sdf.log",' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'MTM_CONTROL = "MAXIMUM",' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'SCALE_FACTORS = "1.0:1.0:1.0",' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	@echo 'SCALE_TYPE = "FROM_MTM";' >> $(PROJECT_DIR)/frontend/sdf_cmd_file.cmd
	bash -l -c "module add $(XCELIUM_MOD) && \
			cd $(FRONTEND_DIR) && \
			xrun $(XRUN_POST_LAYOUT_FLAGS) \
			$(TECH_V_LIB) \
			$(NETLIST_FILE_POST_LAYOUT) \
			$(TB_FILES) \
			$(TOP_MODULE) \
			$(SDF_CMD)|| true"


# =========================================================================
# Parameter Sweeps & Extractions
# =========================================================================

# Faz a síntese base e gera os VCDs e os power reports para X e 2X
vcd_synth:
	@echo "=================================================="
	@echo "1. Running base synthesis to generate netlist and SDF"
	@echo "=================================================="
	$(MAKE) synth FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=0
	@echo "=================================================="
	@echo "2. Running simulation for $(FREQ_MHZ) MHz to generate VCD"
	@echo "=================================================="
	@mkdir -p $(FRONTEND_DIR)/VCDs
	$(MAKE) sim_gls_vcd FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=$(CALC_RUNTIME) VECT=1
	@echo "=================================================="
	@echo "3. Running fast power analysis with VCD"
	@echo "=================================================="
	$(MAKE) power_synth FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=$(CALC_RUNTIME)
	@echo "=================================================="
	@echo "4. Running simulation for $(FREQ_MHZ) MHz to generate VCD with 2X Runtime"
	@echo "=================================================="
	@mkdir -p $(FRONTEND_DIR)/VCDs
	$(MAKE) sim_gls_vcd FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=$(CALC_RUNTIME2) VECT=1
	@echo "=================================================="
	@echo "5. Running fast power analysis with VCD and 2X Runtime"
	@echo "=================================================="
	$(MAKE) power_synth FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=$(CALC_RUNTIME2)

# Runs logic synthesis -> physical synthesis -> post layout simulation for VCD (X and 2X) -> generates power reports
vcd_layout:
	@echo "=================================================="
	@echo "1. Running base layout (requires base synth first)"
	@echo "=================================================="
	$(MAKE) synth FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=0
	$(MAKE) layout_innovus FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=0
	@echo "=================================================="
	@echo "2. Running Post-Layout simulation for $(FREQ_MHZ) MHz to generate VCD"
	@echo "=================================================="
	@mkdir -p $(FRONTEND_DIR)/VCDs
	$(MAKE) sim_post_layout FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=$(CALC_RUNTIME) VECT=1
	@echo "=================================================="
	@echo "3. Running Post-Layout power analysis with VCD"
	@echo "=================================================="
	$(MAKE) innovus_power FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=$(CALC_RUNTIME)
	@echo "=================================================="
	@echo "4. Running Post-Layout simulation for $(FREQ_MHZ) MHz to generate VCD with 2X Runtime"
	@echo "=================================================="
	@mkdir -p $(FRONTEND_DIR)/VCDs
	$(MAKE) sim_post_layout FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=$(CALC_RUNTIME2) VECT=1
	@echo "=================================================="
	@echo "5. Running Post-Layout power analysis with VCD and 2X Runtime"
	@echo "=================================================="
	$(MAKE) innovus_power FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=$(CALC_RUNTIME2)


sweep_synth_csv: sim_rtl
	@mkdir -p $(CSVS_DIR)
	@for freq in 10 100 500 1000; do \
		for lib in worst best; do \
			echo "=================================================="; \
			echo "Running synthesis for $$freq MHz with $$lib library"; \
			echo "=================================================="; \
			$(MAKE) synth FREQ_MHZ=$$freq LIB_TYPE=$$lib; \
		done \
	done
	@echo "=================================================="
	@echo "Extracting synthesis data to CSV..."
	@echo "=================================================="
	python3 $(SCRIPTS_DIR)/Report_extractor.py

sweep_gls_monitor:
	@mkdir -p $(CSVS_DIR)
	@for freq in 10 100 500 1000; do \
		for lib in worst best; do \
			echo "=================================================="; \
			echo "Running Post-Synth Simulation: $$freq MHz | $$lib"; \
			echo "=================================================="; \
			$(MAKE) sim_gls_monitor FREQ_MHZ=$$freq LIB_TYPE=$$lib; \
		done \
	done
	@echo "=================================================="
	@echo "Extracting stability times to CSV..."
	@echo "=================================================="
	python3 $(SCRIPTS_DIR)/stable_extractor.py

sweep_gls_vcd:
	@mkdir -p $(CSVS_DIR)
	@for freq in 100 ; do \
		for lib in worst; do \
			for runtime in 5000; do \
				echo "==============================================================="; \
				echo "Running Post-Synth Simulation: $$freq MHz | $$lib | $$runtime"; \
				echo "==============================================================="; \
				$(MAKE) sim_gls_vcd FREQ_MHZ=$$freq LIB_TYPE=$$lib RUNTIME=$$runtime; \
				$(MAKE) synth FREQ_MHZ=$$freq LIB_TYPE=$$lib RUNTIME=$$runtime; \
			done \
		done \
	done

sweep_full_power_analysis:
	@mkdir -p $(CSVS_DIR)
	@echo "========================================================="
	@echo "		  GENERATING BASE SYNTHESIS FILES				"
	@echo "========================================================="
	@for freq in 100 500 1000; do \
		for lib in worst; do \
			echo "Running base synthesis for $$freq MHz | $$lib"; \
			$(MAKE) synth FREQ_MHZ=$$freq LIB_TYPE=$$lib RUNTIME=0; \
		done \
	done
	@echo "========================================================="
	@echo "		 STARTING GATE-LEVEL VCD SWEEPS				  "
	@echo "========================================================="
	@for freq in 100 ; do \
		for lib in worst; do \
			for runtime in 0 500 1000; do \
				echo "==============================================================="; \
				echo "Running Post-Synth Simulation: $$freq MHz | $$lib | $$runtime"; \
				echo "==============================================================="; \
				$(MAKE) sim_gls_vcd FREQ_MHZ=$$freq LIB_TYPE=$$lib RUNTIME=$$runtime; \
				$(MAKE) synth FREQ_MHZ=$$freq LIB_TYPE=$$lib RUNTIME=$$runtime; \
			done \
		done \
	done
	@for freq in 500 ; do \
		for lib in worst; do \
			for runtime in 0 100 200; do \
				echo "==============================================================="; \
				echo "Running Post-Synth Simulation: $$freq MHz | $$lib | $$runtime"; \
				echo "==============================================================="; \
				$(MAKE) sim_gls_vcd FREQ_MHZ=$$freq LIB_TYPE=$$lib RUNTIME=$$runtime; \
				$(MAKE) synth FREQ_MHZ=$$freq LIB_TYPE=$$lib RUNTIME=$$runtime; \
			done \
		done \
	done
	@for freq in 1000 ; do \
		for lib in worst; do \
			for runtime in 0 50 100; do \
				echo "==============================================================="; \
				echo "Running Post-Synth Simulation: $$freq MHz | $$lib | $$runtime"; \
				echo "==============================================================="; \
				$(MAKE) sim_gls_vcd FREQ_MHZ=$$freq LIB_TYPE=$$lib RUNTIME=$$runtime; \
				$(MAKE) synth FREQ_MHZ=$$freq LIB_TYPE=$$lib RUNTIME=$$runtime; \
			done \
		done \
	done
	@echo "================================================================"
	@echo "Extracting synthesis data to CSV and writting to latex table..."
	@echo "================================================================"
	python3 $(SCRIPTS_DIR)/Report_extractor_TL.py
	python3 $(SCRIPTS_DIR)/latex_table_builder.py
		
sweep_short_power_analysis:
	@echo "========================================================="
	@echo "		 STARTING GATE-LEVEL VCD SWEEPS				  "
	@echo "========================================================="
	@for freq in 100 ; do \
		for lib in worst; do \
			for runtime in 500; do \
				echo "==============================================================="; \
				echo "Running Post-Synth Simulation: $$freq MHz | $$lib | $$runtime"; \
				echo "==============================================================="; \
				$(MAKE) sim_gls_vcd FREQ_MHZ=$$freq LIB_TYPE=$$lib RUNTIME=$$runtime; \
				$(MAKE) synth FREQ_MHZ=$$freq LIB_TYPE=$$lib RUNTIME=$$runtime; \
			done \
		done \
	done
	@for freq in 1000 ; do \
		for lib in worst; do \
			for runtime in 50; do \
				echo "==============================================================="; \
				echo "Running Post-Synth Simulation: $$freq MHz | $$lib | $$runtime"; \
				echo "==============================================================="; \
				$(MAKE) sim_gls_vcd FREQ_MHZ=$$freq LIB_TYPE=$$lib RUNTIME=$$runtime; \
				$(MAKE) synth FREQ_MHZ=$$freq LIB_TYPE=$$lib RUNTIME=$$runtime; \
			done \
		done \
	done
		
innovus_power:
	@mkdir -p $(LAYOUT_DIR)/reports/$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_$(RUNTIME)
	bash -l -c "module add $(INNOVUS_MOD_DDI) && cd $(LAYOUT_DIR)/work && innovus -stylus -no_gui -init $(POWER_SCRIPT) -overwrite -log innovus_power_$(FREQ_MHZ)MHz.log"

# --- Complete Flow Execution ---
flow_full_single_config:
	@echo "========================================================="
	@echo "       STEP 1: BASE LOGICAL SYNTHESIS (GENUS)         "
	@echo "========================================================="
	$(MAKE) synth FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=0
	@echo "========================================================="
	@echo "       STEP 2: BASE PHYSICAL SYNTHESIS (INNOVUS)      "
	@echo "========================================================="
	$(MAKE) layout_innovus FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=0
	@echo "========================================================="
	@echo "       STEP 3: POST-LAYOUT SIMULATION (XCELIUM)       "
	@echo "========================================================="
	@mkdir -p $(FRONTEND_DIR)/VCDs
	$(MAKE) sim_post_layout FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=$(RUNTIME) VECT=1
	@echo "========================================================="
	@echo "       STEP 4: POST-LAYOUT POWER ANALYSIS (INNOVUS)   "
	@echo "===========================$(MAKE) innovus_power FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=$(RUNTIME)=============================="
	$(MAKE) innovus_power FREQ_MHZ=$(FREQ_MHZ) LIB_TYPE=$(LIB_TYPE) RUNTIME=$(RUNTIME)

# =========================================================================
# Maximum Frequency Finder Sweep
# =========================================================================
export START_FREQ ?= 100
export FREQ_STEP ?= 1

find_max_freq:
	@echo "==============================================================="
	@echo "Starting frequency sweep to find maximum operational frequency."
	@echo "==============================================================="
	@freq=$(START_FREQ); \
	step=$(FREQ_STEP); \
	while true; do \
		echo "Testing FREQ_MHZ=$$freq MHz..."; \
		$(MAKE) synth FREQ_MHZ=$$freq; \
		rpt_file="$(BACKEND_DIR)/synthesis/reports/$(DESIGNS)_$(LIB_TYPE)_$${freq}_$(RUNTIME)/$(DESIGNS)_timing.rpt"; \
		if [ ! -f "$$rpt_file" ]; then \
			echo "Error: Timing report not found ($$rpt_file). Did synthesis fail?"; \
			break; \
		fi; \
		slack=$$(grep -i -E "^\s*Slack:=" "$$rpt_file" | head -n 1 | awk -F'[:=]+' '{print $$2}' | tr -d '[:space:]'); \
		if [ -z "$$slack" ]; then \
			echo "Error: Could not extract slack from report."; \
			break; \
		fi; \
		echo "Result: $$freq MHz -> Slack: $$slack ps"; \
		if echo "$$slack" | awk '{if ($$1 <= -50) exit 0; else exit 1}'; then \
			echo "==============================================================="; \
			echo "Negative slack reached at $$freq MHz."; \
			prev_freq=$$((freq - step)); \
			echo "Max positive slack frequency is approximately $$prev_freq MHz."; \
			echo "==============================================================="; \
			break; \
		fi; \
		freq=$$((freq + step)); \
	done

# Variables
# =========================================================================
# Layout Maximum Frequency Finder Sweep
# =========================================================================
export START_FREQ_LAYOUT ?= 372
export FREQ_STEP_LAYOUT ?= 1

find_max_freq_layout:
	@echo "==============================================================="
	@echo "Starting layout frequency reverse-sweep."
	@echo "==============================================================="
	@freq=$(START_FREQ_LAYOUT); \
	step=$(FREQ_STEP_LAYOUT); \
	while true; do \
		if [ $$freq -le 0 ]; then \
			echo "Reached 0 MHz. Failing out."; \
			break; \
		fi; \
		echo "Testing FREQ_MHZ=$$freq MHz..."; \
		$(MAKE) synth FREQ_MHZ=$$freq RUNTIME=0; \
		$(MAKE) layout_innovus FREQ_MHZ=$$freq RUNTIME=0; \
		setup_rpt="$(BACKEND_DIR)/layout/reports/$(DESIGNS)_$(LIB_TYPE)_$${freq}_0/setup_timing.rpt"; \
		hold_rpt="$(BACKEND_DIR)/layout/reports/$(DESIGNS)_$(LIB_TYPE)_$${freq}_0/hold_timing.rpt"; \
		if [ ! -f "$$setup_rpt" ] || [ ! -f "$$hold_rpt" ]; then \
			echo "Error: Layout timing reports not found. Did Innovus fail?"; \
			break; \
		fi; \
		setup_slack=$$(grep -i -E "^\s*Slack\s*[:=]+" "$$setup_rpt" | head -n 1 | awk -F'[:=]+' '{print $$2}' | tr -d '[:space:]psns'); \
		hold_slack=$$(grep -i -E "^\s*Slack\s*[:=]+" "$$hold_rpt" | head -n 1 | awk -F'[:=]+' '{print $$2}' | tr -d '[:space:]psns'); \
		echo "Result: $$freq MHz -> Setup Slack: $$setup_slack | Hold Slack: $$hold_slack"; \
		if echo "$$setup_slack" | grep -q "^-" || echo "$$hold_slack" | grep -q "^-"; then \
			echo "Negative slack found. Lowering frequency..."; \
			freq=$$((freq - step)); \
		else \
			echo "==============================================================="; \
			echo "Max operational layout frequency found: $$freq MHz."; \
			echo "==============================================================="; \
			break; \
		fi; \
	done


# =========================================================================
# Utilities & Visualizers
# =========================================================================


latex:
	@echo "================================================================"
	@echo "Extracting synthesis data to CSV and writting to latex table..."
	@echo "================================================================"
	python3 $(SCRIPTS_DIR)/Report_extractor_TL.py
	python3 $(SCRIPTS_DIR)/latex_table_builder.py
		
genus_gui:
	@echo "==============================================================="
	@echo "Launching Genus Schematic Viewer: $(FREQ_MHZ) MHz | $(LIB_TYPE)"
	@echo "==============================================================="
	bash -l -c "module add $(GENUS_MOD) && cd $(BACKEND_SYNTH_DIR) && genus -gui -f ../scripts/view_design.tcl"

innovus_gui:
	@echo "==============================================================="
	@echo "Launching Innovus for: $(FREQ_MHZ) MHz | $(LIB_TYPE) library"
	@echo "Netlist path: ../deliverables/$(DESIGNS)_$(LIB_TYPE)_$(FREQ_MHZ)_0/$(DESIGNS).v"
	@echo "==============================================================="
	bash -l -c "module add $(INNOVUS_MOD) && cd $(BACKEND_SYNTH_DIR) && innovus"
		
cross_sta:
	@echo "==============================================================="
	@echo "Running Static Timing Analysis"
	@echo "Netlist: $(SYNTH_FREQ) MHz  |  Testing at: $(TEST_FREQ) MHz"
	@echo "==============================================================="
	bash -l -c "module add $(GENUS_MOD) && \
		export SYNTH_FREQ=$(SYNTH_FREQ) && \
		export TEST_FREQ=$(TEST_FREQ) && \
		cd $(BACKEND_SYNTH_DIR) && \
		genus -abort_on_error -log genus_cross_sta -overwrite -f ../scripts/cross_timing.tcl"
		
uvm_sim:
	@echo "=================================================="
	@echo "Running UVM Mixed-Language Simulation..."
	@echo "=================================================="
	bash -l -c "module add $(INNOVUS_MOD_DDI) && xrun $(XRUN_UVM_FLAGS)"
		
cov_gui:
	@echo "=================================================="
	@echo "Launching Cadence IMC Coverage Viewer..."
	@echo "=================================================="
	bash -l -c "module add $(IMC_MOD) && module add $(XCELIUM_MOD) && imc -load cov_work/scope/test"

clean:
	@echo "=================================================="
	@echo "Cleaning temporary logs, simulation data, and history..."
	@echo "=================================================="
	rm -rf $(FRONTEND_DIR)/xcelium.d $(FRONTEND_DIR)/xrun.history $(FRONTEND_DIR)/xrun.log*
	rm -rf $(FRONTEND_DIR)/work $(FRONTEND_DIR)/sdf.log $(FRONTEND_DIR)/vcd_sim.log $(FRONTEND_DIR)/*.sdf.X
	rm -rf $(BACKEND_SYNTH_DIR)/genus* $(BACKEND_SYNTH_DIR)/fv $(BACKEND_SYNTH_DIR)/rc*
	rm -rf $(BACKEND_LAYOUT_DIR)/innovus* $(BACKEND_LAYOUT_DIR)/*.log* $(BACKEND_LAYOUT_DIR)/*.cmd*
	rm -rf $(BACKEND_LAYOUT_DIR)/work $(FRONTEND_DIR)/VCDs
	@echo "=================================================="
	@echo "INFO: Run 'make clean_all' to permanently delete all VCDs, .db files, and reports."
	@echo "=================================================="

clean_all: clean
	@echo "=================================================="
	@echo "Deep cleaning: Removing all VCDs, Reports, CSVs, and Deliverables..."
	@echo "=================================================="
	rm -rf $(FRONTEND_DIR)/VCDs
	rm -rf $(CSVS_DIR)
	rm -rf $(BACKEND_DIR)/synthesis/reports/*
	rm -rf $(BACKEND_DIR)/synthesis/deliverables/*
	rm -rf $(BACKEND_DIR)/layout/reports/*
	rm -rf $(BACKEND_DIR)/layout/deliverables/*
	@echo "Project reset complete."

# =========================================================================
# Help Menu
# =========================================================================

help:
	@echo "========================================================================================="
	@echo "                             MAKEFILE COMMAND REFERENCE                             "
	@echo "========================================================================================="
	@echo "Usage: make <target> [VARIABLE=value]"
	@echo "Example: make vcd_layout FREQ_MHZ=372 LIB_TYPE=worst"
	@echo ""
	@echo "Key Variables (can be overridden from command line):"
	@echo "  FREQ_MHZ          : Target frequency in MHz (Default: 100)."
	@echo "  LIB_TYPE          : Library operating condition (Default: worst). Options: worst, best."
	@echo "  RUNTIME           : Simulation runtime in ns (Default: dynamically calculated or 0)."
	@echo "  VECT              : Set to 1 to use the vector-based testbench (Default: 0)."
	@echo "  GUI               : Set to 1 to open Xcelium GUI for RTL sim (Default: 0)."
	@echo "  GUI_VCD           : Set to 1 to open Xcelium GUI for GLS/VCD sim (Default: 0)."
	@echo "  START_FREQ        : Starting frequency (MHz) for logical find_max_freq (Default: 100)."
	@echo "  FREQ_STEP         : Step size (MHz) for logical find_max_freq (Default: 1)."
	@echo "  START_FREQ_LAYOUT : Starting frequency (MHz) for physical find_max_freq_layout (Default: 372)."
	@echo "  FREQ_STEP_LAYOUT  : Step size (MHz) for physical find_max_freq_layout (Default: 1)."
	@echo ""
	@echo "Core Execution Targets:"
	@echo "  flow_full_single_config : Execute complete flow (synth -> layout -> sim -> power)."
	@echo "  sim_rtl                 : Run standard frontend RTL simulation in Xcelium."
	@echo "  synth                   : Run logic synthesis using Genus (generates .db for power analysis)."
	@echo "  power_synth             : Run fast power analysis using a saved Genus .db and VCD file."
	@echo "  vcd_synth               : Run base synth, VCD generation (X and 2X), and logical power analysis."
	@echo "  layout_innovus          : Run physical design layout using Innovus."
	@echo "  layout_genus            : Run layout scripts via Genus."
	@echo "  innovus_power           : Run post-layout power analysis using Innovus and VCD."
	@echo "  vcd_layout              : Run base layout, VCD generation (X and 2X), and physical power analysis."
	@echo "" 
	@echo "Gate-Level Simulation (GLS) Targets:"
	@echo "  sim_gls_monitor         : Post-synthesis simulation using a monitor script."
	@echo "  sim_gls_vcd             : Post-synthesis simulation with VCD generation."
	@echo "  sim_post_layout         : Post-layout simulation using Innovus SDF."
	@echo ""
	@echo "Parameter Sweeps & Batch Analysis:"
	@echo "  find_max_freq           : Sweep frequencies upward to find max logical synthesis freq."
	@echo "  find_max_freq_layout    : Sweep frequencies downward to find max physical layout freq."
	@echo "  sweep_synth_csv         : Sweep synthesis across frequencies/libs and extract to CSV."
	@echo "  sweep_gls_monitor       : Sweep post-synth monitor simulations across frequencies."
	@echo "  sweep_gls_vcd           : Sweep post-synth VCD simulations for specific runtimes."
	@echo "  sweep_full_power        : Full multi-frequency base generation and analysis sweep."
	@echo "  sweep_short_power       : Short gate-level VCD sweep for specific runtimes."
	@echo ""
	@echo "Utilities & Visualizers:"
	@echo "  setup_dirs              : Initialize the project directory tree."
	@echo "  genus_gui               : Open the Genus Schematic Viewer for the current parameters."
	@echo "  innovus_gui             : Open the Innovus GUI with the generated netlist."
	@echo "  cross_sta               : Run Static Timing Analysis (requires SYNTH_FREQ & TEST_FREQ)."
	@echo "  uvm_sim                 : Run UVM mixed-language simulation."
	@echo "  cov_gui                 : Open Cadence IMC Coverage Viewer."
	@echo "  latex                   : Extract synthesis data and build a LaTeX table."
	@echo "  clean                   : Remove simulator logs, history, and workspace temp files."
	@echo "  clean_all               : Deep clean. Removes ALL deliverables, reports, .db files, and VCDs."
	@echo "========================================================================================="
	@echo "Example: make vcd_layout FREQ_MHZ=372 LIB_TYPE=worst"
	@echo "========================================================================================="

# =========================================================================
# Workspace Setup
# =========================================================================

setup_dirs:
	@echo "=================================================="
	@echo "Initializing project directory tree..."
	@echo "=================================================="
	@mkdir -p $(HDL_TEMP_DIR)
	@mkdir -p $(DUMP_DIR)
	@mkdir -p $(FRONTEND_DIR)/VCDs
	@mkdir -p $(CSVS_DIR)
	@mkdir -p $(BACKEND_DIR)/layout/constraints
	@mkdir -p $(BACKEND_DIR)/layout/deliverables
	@mkdir -p $(BACKEND_DIR)/layout/reports
	@mkdir -p $(BACKEND_DIR)/layout/scripts
	@mkdir -p $(BACKEND_DIR)/layout/work
	@mkdir -p $(BACKEND_DIR)/synthesis/constraints
	@mkdir -p $(BACKEND_DIR)/synthesis/deliverables
	@mkdir -p $(BACKEND_DIR)/synthesis/reports
	@mkdir -p $(BACKEND_DIR)/synthesis/scripts
	@mkdir -p $(BACKEND_DIR)/synthesis/work
	@echo "Directory tree initialized."
