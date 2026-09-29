# =============================================================================
# constraints.xdc  -  FM_DEMOD_V  (ported from Quartus FM_DEMOD2)
# Board : XI050CD   FPGA: XC7A50TFGG484-1   I/O: LVCMOS33   Vivado 2025.2
# Top   : fm_demod_board (i_clk_25m, rst_n, ad9226_data[11:0], ad9226_clk,
#                         dac904e_db[13:0], dac904e_clk)
# =============================================================================

# -----------------------------------------------------------------------------
# Clock  (board oscillator i_clk_25m = 25 MHz on W19)
# Top is fm_demod_board: an MMCM inside the wrapper multiplies 25 -> 50 MHz and
# drives the fm_demod_top core, so the demod centre-freq / AGC math stays valid.
# Only the 25 MHz input pin is constrained here; Vivado auto-derives the 50 MHz
# generated clock from the MMCM.
# -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN W19  IOSTANDARD LVCMOS33 } [get_ports i_clk_25m]
create_clock -period 40.000 -name clk25 [get_ports i_clk_25m]

# -----------------------------------------------------------------------------
# Reset  (active-low) -> push-button i_key[0] = V18
# -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN V18  IOSTANDARD LVCMOS33 } [get_ports rst_n]

# -----------------------------------------------------------------------------
# Status LEDs (active-low) - same pinout as the 2023H board
#   LED0 = FM detected, LED3 = AM detected (both off until decision locked)
# -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN P17  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {o_led[0]}]
set_property -dict { PACKAGE_PIN V20  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {o_led[1]}]
set_property -dict { PACKAGE_PIN V22  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {o_led[2]}]
set_property -dict { PACKAGE_PIN U21  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {o_led[3]}]

# -----------------------------------------------------------------------------
# Test clock output C2  (222.222 MHz from MMCM CLKOUT0 = 750/3.375)
# -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN C2  IOSTANDARD LVCMOS33 DRIVE 8 } [get_ports o_test_clk]

# =============================================================================
# ADC  AD9226 (12-bit)  ->  ad9226_data[11:0] , encode clock ad9226_clk
# =============================================================================
set_property -dict { PACKAGE_PIN L21  IOSTANDARD LVCMOS33 DRIVE 8 } [get_ports ad9226_clk]
set_property -dict { PACKAGE_PIN M20  IOSTANDARD LVCMOS33 } [get_ports {ad9226_data[0]}]
set_property -dict { PACKAGE_PIN J16  IOSTANDARD LVCMOS33 } [get_ports {ad9226_data[1]}]
set_property -dict { PACKAGE_PIN M21  IOSTANDARD LVCMOS33 } [get_ports {ad9226_data[2]}]
set_property -dict { PACKAGE_PIN J19  IOSTANDARD LVCMOS33 } [get_ports {ad9226_data[3]}]
set_property -dict { PACKAGE_PIN M22  IOSTANDARD LVCMOS33 } [get_ports {ad9226_data[4]}]
set_property -dict { PACKAGE_PIN J15  IOSTANDARD LVCMOS33 } [get_ports {ad9226_data[5]}]
set_property -dict { PACKAGE_PIN N20  IOSTANDARD LVCMOS33 } [get_ports {ad9226_data[6]}]
set_property -dict { PACKAGE_PIN K16  IOSTANDARD LVCMOS33 } [get_ports {ad9226_data[7]}]
set_property -dict { PACKAGE_PIN N22  IOSTANDARD LVCMOS33 } [get_ports {ad9226_data[8]}]
set_property -dict { PACKAGE_PIN L16  IOSTANDARD LVCMOS33 } [get_ports {ad9226_data[9]}]
set_property -dict { PACKAGE_PIN J17  IOSTANDARD LVCMOS33 } [get_ports {ad9226_data[10]}]
set_property -dict { PACKAGE_PIN K19  IOSTANDARD LVCMOS33 } [get_ports {ad9226_data[11]}]

