# =============================================================================
# import_sources.tcl
# Creates a portable FM_DEMOD_V project from the source files in this repository.
#
# Usage (either one):
#   A) Batch:  vivado -mode batch -source import_sources.tcl
#   B) GUI Tcl console (empty session): source import_sources.tcl
#
# Output: build/FM_DEMOD_V/FM_DEMOD_V.xpr (not committed to Git).
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set rtl_dir     [file join $script_dir src rtl]
set sim_dir     [file join $script_dir src sim]
set constr_dir  [file join $script_dir src constrs]

# ---- Create a clean project when run as a standalone batch script ----
if {[current_project -quiet] eq ""} {
    create_project -force FM_DEMOD_V [file join $script_dir build FM_DEMOD_V] -part xc7a50tfgg484-1
}

set_property target_language Verilog [current_project]

# =============================================================================
# Synthesis sources (sources_1)
# =============================================================================
set rtl_files [list \
    [file join $rtl_dir fm_demod_board.v] \
    [file join $rtl_dir fm_am_demod_top.v] \
    [file join $rtl_dir fm_demod_top.v] \
    [file join $rtl_dir fm_demodulator_improved.v] \
    [file join $rtl_dir cordic_limiter.v] \
    [file join $rtl_dir am_demodulator.v] \
    [file join $rtl_dir fft_scanner_wrapper.v] \
    [file join $rtl_dir fftmain.v] \
    [file join $rtl_dir fftstage.v] \
    [file join $rtl_dir hwbfly.v] \
    [file join $rtl_dir qtrstage.v] \
    [file join $rtl_dir laststage.v] \
    [file join $rtl_dir bitreverse.v] \
    [file join $rtl_dir butterfly.v] \
    [file join $rtl_dir longbimpy.v] \
    [file join $rtl_dir bimpy.v] \
    [file join $rtl_dir shiftaddmpy.v] \
    [file join $rtl_dir convround.v] \
]
add_files -norecurse -fileset sources_1 $rtl_files

# ---- FFT twiddle-coefficient ROMs (read by $readmemh in fftstage.v) ----
# Added to the fileset so synthesis can locate them on the readmem search path.
set cmem_files [glob -nocomplain [file join $rtl_dir cmem_*.hex]]
if {[llength $cmem_files] > 0} {
    add_files -norecurse -fileset sources_1 $cmem_files
}

set_property top fm_demod_board [get_filesets sources_1]
update_compile_order -fileset sources_1

# =============================================================================
# Simulation sources (sim_1)
# =============================================================================
set sim_files [list \
    [file join $sim_dir tb_fm_demod_fft.v] \
    [file join $sim_dir fm_signal_rom.v] \
    [file join $sim_dir fm_signal_hex.txt] \
    [file join $sim_dir mod_signal_hex.txt] \
]
add_files -norecurse -fileset sim_1 $sim_files
set_property top tb_fm_demod_fft [get_filesets sim_1]
update_compile_order -fileset sim_1

# =============================================================================
# Constraints (constrs_1)
# =============================================================================
add_files -norecurse -fileset constrs_1 [file join $constr_dir constraints.xdc]

puts "============================================================"
puts " FM_DEMOD sources imported."
puts "   Top (synth/impl): fm_demod_board  (25->50 MHz MMCM + fm_demod_top)"
puts "   Top (sim):        tb_fm_demod_fft"
puts " NOTE 1: verify board pinout and replace placeholder ADC/DAC timing values in constraints.xdc."
puts " NOTE 2: for behavioral sim, the testbench reads"
puts "         fm_signal_hex.txt / mod_signal_hex.txt via \$readmemh."
puts "         If xsim cannot find them, run python gen_fm_signal.py to"
puts "         copy both stimulus files and cmem_*.hex into the sim run dir."
puts "============================================================"
