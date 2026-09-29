# Usage: vivado -mode batch -source build_bit.tcl
# First run import_sources.tcl to generate build/FM_DEMOD_V/FM_DEMOD_V.xpr.
set root [file dirname [file normalize [info script]]]
set project_file [file join $root build FM_DEMOD_V FM_DEMOD_V.xpr]
if {![file exists $project_file]} {
    error "Project not found: run vivado -mode batch -source import_sources.tcl first"
}
open_project $project_file
set jobs 4
if {[info exists ::env(VIVADO_JOBS)]} { set jobs $::env(VIVADO_JOBS) }
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
set bit_file [file join $root build FM_DEMOD_V FM_DEMOD_V.runs impl_1 fm_demod_board.bit]
if {![file exists $bit_file]} { error "Implementation did not produce a bitstream; inspect Vivado run logs" }
puts "Bitstream: $bit_file"
