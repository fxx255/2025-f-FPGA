# Usage: vivado -mode batch -source gen_mcs.tcl
# XI050CD: N25Q128 128 Mb SPI flash, x1 mode. Verify the flash part on your board.
set root [file dirname [file normalize [info script]]]
set bit_file [file join $root build FM_DEMOD_V FM_DEMOD_V.runs impl_1 fm_demod_board.bit]
set mcs_file [file join $root build FM_DEMOD_V FM_DEMOD_V.runs impl_1 fm_demod_board.mcs]
if {![file exists $bit_file]} { error "Bitstream not found: run build_bit.tcl first" }
write_cfgmem -force -format mcs -size 16 -interface SPIx1 -loadbit "up 0x0 $bit_file" -file $mcs_file
puts "MCS file generated: $mcs_file"
