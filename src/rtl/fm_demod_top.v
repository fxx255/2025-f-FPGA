module fm_demod_top #(
    parameter ADC_WIDTH  = 12,
    parameter DAC_WIDTH  = 12,
    parameter ADC_OFFSET_BINARY = 1,
    parameter BYPASS_SCAN = 0   // 1 = skip FFT scan, use MANUAL_FREQ directly
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [ADC_WIDTH-1:0] adc_data,
    output reg  [DAC_WIDTH-1:0] dac_data
);

// ===================== FSM States =====================
localparam S_SCAN   = 3'd0;
localparam S_WAIT   = 3'd1;
localparam S_CALIB  = 3'd2;
localparam S_DEMOD  = 3'd3;

reg [2:0] state;
reg [31:0] lo_freq_word;

// ===================== ADC — signed 16-bit =====================
wire signed [15:0] fm_in;

generate
    if (ADC_OFFSET_BINARY) begin : gen_offset_binary
        wire [ADC_WIDTH-1:0] adc_signed;
        assign adc_signed = {~adc_data[ADC_WIDTH-1], adc_data[ADC_WIDTH-2:0]};
        assign fm_in = { {(16-ADC_WIDTH){adc_signed[ADC_WIDTH-1]}}, adc_signed };
    end else begin : gen_two_comp
        assign fm_in = { {(16-ADC_WIDTH){adc_data[ADC_WIDTH-1]}}, adc_data };
    end
endgenerate

// ===================== FFT Scanner (1024-pt opencores) =====================
wire        scan_done;
wire [31:0] scan_freq_word;
wire [9:0]  scan_peak_bin;
wire [31:0] scan_peak_mag;

fft_scanner_wrapper scanner_inst (
    .clk        (clk),
    .rst_n      (rst_n),
    .sample_in  (fm_in),
    .scan_start (state == S_SCAN),
    .scan_done  (scan_done),
    .freq_word  (scan_freq_word),
    .peak_bin   (scan_peak_bin),
    .peak_mag   (scan_peak_mag)
);

// ===================== FM Demodulator =====================
// DISCR=20: sensitive baseline; auto-deviation-gain normalizes 5kHz~75kHz
wire signed [15:0] demod_out;

localparam DISCR = 26;  // baseline: works for ±75kHz, smaller dev needs gain

fm_demodulator_improved #(
    .DISCR_SCALE (DISCR),
    .LPF_TAPS    (16),
    .POST_TAPS   (64)
) demod_inst (
    .clk       (clk),
    .rst_n     (rst_n),
    .fm_in     (fm_in),
    .freq_word (lo_freq_word),
    .demod_out (demod_out)
);

// ===================== Control FSM =====================
localparam FREQ_10MHZ = 32'd858993459;  // 10 MHz: 0x33333333

reg [31:0] freq_hold;  // latch scan result

// Auto deviation detection registers (declared early for FSM reference)
reg [16:0] calib_cnt;
reg [15:0] peak_abs;
reg        calib_done;
reg [2:0]  dev_gain;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state        <= S_SCAN;
        lo_freq_word <= FREQ_10MHZ;
        freq_hold    <= FREQ_10MHZ;
    end else begin
        if (BYPASS_SCAN) begin
            lo_freq_word <= FREQ_10MHZ;
            freq_hold    <= FREQ_10MHZ;
            state        <= S_DEMOD;
        end else begin
            case (state)
                S_SCAN: begin
                    if (scan_done) begin
                        freq_hold    <= scan_freq_word;
                        lo_freq_word <= scan_freq_word;
                        state        <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    lo_freq_word <= freq_hold;
                    state        <= S_CALIB;
                end
                S_CALIB: begin
                    lo_freq_word <= freq_hold;
                    // calib_done set by deviation measurement block
                    if (calib_done)
                        state <= S_DEMOD;
                end
                S_DEMOD: begin
                    lo_freq_word <= freq_hold;
                end
                default: state <= S_SCAN;
            endcase
        end
    end
end

// ===================== Auto Deviation Detection & Gain =====================
// Measure peak of |demod_out| over ~2.6ms (131072 samples), then set gain_shift
// to normalize output to ~25% full-scale regardless of deviation (5kHz~75kHz).