# =============================================================================
# DAC  DAC904E (14-bit)  ->  dac904e_db[13:0] , clock dac904e_clk
# (core DAC_WIDTH=14, offset-binary; dac904e_db[13]=MSB)
# =============================================================================
set_property -dict { PACKAGE_PIN H22  IOSTANDARD LVCMOS33 DRIVE 8 } [get_ports dac904e_clk]
set_property -dict { PACKAGE_PIN H19  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[0]}]
set_property -dict { PACKAGE_PIN L20  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[1]}]
set_property -dict { PACKAGE_PIN H18  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[2]}]
set_property -dict { PACKAGE_PIN K22  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[3]}]
set_property -dict { PACKAGE_PIN H17  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[4]}]
set_property -dict { PACKAGE_PIN K21  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[5]}]
set_property -dict { PACKAGE_PIN G17  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[6]}]
set_property -dict { PACKAGE_PIN J21  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[7]}]
set_property -dict { PACKAGE_PIN G16  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[8]}]
set_property -dict { PACKAGE_PIN J22  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[9]}]
set_property -dict { PACKAGE_PIN G15  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[10]}]
set_property -dict { PACKAGE_PIN J20  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[11]}]
set_property -dict { PACKAGE_PIN H15  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[12]}]
set_property -dict { PACKAGE_PIN H20  IOSTANDARD LVCMOS33 DRIVE 4 } [get_ports {dac904e_db[13]}]

# ad9226_clk / dac904e_clk are the 50 MHz core clock forwarded through ODDR.
# o_test_clk is the 222.222 MHz test clock forwarded through ODDR.
# Their source-synchronous timing is defined in the section at the end of file.

# =============================================================================
# Configuration (SPI x1, 50 MHz, non-32-bit-addr)
# =============================================================================
set_property CONFIG_VOLTAGE 3.3        [current_design]
set_property CFGBVS VCCO                [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1            [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50             [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE            [current_design]

# =============================================================================
# Source-synchronous timing  (forwarded clocks + ADC/DAC I/O delays)
#
# EDIT these to the real AD9226 / DAC904E datasheet numbers and PCB trace skew.
#   ADC_TCO_*  : AD9226 data output delay after encode-clk rising edge (t_OD)
#   DAC_TSU/TH : DAC904E data setup / hold around dac-clk rising edge
#   BRD_SKEW   : one-sided clk-vs-data PCB trace skew budget
# Defaults below are REPRESENTATIVE placeholders, not guaranteed values.
# =============================================================================
set ADC_TCO_MAX 6.0
set ADC_TCO_MIN 2.5
set DAC_TSU     2.0
set DAC_TH      1.5
set BRD_SKEW    0.5

# ---- Forwarded output clocks: divide_by 1 of their respective core clocks ----
create_generated_clock -name ad9226_clk_out \
    -source [get_pins oddr_adc_clk/C] -divide_by 1 [get_ports ad9226_clk]
create_generated_clock -name dac904e_clk_out \
    -source [get_pins oddr_dac_clk/C] -divide_by 1 [get_ports dac904e_clk]
create_generated_clock -name o_test_clk_out \
    -source [get_pins oddr_test_clk/C] -divide_by 1 [get_ports o_test_clk]

# ---- ADC capture: ad9226_data valid relative to the forwarded encode clock ----
set_input_delay -clock ad9226_clk_out -max [expr {$ADC_TCO_MAX + $BRD_SKEW}] [get_ports {ad9226_data[*]}]
set_input_delay -clock ad9226_clk_out -min [expr {$ADC_TCO_MIN - $BRD_SKEW}] [get_ports {ad9226_data[*]}]

# ---- DAC launch: dac904e_db setup/hold at DAC vs forwarded clock ----
set_output_delay -clock dac904e_clk_out -max [expr {$DAC_TSU + $BRD_SKEW}]      [get_ports {dac904e_db[*]}]
set_output_delay -clock dac904e_clk_out -min [expr {-($DAC_TH + $BRD_SKEW)}]    [get_ports {dac904e_db[*]}]

# ---- Async push-button reset: do not time it ----
set_false_path -from [get_ports rst_n]

# NOTE: data is launched by the 50 MHz core clock and the forwarded clock is
# SAME-edge. If the DAC output fails setup by ~half a period (or the ADC capture
# is off by a bit), forward an inverted clock by swapping D1/D2 in the ODDR
# instances (oddr_adc_clk / oddr_dac_clk) in fm_demod_board.v -- this XDC stays
# valid. The AD9226 also has pipeline latency (functional, multi-cycle); only
# bit alignment is constrained here.
