# frontend/generate_vcd.tcl

set freq $::env(FREQ_MHZ)
set lib  $::env(LIB_TYPE)
set runtime $::env(RUNTIME)

if {$runtime <= 0} {
    set runtime 1000
}

# 1. Open a VCD database with a dynamic name
database -open -vcd vcd_db -into VCDs/counter_${lib}_${freq}_${runtime}.vcd

# 2. Probe all signals within the instantiated synthesized module (DUV)
#probe -create -database vcd_db {DUV} -all -depth all
probe -create -database vcd_db {counter_tb} -all -depth all

# 3. Run the simulation
run ${runtime}ns

# 4. Clean up and exit
exit