wire signed [15:0] demod_raw_abs = (demod_out[15]) ? -demod_out : demod_out;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        calib_cnt  <= 17'd0;
        peak_abs   <= 16'd0;
        calib_done <= 1'b0;
        dev_gain   <= 3'd3;    // initial: 8x gain (safe mid-range)
    end else begin
        case (state)
            S_CALIB: begin
                calib_cnt <= calib_cnt + 1;
                // track peak absolute value
                if (demod_raw_abs > peak_abs)
                    peak_abs  <= demod_raw_abs[15:0];

                // After 131072 samples (~2.6ms, ~9 cycles @ 3.4kHz), compute gain
                if (calib_cnt == 17'd131071) begin
                    calib_done <= 1'b1;
                    // Map peak → gain_shift to reach target ~8192-16384 (25-50% FS)
                    // DISCR=26 baseline: ±75kHz → peak~8192, ±5kHz → peak~546
                    if (peak_abs < 16'd512)
                        dev_gain <= 3'd5;      // ×32:   ~512 → ~16384
                    else if (peak_abs < 16'd1024)
                        dev_gain <= 3'd4;      // ×16:  ~1024 → ~16384
                    else if (peak_abs < 16'd2048)
                        dev_gain <= 3'd3;      // ×8:   ~2048 → ~16384
                    else if (peak_abs < 16'd4096)
                        dev_gain <= 3'd2;      // ×4:   ~4096 → ~16384
                    else if (peak_abs < 16'd8192)
                        dev_gain <= 3'd1;      // ×2:   ~8192 → ~16384
                    else
                        dev_gain <= 3'd0;      // ×1:  already 8192+
                end
            end
            default: begin
                calib_cnt  <= 17'd0;
                peak_abs   <= 16'd0;
                calib_done <= 1'b0;
            end
        endcase
    end
end

// Apply deviation gain: arithmetic left-shift with saturation
wire signed [31:0] demod_gained;
assign demod_gained = (dev_gain == 3'd0) ? $signed(demod_out) :
                      (dev_gain == 3'd1) ? $signed(demod_out) <<< 1 :
                      (dev_gain == 3'd2) ? $signed(demod_out) <<< 2 :
                      (dev_gain == 3'd3) ? $signed(demod_out) <<< 3 :
                      (dev_gain == 3'd4) ? $signed(demod_out) <<< 4 :
                                           $signed(demod_out) <<< 5;

// ===================== LPF + DC + 20ms AGC =====================
reg signed [31:0] lpf_acc, dc_acc;
wire signed [15:0] demod_scaled = ($signed(demod_gained) > 32'sd32767) ? 16'sd32767 :
                                  ($signed(demod_gained) < -32'sd32768) ? -16'sd32768 :
                                  demod_gained[15:0];

wire signed [15:0] demod_lpf   = lpf_acc >>> 10;
wire signed [15:0] demod_clean = demod_lpf - (dc_acc >>> 15);

reg [47:0] rms_acc;
reg [19:0] agc_cnt;
reg [3:0]  agc_sh;   // gain = 2^(agc_sh-2)

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lpf_acc <= 0; dc_acc <= 0; rms_acc <= 0; agc_cnt <= 0; agc_sh <= 4'd3;
    end else if (state == S_DEMOD || state == S_CALIB) begin
        lpf_acc <= lpf_acc + (demod_scaled - demod_lpf);
        dc_acc  <= dc_acc + (demod_lpf - (dc_acc >>> 15));
        if (state == S_DEMOD) begin
            rms_acc <= rms_acc + ($signed(demod_clean) * $signed(demod_clean));
            agc_cnt <= agc_cnt + 1;
            if (agc_cnt == 20'd1000000) begin
                agc_cnt <= 0;
                if (rms_acc > 48'd200000000000 && agc_sh > 4'd0)
                    agc_sh <= agc_sh - 1;
                else if (rms_acc < 48'd10000000000 && agc_sh < 4'd8)
                    agc_sh <= agc_sh + 1;
                rms_acc <= 0;
            end
        end
    end
end

wire signed [31:0] agc_gained = (agc_sh > 2) ? (demod_clean << (agc_sh - 2)) :
                                 (demod_clean >>> (2 - agc_sh));
wire signed [15:0] dac_source;
assign dac_source = (state == S_DEMOD) ?
    (agc_gained > 32'sd32767 ? 16'sd32767 : agc_gained < -32'sd32768 ? -16'sd32768 : agc_gained[15:0]) : 16'sd0;

wire [DAC_WIDTH-1:0] dac_raw;

generate
    if (DAC_WIDTH >= 16) begin : gen_dac_full
        wire [15:0] dac_offset = dac_source ^ {1'b1, {15{1'b0}}};
        assign dac_raw = dac_offset[15 : 16-DAC_WIDTH];
    end else begin : gen_dac_trunc
        wire signed [DAC_WIDTH-1:0] dac_trunc;
        assign dac_trunc = dac_source[15 : 16-DAC_WIDTH];
        assign dac_raw = dac_trunc ^ {1'b1, {(DAC_WIDTH-1){1'b0}}};
    end
endgenerate

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        dac_data <= {DAC_WIDTH{1'b0}};
    else
        dac_data <= dac_raw;
end

endmodule
