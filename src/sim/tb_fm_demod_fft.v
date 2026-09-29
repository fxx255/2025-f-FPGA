// =============================================================================
// tb_fm_demod_fft.v - Testbench for FFT-based wideband FM demodulator
// 10 MHz carrier FM, 3.4 kHz baseband, 60 kHz deviation
// Compatible: Vivado xsim, ModelSim, iverilog
// =============================================================================

`timescale 1ns / 1ps

module tb_fm_demod_fft;

reg clk;
reg rst_n;

// ===================== FM Test Signal Source (ROM) =====================
wire signed [15:0] fm_src;
wire [17:0] rom_addr;

fm_signal_rom #(
    .ROM_DEPTH(166667)
) fm_rom_inst (
    .clk     (clk),
    .rst_n   (rst_n),
    .enable  (1'b1),
    .fm_out  (fm_src),
    .mod_out (),
    .addr    (rom_addr)
);

// Convert signed 16-bit FM -> ADC offset binary (16-bit ADC, no truncation)
wire [15:0] adc_data;
assign adc_data = fm_src ^ {1'b1, {15{1'b0}}};

// ===================== DUT =====================
wire [15:0] dac_data;

fm_am_demod_top #(
    .ADC_WIDTH(16),
    .DAC_WIDTH(16),
    .ADC_OFFSET_BINARY(1),
    // DEBUG: force LO to correct 10 MHz word (bypass FFT scanner) to verify
    // the demod chain. Set to 0 to test the real auto-scan path.
    .FORCE_FREQ(32'h00000000)
) dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .adc_data (adc_data),
    .dac_data (dac_data),
    .o_retry_led()   // Bug 4: unused in simulation
);

// ===================== Clock (50 MHz, 20ns period) =====================
always #10 clk = ~clk;

// ===================== DAC output signed decode =====================
wire signed [15:0] dac_signed;
assign dac_signed = dac_data ^ {1'b1, {15{1'b0}}};

// ===================== Debug probes (view as Signed Decimal) =====================
// CORDIC limiter output: should settle near +/-16384 (constant envelope)
wire signed [17:0] dbg_i_norm   = dut.fm_demod_inst.u_limiter.i_norm;
wire signed [17:0] dbg_q_norm   = dut.fm_demod_inst.u_limiter.q_norm;
// Envelope magnitude estimate |i_norm| for quick eyeballing
wire signed [17:0] dbg_i_abs    = dbg_i_norm[17] ? -dbg_i_norm : dbg_i_norm;
// Discriminator raw output (pre output-chain)
wire signed [15:0] dbg_fm_out   = dut.fm_demod_out;
wire signed [31:0] dbg_discr    = dut.fm_demod_inst.discr;
// Output-chain intermediates
wire signed [15:0] dbg_raw_out   = dut.raw_out;
wire signed [15:0] dbg_demod_lpf = dut.demod_lpf;
wire signed [15:0] dbg_demod_cln = dut.demod_clean;
wire signed [31:0] dbg_agc_out   = dut.agc_out;
// Gain/AGC state
wire [2:0] dbg_dev_gain = dut.dev_gain;
wire [3:0] dbg_agc_sh   = dut.agc_sh;
wire       dbg_is_fm    = dut.is_fm;

// ===================== Expected: 10 MHz =====================
// 10e6 * 2^32 / 50e6 = 858993459 = 0x33333333
// 1024pt FFT: bin≈205
localparam CARRIER_FW = 32'd858993459;

// ===================== Simulation =====================
integer scan_done_time;

initial begin
    clk   = 1'b0;
    rst_n = 1'b0;

    #200;
    rst_n = 1'b1;

    @(posedge dut.scanner_inst.scan_done);
    scan_done_time = $time / 1000;
    $display("[%0t ns] SCAN DONE: freq_word=0x%0h, peak_bin=%0d, peak_mag=%0d",
             $time, dut.scanner_inst.freq_word,
             dut.scanner_inst.peak_bin, dut.scanner_inst.peak_mag);
    $display("[%0t ns] Expected ~0x33333333 for 10 MHz", $time);

    // Wait for calibration to complete (~2.6ms)
    @(posedge dut.calib_done);
    $display("[%0t ns] CALIB DONE:", $time);
    $display("  fm_energy=%0d, am_energy=%0d", dut.fm_energy, dut.am_energy);
    $display("  is_fm=%0d, dev_gain=%0d", dut.is_fm, dut.dev_gain);

    repeat(510) @(posedge clk);
    $display("[%0t ns] lo_freq_word=0x%0h  fm_out=%0d  am_out=%0d  dac_signed=%0d",
             $time, dut.lo_freq_word, $signed(dut.fm_demod_out), $signed(dut.am_demod_out), $signed(dac_signed));

    repeat(20000) @(posedge clk);
    $display("[%0t ns] Done. Scan:%0d us, Calib:%0d us", $time, scan_done_time,
             ($time/1000 - scan_done_time));
    $finish;
end

// ===================== Waveform Dump =====================
// VCD dump: only for ModelSim / iverilog (not xsim)
// Define VCD_DUMP when running with ModelSim:  vsim +define+VCD_DUMP ...
`ifdef VCD_DUMP
initial begin
    $dumpfile("vcd/tb_fm_demod_fft.vcd");
    $dumpvars(0, tb_fm_demod_fft);
end
`endif

endmodule
