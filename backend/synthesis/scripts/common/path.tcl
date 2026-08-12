set PROJECT_DIR $env(PROJECT_DIR)
set TECH_DIR $env(TECH_DIR)


#-----------------------------------------------------------------------------
# Common path variables (directory structure dependent)
#-----------------------------------------------------------------------------
set BACKEND_DIR ${PROJECT_DIR}/backend
set SYNT_DIR ${BACKEND_DIR}/synthesis
set SCRIPT_DIR ${SYNT_DIR}/scripts
set RPT_DIR ${SYNT_DIR}/reports
set DEV_DIR ${SYNT_DIR}/deliverables
set LAYOUT_DIR ${BACKEND_DIR}/layout

#-----------------------------------------------------------------------------
# Setting rtl search directories
#-----------------------------------------------------------------------------
set FRONTEND_DIR ${PROJECT_DIR}/frontend
set OTHERS ""
lappend FRONTEND_DIR $OTHERS

#-----------------------------------------------------------------------------
# Setting technology directories
#-----------------------------------------------------------------------------
set LIB_DIR ${TECH_DIR}/gsclib045_svt_v4.4/gsclib045/timing
#lappend LIB_DIR ${TECH_DIR}/io

#set LEF_DIR ${TECH_DIR}/gsclib045_svt_v4.4/gsclib045/lef
#export LEF_DIR ${TECH_DIR}/gsclib045_svt_v4.4/gsclib045/lef
lappend LEF_DIR ${TECH_DIR}/gsclib045_svt_v4.4/gsclib045/lef