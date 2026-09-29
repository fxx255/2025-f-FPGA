// =============================================================================
// fm_am_demod_top.v - FM/AM auto-detection dual-mode demodulator
//   S_SCAN  → FFT finds carrier
//   S_CALIB → Run FM + AM in parallel, measure output energy → decide mode
//   S_DEMOD → Output selected demodulator to DAC
//
//   OPTIMIZED: NCO + mixer + LPF shared between FM and AM paths (same LO).
//   FFT is held in reset after S_SCAN to save DSP power.
// =============================================================================
module fm_am_demod_top #(
    parameter ADC_WIDTH  = 12,
    parameter DAC_WIDTH  = 14,
    parameter ADC_OFFSET_BINARY = 1,
    parameter [31:0] FORCE_FREQ = 32'd0,
    parameter [2:0] DIAG_NODE = 3'd0,
    parameter [1:0] FORCE_MODE = 2'd0,
    parameter [2:0] AM_GAIN_SHIFT = 3'd4,
    parameter [3:0] DEPTH_SHIFT = 4'd2   // 25% AM threshold (was 12.5%); harder to trigger AM
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [ADC_WIDTH-1:0] adc_data,
    output reg  [DAC_WIDTH-1:0] dac_data,
    output wire                 o_is_fm,
    output wire                 o_mode_valid,
    output wire                 o_retry_led     // Bug 4: high when retry limit exceeded
);

// ===================== FSM =====================
localparam S_SCAN   = 3'd0;
localparam S_WAIT   = 3'd1;
localparam S_CALIB  = 3'd2;
localparam S_DEMOD  = 3'd3;

reg [2:0] state;
reg [31:0] lo_freq_word;
reg [31:0] freq_hold;
reg        calib_done;

reg [16:0] calib_cnt;  // 17-bit: 131071 max = 2.62ms cal window
reg [2:0]  dev_gain;
reg [2:0]  am_gain_sh;   // adaptive AM pre-gain (mirrors dev_gain for FM)
reg        is_fm;

// v3: S_WAIT removed — S_SCAN goes directly to S_CALIB.
// Pipeline flush via S_WAIT caused strange-waveform regression (user feedback).
// Occasional first-RST calibration failures are handled by watchdog auto-retry.

// Bug 4: auto-retry watchdog
reg [2:0]  retry_cnt;        // 0..5 retries, saturates at 5
reg [4:0]  wdog_win_cnt;     // counts AGC windows while gain is saturated
wire       wdog_timeout;     // v3.5: 30 windows @ 21ms = ~630ms
reg        retry_now;        // pulsed: forces state back to S_SCAN

// v3: watchdog armed only after physical RST press
reg        wdog_armed;        // set on RST, cleared when AGC converges successfully
reg        wdog_converged;    // window-end pulse: full-window avg in dead-zone AND gain not at ceiling
reg        agc_win_end;       // v3.3: one-cycle pulse at every AGC window end (health-independent)
reg [3:0]  wdog_ok_cnt;       // v3.3: consecutive healthy windows; disarm only after WDOG_OK_WINS
localparam [3:0] WDOG_OK_WINS = 4'd12;  // v3.5: was 8, scaled with timeout increase
reg [19:0] scan_timer;       // S_SCAN timeout counter (~20ms max)

// Output assigns (placed after their reg declarations so strict Verilog
// parsers like xvlog don't flag use-before-declaration; synthesis was lenient).
assign o_mode_valid = (state == S_DEMOD);
assign o_is_fm      = is_fm;
assign o_retry_led  = (retry_cnt >= 3'd5);  // Bug 4: LED1 on after 5 failed retries

// ===================== ADC → signed 16-bit =====================
wire signed [15:0] rf_in;
generate
    if (ADC_OFFSET_BINARY) begin
        wire [ADC_WIDTH-1:0] adc_s;
        assign adc_s = {~adc_data[ADC_WIDTH-1], adc_data[ADC_WIDTH-2:0]};
        assign rf_in = { {(16-ADC_WIDTH){adc_s[ADC_WIDTH-1]}}, adc_s };
    end else begin
        assign rf_in = { {(16-ADC_WIDTH){adc_data[ADC_WIDTH-1]}}, adc_data };
    end
endgenerate

// ===================== FFT Scanner (powered down after scan) =====================
wire        scan_done;
wire [31:0] scan_freq_word;
wire [9:0]  scan_peak_bin;
wire [31:0] scan_peak_mag;
wire        fft_en = (state == S_SCAN);       // only active during carrier scan

fft_scanner_wrapper scanner_inst (
    .clk(clk), .rst_n(rst_n && fft_en),        // held in reset after scan
    .sample_in(rf_in),
    .scan_start(fft_en), .scan_done(scan_done),
    .freq_word(scan_freq_word), .peak_bin(scan_peak_bin), .peak_mag(scan_peak_mag)
);

// ===================== Shared NCO (65-entry quarter-wave LUT) =====================
localparam PHASE_WIDTH = 32;

reg [PHASE_WIDTH-1:0] phase_acc;
reg signed [15:0] lo_cos;
reg signed [15:0] lo_sin;

wire signed [15:0] sin_lut [0:64];
assign sin_lut[0]=16'sd0;     assign sin_lut[1]=16'sd804;   assign sin_lut[2]=16'sd1608;
assign sin_lut[3]=16'sd2410;  assign sin_lut[4]=16'sd3212;  assign sin_lut[5]=16'sd4011;
assign sin_lut[6]=16'sd4808;  assign sin_lut[7]=16'sd5602;  assign sin_lut[8]=16'sd6393;
assign sin_lut[9]=16'sd7179;  assign sin_lut[10]=16'sd7962; assign sin_lut[11]=16'sd8739;
assign sin_lut[12]=16'sd9512; assign sin_lut[13]=16'sd10278;assign sin_lut[14]=16'sd11039;
assign sin_lut[15]=16'sd11793;assign sin_lut[16]=16'sd12539;assign sin_lut[17]=16'sd13279;
assign sin_lut[18]=16'sd14010;assign sin_lut[19]=16'sd14733;assign sin_lut[20]=16'sd15446;
assign sin_lut[21]=16'sd16151;assign sin_lut[22]=16'sd16846;assign sin_lut[23]=16'sd17530;
assign sin_lut[24]=16'sd18204;assign sin_lut[25]=16'sd18868;assign sin_lut[26]=16'sd19519;
assign sin_lut[27]=16'sd20159;assign sin_lut[28]=16'sd20787;assign sin_lut[29]=16'sd21403;
assign sin_lut[30]=16'sd22005;assign sin_lut[31]=16'sd22594;assign sin_lut[32]=16'sd23170;
assign sin_lut[33]=16'sd23732;assign sin_lut[34]=16'sd24279;assign sin_lut[35]=16'sd24811;
assign sin_lut[36]=16'sd25330;assign sin_lut[37]=16'sd25832;assign sin_lut[38]=16'sd26319;
assign sin_lut[39]=16'sd26790;assign sin_lut[40]=16'sd27245;assign sin_lut[41]=16'sd27684;
assign sin_lut[42]=16'sd28106;assign sin_lut[43]=16'sd28511;assign sin_lut[44]=16'sd28898;
assign sin_lut[45]=16'sd29269;assign sin_lut[46]=16'sd29621;assign sin_lut[47]=16'sd29956;
assign sin_lut[48]=16'sd30273;assign sin_lut[49]=16'sd30572;assign sin_lut[50]=16'sd30852;
assign sin_lut[51]=16'sd31114;assign sin_lut[52]=16'sd31357;assign sin_lut[53]=16'sd31581;
assign sin_lut[54]=16'sd31785;assign sin_lut[55]=16'sd31971;assign sin_lut[56]=16'sd32138;
assign sin_lut[57]=16'sd32285;assign sin_lut[58]=16'sd32413;assign sin_lut[59]=16'sd32521;
assign sin_lut[60]=16'sd32609;assign sin_lut[61]=16'sd32678;assign sin_lut[62]=16'sd32728;
assign sin_lut[63]=16'sd32757;assign sin_lut[64]=16'sd32767;

always @(posedge clk) begin
    if (!rst_n || retry_now) begin  // v3.5: retry flushes NCO phase too
        phase_acc <= 0; lo_cos <= 16'sd32767; lo_sin <= 16'sd0;
    end else begin
        phase_acc <= phase_acc + lo_freq_word;
        case (phase_acc[PHASE_WIDTH-1 -: 2])
            2'd0: begin lo_cos <=  sin_lut[7'd64-{1'b0,phase_acc[PHASE_WIDTH-3-:6]}];
                        lo_sin <=  sin_lut[{1'b0,phase_acc[PHASE_WIDTH-3-:6]}]; end
            2'd1: begin lo_cos <= -sin_lut[{1'b0,phase_acc[PHASE_WIDTH-3-:6]}];
                        lo_sin <=  sin_lut[7'd64-{1'b0,phase_acc[PHASE_WIDTH-3-:6]}]; end
            2'd2: begin lo_cos <= -sin_lut[7'd64-{1'b0,phase_acc[PHASE_WIDTH-3-:6]}];
                        lo_sin <= -sin_lut[{1'b0,phase_acc[PHASE_WIDTH-3-:6]}]; end
            default: begin lo_cos <=  sin_lut[{1'b0,phase_acc[PHASE_WIDTH-3-:6]}];
                           lo_sin <= -sin_lut[7'd64-{1'b0,phase_acc[PHASE_WIDTH-3-:6]}]; end
        endcase
    end
end

// ===================== Shared Mixer + 2-stage boxcar LPF (CIC sinc^2) =====================
// Stage 1: 16-tap moving average (parallel adder tree, as before).
// Stage 2: another 16-tap moving average via a recursive running-sum (CIC comb),
//          giving an overall sinc^2 response: sidelobes -13dB -> -26dB, deeper
//          nulls, still exactly linear phase. This suppresses the 2*fc image /
//          sum-frequency leakage that was causing the near-3MHz AM distortion.
// Cost per channel: 1 add + 1 sub + one 16-deep SRL (~24 LUT). No extra DSP.
reg signed [31:0] i_mixed, q_mixed;
reg signed [23:0] i_tap [0:31], q_tap [0:31];
reg signed [29:0] i_sum, q_sum, i_sum_s1, q_sum_s1;
reg signed [23:0] i_lpf1, q_lpf1;              // stage-1 output
reg signed [23:0] i_d2 [0:15], q_d2 [0:15];    // stage-2 delay line (window = 16)
reg signed [29:0] i_rsum, q_rsum;              // stage-2 running sum (24b + 4b headroom)
reg signed [23:0] i_filtered, q_filtered;      // final (stage-2) output

localparam LPF_SHIFT = 4;   // 16-tap FIR (both stages divide by 16)
integer k;

always @(posedge clk) begin
    if (!rst_n || retry_now) begin  // v3.5: flush CIC pipeline on retry
        i_mixed<=0; q_mixed<=0; i_filtered<=0; q_filtered<=0;
        i_sum<=0; q_sum<=0; i_sum_s1<=0; q_sum_s1<=0;
        i_lpf1<=0; q_lpf1<=0; i_rsum<=0; q_rsum<=0;
        for (k=0;k<32;k=k+1) begin i_tap[k]<=0; q_tap[k]<=0; end
        for (k=0;k<16;k=k+1) begin i_d2[k]<=0; q_d2[k]<=0; end
    end else begin
        // Mixer
        i_mixed <= rf_in * lo_cos;
        q_mixed <= rf_in * lo_sin;

        // Shift register
        i_tap[0] <= i_mixed[30:7];
        q_tap[0] <= q_mixed[30:7];
        for (k=1;k<32;k=k+1) begin i_tap[k]<=i_tap[k-1]; q_tap[k]<=q_tap[k-1]; end

        // Stage 1: sum taps 0-7 (registered to break adder chain)
        i_sum_s1 <= $signed({ {6{i_tap[0][23]}},i_tap[0]}) +$signed({ {6{i_tap[1][23]}},i_tap[1]})
                  +$signed({ {6{i_tap[2][23]}},i_tap[2]}) +$signed({ {6{i_tap[3][23]}},i_tap[3]})
                  +$signed({ {6{i_tap[4][23]}},i_tap[4]}) +$signed({ {6{i_tap[5][23]}},i_tap[5]})
                  +$signed({ {6{i_tap[6][23]}},i_tap[6]}) +$signed({ {6{i_tap[7][23]}},i_tap[7]});
        q_sum_s1 <= $signed({ {6{q_tap[0][23]}},q_tap[0]}) +$signed({ {6{q_tap[1][23]}},q_tap[1]})
                  +$signed({ {6{q_tap[2][23]}},q_tap[2]}) +$signed({ {6{q_tap[3][23]}},q_tap[3]})
                  +$signed({ {6{q_tap[4][23]}},q_tap[4]}) +$signed({ {6{q_tap[5][23]}},q_tap[5]})
                  +$signed({ {6{q_tap[6][23]}},q_tap[6]}) +$signed({ {6{q_tap[7][23]}},q_tap[7]});

        // Stage 2: sum s1 + taps 8-15
        i_sum <= i_sum_s1
                +$signed({ {6{i_tap[8][23]}},i_tap[8]}) +$signed({ {6{i_tap[9][23]}},i_tap[9]})
                +$signed({ {6{i_tap[10][23]}},i_tap[10]})+$signed({ {6{i_tap[11][23]}},i_tap[11]})
                +$signed({ {6{i_tap[12][23]}},i_tap[12]})+$signed({ {6{i_tap[13][23]}},i_tap[13]})
                +$signed({ {6{i_tap[14][23]}},i_tap[14]})+$signed({ {6{i_tap[15][23]}},i_tap[15]});
        q_sum <= q_sum_s1
                +$signed({ {6{q_tap[8][23]}},q_tap[8]}) +$signed({ {6{q_tap[9][23]}},q_tap[9]})
                +$signed({ {6{q_tap[10][23]}},q_tap[10]})+$signed({ {6{q_tap[11][23]}},q_tap[11]})
                +$signed({ {6{q_tap[12][23]}},q_tap[12]})+$signed({ {6{q_tap[13][23]}},q_tap[13]})
                +$signed({ {6{q_tap[14][23]}},q_tap[14]})+$signed({ {6{q_tap[15][23]}},q_tap[15]});

        // Stage-1 output (divide by 16)
        i_lpf1 <= i_sum[29:LPF_SHIFT];
        q_lpf1 <= q_sum[29:LPF_SHIFT];

        // ---- Stage 2: recursive 16-tap moving average (CIC comb) ----
        // running_sum += new - delayed[15];  out = running_sum / 16
        i_d2[0] <= i_lpf1;
        q_d2[0] <= q_lpf1;
        for (k=1;k<16;k=k+1) begin i_d2[k]<=i_d2[k-1]; q_d2[k]<=q_d2[k-1]; end

        i_rsum <= i_rsum + $signed({ {6{i_lpf1[23]}}, i_lpf1 })
                         - $signed({ {6{i_d2[15][23]}}, i_d2[15] });
        q_rsum <= q_rsum + $signed({ {6{q_lpf1[23]}}, q_lpf1 })
                         - $signed({ {6{q_d2[15][23]}}, q_d2[15] });

        i_filtered <= i_rsum[29:LPF_SHIFT];
        q_filtered <= q_rsum[29:LPF_SHIFT];
    end
end

// ===================== FM Demodulator (uses shared NCO+LPF output) =====================
localparam DISCR = 8;
wire signed [15:0] fm_demod_out;

fm_demodulator_improved #(.DISCR_SCALE(DISCR), .LPF_TAPS(16), .POST_TAPS(64),
                          .BYPASS_NCO_LPF(1))
fm_demod_inst (.clk(clk), .rst_n(rst_n && !retry_now),  // v3.5: retry flushes post-LPF
    .i_in(i_filtered), .q_in(q_filtered),   // shared filtered baseband IQ
    .demod_out(fm_demod_out));

// ===================== AM Demodulator (uses shared NCO+LPF output) =====================
wire signed [15:0] am_demod_out;
wire signed [31:0] am_env_dc;
wire signed [31:0] am_env_ac;
wire signed [31:0] am_env_raw;

am_demodulator #(.ENV_SCALE(8), .DC_TRACK_SHIFT(16), .LPF_TAPS(16), .POST_TAPS(64),
                 .BYPASS_NCO_LPF(1))
am_demod_inst (.clk(clk), .rst_n(rst_n && !retry_now),  // v3.5: retry flushes internal state
    .i_in(i_filtered), .q_in(q_filtered),   // shared filtered baseband IQ
    .demod_out(am_demod_out),
    .o_env_dc(am_env_dc), .o_env_ac(am_env_ac), .o_env_raw(am_env_raw));

// ===================== Control FSM =====================
localparam FREQ_DEFAULT = 32'd858993459;

wire [31:0] eff_freq_word = (FORCE_FREQ != 32'd0) ? FORCE_FREQ : scan_freq_word;

// Bug 2: validate FFT peak quality — reject noise-floor peaks
wire peak_quality_ok = (scan_peak_mag > 32'd100000) || (FORCE_FREQ != 32'd0);

// Bug 4: watchdog timeout = 15 AGC windows (~315ms)
assign wdog_timeout = (wdog_win_cnt >= 5'd30);  // v3.5: was 15, extended for weak-signal AGC ramp

always @(posedge clk) begin
    if (!rst_n) begin
        state <= S_SCAN; lo_freq_word <= FREQ_DEFAULT; freq_hold <= FREQ_DEFAULT;
        retry_cnt <= 0; retry_now <= 0; scan_timer <= 0;
        wdog_armed <= 1'b1;  // arm watchdog on physical RST
        wdog_ok_cnt <= 4'd0;
    end else begin
        retry_now <= 1'b0;  // pulse, default low

        // v3.3: disarm watchdog only after WDOG_OK_WINS *consecutive* healthy
        // windows. The v3.1/v3.2 "one healthy window disarms" was still wrong:
        // while the AGC gain ramps up, the amplified noise/garbage average
        // *passes through* the dead-zone for a window or two (gain not yet at
        // ceiling, not yet railing) -> that lone window looked converged and
        // permanently disarmed the watchdog. On a CW carrier this meant LED1
        // never lit. Requiring 8 consecutive healthy windows rejects that
        // transient pass-through; genuine lock stays healthy indefinitely.
        // wdog_converged is a window-end pulse, so we only step on window ends.
        if (wdog_armed && state == S_DEMOD && agc_win_end) begin
            if (wdog_converged) begin
                if (wdog_ok_cnt >= WDOG_OK_WINS) wdog_armed <= 1'b0;
                else                             wdog_ok_cnt <= wdog_ok_cnt + 1'b1;
            end else begin
                wdog_ok_cnt <= 4'd0;   // any unhealthy window restarts the count
            end
        end

        // v3.3: consecutive-healthy-window counter is only meaningful inside
        // S_DEMOD; clear it whenever we're not demodulating so a partial count
        // never survives a re-scan/retry.
        if (state != S_DEMOD) wdog_ok_cnt <= 4'd0;

        // Bug 4: auto-retry — trigger when armed AND watchdog times out
        // Only active after physical RST; disarms on successful convergence.
        if (wdog_armed && state == S_DEMOD && wdog_timeout && retry_cnt < 3'd5) begin
            retry_now <= 1'b1;
            retry_cnt <= retry_cnt + 1;
            state <= S_SCAN;   // wdog_win_cnt cleared by AGC block on state change
        end

        case (state)
            S_SCAN: begin
                scan_timer <= scan_timer + 1;
                // v3: go directly to calibration after scan (S_WAIT removed).
                if (scan_done) begin
                    freq_hold <= eff_freq_word; lo_freq_word <= eff_freq_word;
                    state <= S_CALIB;
                    scan_timer <= 0;
                end else if (scan_timer == 20'd1000000) begin  // 20ms timeout
                    // FFT can't find carrier — fall back to default freq and
                    // let calibration + watchdog handle it
                    freq_hold <= FREQ_DEFAULT; lo_freq_word <= FREQ_DEFAULT;
                    state <= S_CALIB;
                    scan_timer <= 0;
                end
            end
            S_CALIB: begin
                lo_freq_word <= freq_hold;
                if (calib_done)
                    state <= S_DEMOD;  // wdog_win_cnt auto-clears in AGC block when entering S_DEMOD
            end
            S_DEMOD: lo_freq_word <= freq_hold;
            default: state <= S_SCAN;
        endcase
    end
end

// ===================== Calibration: Modulation-Depth Decision =====================
reg [15:0] fm_peak;
reg [15:0] am_peak;
reg signed [15:0] fm_prev;
reg signed [23:0] am_dc_fast;
reg signed [31:0] env_max, env_min;

localparam ENV_LP_SHIFT = 9;
localparam AGC_ENV_SETTLE = 17'd4096;
reg  signed [40:0] env_lp_hi;
wire signed [31:0] env_lp = env_lp_hi >>> ENV_LP_SHIFT;
reg [47:0] env_ac_acc;
reg signed [31:0] env_dc_hold;
wire signed [31:0] env_ac_abs = am_env_ac[31] ? -am_env_ac : am_env_ac;

wire signed [15:0] am_ac_coupled = am_demod_out - $signed(am_dc_fast[23:8]);

always @(posedge clk) begin
    if (!rst_n) begin
        calib_cnt <= 0; calib_done <= 0;
        fm_peak <= 0; am_peak <= 0; fm_prev <= 0; am_dc_fast <= 0;
        env_ac_acc <= 0; env_dc_hold <= 0;
        env_lp_hi <= 0;
        env_max <= 32'sh80000000;
        env_min <= 32'sh7FFFFFFF;
        is_fm <= 1'b1;
        dev_gain <= 3'd3;
        am_gain_sh <= AM_GAIN_SHIFT;
    end else begin
        case (state)
            S_CALIB: begin
                calib_cnt <= calib_cnt + 1;
                fm_prev <= fm_demod_out;
                am_dc_fast <= am_dc_fast + (($signed({am_demod_out,8'd0}) - am_dc_fast) >>> 9);

                if (calib_cnt == 0)
                    env_lp_hi <= $signed(am_env_raw) <<< ENV_LP_SHIFT;
                else
                    env_lp_hi <= env_lp_hi + ($signed(am_env_raw) - env_lp);

                if (calib_cnt >= AGC_ENV_SETTLE) begin
                    if (env_lp > env_max) env_max <= env_lp;
                    if (env_lp < env_min) env_min <= env_lp;
                end

                env_ac_acc <= env_ac_acc + {16'd0, env_ac_abs};

                // Track FM peak for deviation gain
                if (fm_demod_out[15]) begin
                    if ((16'd0 - fm_demod_out) > fm_peak) fm_peak <= 16'd0 - fm_demod_out;
                end else begin
                    if (fm_demod_out > fm_peak) fm_peak <= fm_demod_out;
                end

                // Track AM peak (post DC-removal modulation) for adaptive AM pre-gain.
                // Skip the settle transient so the peak reflects steady-state envelope.
                if (calib_cnt >= AGC_ENV_SETTLE) begin
                    if (am_demod_out[15]) begin
                        if ((16'd0 - am_demod_out) > am_peak) am_peak <= 16'd0 - am_demod_out;
                    end else begin
                        if (am_demod_out > am_peak) am_peak <= am_demod_out;
                    end
                end

                if (calib_cnt == 17'd131071) begin  // 2.62ms window
                    calib_done <= 1'b1;
                    env_dc_hold <= am_env_dc;
                    is_fm <= (FORCE_MODE==2'd1) ? 1'b1 :
                             (FORCE_MODE==2'd2) ? 1'b0 :
                             !(((env_max + env_min) > 32'sd0) &&
                               ((env_max - env_min) > ((env_max + env_min) >>> DEPTH_SHIFT)));
                    if (fm_peak < 16'd512)      dev_gain <= 3'd5;
                    else if (fm_peak < 16'd1024) dev_gain <= 3'd4;
                    else if (fm_peak < 16'd2048) dev_gain <= 3'd3;
                    else if (fm_peak < 16'd4096) dev_gain <= 3'd2;
                    else if (fm_peak < 16'd8192) dev_gain <= 3'd1;
                    else                         dev_gain <= 3'd0;

                    // Adaptive AM pre-gain: normalize am_peak to ~8k-16k so the
                    // downstream AGC only does fine trimming (mirrors FM dev_gain).
                    // Fixes small-signal AM undershoot where fixed x16 + AGC hit
                    // the AGC_GAIN_MAX ceiling and only reached ~half of target.
                    // Ceiling raised to <<6 (x64, was <<5/x32) for very small inputs
                    // (e.g. carrier near 3MHz where the envelope comes out weak).
                    if (am_peak < 16'd256)       am_gain_sh <= 3'd6;
                    else if (am_peak < 16'd512)  am_gain_sh <= 3'd5;
                    else if (am_peak < 16'd1024) am_gain_sh <= 3'd4;
                    else if (am_peak < 16'd2048) am_gain_sh <= 3'd3;
                    else if (am_peak < 16'd4096) am_gain_sh <= 3'd2;
                    else if (am_peak < 16'd8192) am_gain_sh <= 3'd1;
                    else                         am_gain_sh <= 3'd0;
                end
            end
            default: begin
                calib_cnt <= 0; calib_done <= 0;
                fm_peak <= 0; fm_prev <= 0; am_dc_fast <= 0;
                env_ac_acc <= 0;
                env_lp_hi <= 0;
                env_max <= 32'sh80000000;
                env_min <= 32'sh7FFFFFFF;
            end
        endcase
    end
end

// ===================== FM Output Processing =====================
wire signed [31:0] fm_gained;
assign fm_gained = (dev_gain==0) ? $signed(fm_demod_out) :
                   (dev_gain==1) ? $signed(fm_demod_out) <<< 1 :
                   (dev_gain==2) ? $signed(fm_demod_out) <<< 2 :
                   (dev_gain==3) ? $signed(fm_demod_out) <<< 3 :
                   (dev_gain==4) ? $signed(fm_demod_out) <<< 4 :
                                   $signed(fm_demod_out) <<< 5;

wire signed [15:0] fm_scaled = ($signed(fm_gained) > 32'sd32767) ? 16'sd32767 :
                               ($signed(fm_gained) < -32'sd32768) ? -16'sd32768 :
                               fm_gained[15:0];

// AM output: apply adaptive coarse gain (mirrors FM dev_gain), so small-signal
// AM is normalized before the AGC instead of relying on AGC headroom alone.
wire signed [31:0] am_gained = (am_gain_sh==0) ? $signed(am_demod_out) :
                               (am_gain_sh==1) ? $signed(am_demod_out) <<< 1 :
                               (am_gain_sh==2) ? $signed(am_demod_out) <<< 2 :
                               (am_gain_sh==3) ? $signed(am_demod_out) <<< 3 :
                               (am_gain_sh==4) ? $signed(am_demod_out) <<< 4 :
                               (am_gain_sh==5) ? $signed(am_demod_out) <<< 5 :
                                                 $signed(am_demod_out) <<< 6;
wire signed [15:0] am_scaled = ($signed(am_gained) > 32'sd32767) ? 16'sd32767 :
                               ($signed(am_gained) < -32'sd32768) ? -16'sd32768 :
                               am_gained[15:0];

wire signed [15:0] raw_out = is_fm ? fm_scaled : am_scaled;

// ===================== LPF + DC + AGC (shared) =====================
// v3.3: ADAPTIVE DC-block time constant (replaces the fixed v3.2 shift=15).
// The accumulator is scaled to <<DCBLK_S (now 22) in BOTH modes, so switching
// the time constant changes ONLY the update step size, never the state's meaning
// -> no rescale glitch. Fast mode (step x128 -> tau=2^15=655us) during acquisition
// discharges the LO-mismatch quasi-DC step quickly (kills the sawtooth). Slow
// mode (tau=2^18=5.24ms, cutoff ~30Hz) once locked, so 2-3kHz square-wave flat
// tops no longer droop (the ~243Hz high-pass was slanting them).
// v3.5: slow tau raised further 2^22 (83.9ms) -> 2^23 (167.8ms, cutoff ~0.95Hz)
// to cut low-freq square-wave flat-top droop to ~1% at 300Hz / ~3% at 100Hz.
// The DC to reject is a STATIC discriminator offset — a 0.95Hz cutoff is still
// fine. Fast-mode tau (655us) unchanged via boost 7->8.
// dc_acc width: steady-state peak = 32768*2^23 = 2.75e11 (needs 39 bits incl sign);
// signed [39:0] (2^39≈5.5e11) leaves ~2x headroom; monotonic convergence no overshoot.
localparam DCBLK_S          = 23;   // accumulator scale / slow tau = 2^23 (167.8ms)
localparam DCBLK_FAST_BOOST = 8;    // fast step x256 -> effective tau = 2^15 (655us)
reg signed [31:0] lpf_acc;
reg signed [39:0] dc_acc;           // widened: demod_lpf(16b) << 22 needs ~38 bits
wire signed [15:0] demod_lpf   = lpf_acc >>> 10;
wire signed [15:0] dc_est      = dc_acc >>> DCBLK_S;
wire signed [15:0] demod_clean = demod_lpf - dc_est;
// DC-block update error, sign-extended to the FULL accumulator width BEFORE any
// shift, so the fast-mode <<3 can never truncate high bits (avoids a subtle
// Verilog self-determined-shift-width pitfall on large mismatch DC steps).
wire signed [39:0] dc_err_ext = {{24{demod_lpf[15]}}, demod_lpf}
                              - {{24{dc_est[15]}},    dc_est};
// Fast DC-block during acquisition (calib + soft-start), slow once locked.
wire dcblk_fast = (state==S_CALIB) || (settle_cnt < SETTLE_WINS);
wire signed [39:0] dc_step    = dcblk_fast ? (dc_err_ext <<< DCBLK_FAST_BOOST)
                                           :  dc_err_ext;

localparam AGC_WIN_SHIFT = 20;
localparam [AGC_WIN_SHIFT-1:0] AGC_WIN = {AGC_WIN_SHIFT{1'b1}};
reg [36:0] amp_acc;
reg [AGC_WIN_SHIFT-1:0] agc_cnt;

localparam [15:0] AGC_TARGET   = 16'd12000;
localparam [15:0] AGC_DEAD     = 16'd800;   // v3.2: widened 400->800 to stop dead-zone hunting
localparam [15:0] AGC_FAR      = 16'd2000;
localparam [15:0] AGC_VFAR     = 16'd6000;
localparam [17:0] AGC_COARSE   = 18'd48;
localparam [17:0] AGC_GAIN_MIN = 18'd64;
localparam [17:0] AGC_GAIN_MAX = 18'd163840;  // x640 (was x320) — ceiling doubled
reg [17:0] agc_gain;

// v3.2: clip-based watchdog + AGC soft-start.
// Old watchdog watched "average amplitude below target"; but the pathological
// railing waveforms are FULL-SCALE, so their average is HIGH and the old logic
// cleared the counter every window (line "converged: reset") -> never fired.
// New health metric: fraction of samples that CLIP near full-scale per window.
localparam [15:0] CLIP_LEVEL  = 16'd30000;          // |agc_final| >= this counts as clipped
localparam [AGC_WIN_SHIFT-1:0] CLIP_THRESH = {2'b0, {(AGC_WIN_SHIFT-2){1'b1}}}; // ~25% of window
localparam [2:0]  SETTLE_WINS = 3'd4;               // v3.5: was 2; longer ramp-up grace for weak signals
reg [AGC_WIN_SHIFT-1:0] clip_cnt;   // clipped samples in current window
reg [2:0]  settle_cnt;              // counts S_DEMOD windows since entry (soft-start hold-off)

always @(posedge clk) begin
    if (!rst_n || retry_now) begin
        lpf_acc<=0; dc_acc<=0; amp_acc<=0; agc_cnt<=0; agc_gain<=18'd256;
        wdog_win_cnt <= 0;
        wdog_converged <= 1'b0;
        agc_win_end <= 1'b0;
        clip_cnt <= 0; settle_cnt <= 0;
    end else begin
        wdog_converged <= 1'b0;   // window-end pulse, default low
        agc_win_end    <= 1'b0;   // window-end pulse, default low
        // Watchdog counter only meaningful during S_DEMOD; clear otherwise
        if (state != S_DEMOD) begin
            wdog_win_cnt <= 0;
            settle_cnt   <= 0;   // reset soft-start hold-off on leaving S_DEMOD
        end

        if (state==S_DEMOD || state==S_CALIB) begin
        lpf_acc <= lpf_acc + (raw_out - demod_lpf);
        // v3.3: adaptive DC-block. Accumulator always scaled <<DCBLK_S; fast
        // mode just multiplies the error step by 2^DCBLK_FAST_BOOST (x128) so the
        // state meaning is identical in both modes (no glitch on switch).
        dc_acc  <= dc_acc + dc_step;
        if (state==S_DEMOD) begin
            // v3.3: measure the PRE-boost normalized signal (agc_final), so the
            // 300-500Hz cosmetic boost below is NOT regulated away by the AGC.
            amp_acc <= amp_acc + (agc_final[15] ? {21'd0, (16'd0 - agc_final)}
                                                : {21'd0, agc_final});
            // v3.2: count samples that clip near full-scale this window
            if (($signed(agc_final) >= $signed(CLIP_LEVEL)) ||
                ($signed(agc_final) <= -$signed(CLIP_LEVEL)))
                clip_cnt <= clip_cnt + 1'b1;
            agc_cnt <= agc_cnt + 1'b1;
            if (agc_cnt==AGC_WIN) begin
                agc_cnt<=0;
                agc_win_end <= 1'b1;   // v3.3: pulse for FSM's consecutive-window watchdog logic
                if (settle_cnt < SETTLE_WINS) settle_cnt <= settle_cnt + 1'b1;
                // v3.2: soft-start — hold gain at its reset value for the first
                // SETTLE_WINS windows after entering S_DEMOD. Lets the DC-block
                // and pipeline flush the acquisition-time quasi-DC transient
                // BEFORE the AGC reacts, so the AGC never chases that garbage up
                // to the x640 ceiling (root of the railing / 10ms spike).
                // v3: slower geometric stepping to prevent overshoot/oscillation.
                // Far  -> x1.25/÷1.25 per window (was x1.5)
                // Mid  -> x1.0625/÷1.0625 per window (was x1.125)
                // Dead -> fine ±AGC_COARSE (48)
                if (settle_cnt < SETTLE_WINS) begin
                    agc_gain <= agc_gain;   // hold during soft-start
                end else if ((amp_acc>>AGC_WIN_SHIFT) > (AGC_TARGET + AGC_VFAR)) begin
                    if ((agc_gain - (agc_gain>>2)) > AGC_GAIN_MIN)
                        agc_gain <= agc_gain - (agc_gain>>2);       // ÷1.25
                    else agc_gain <= AGC_GAIN_MIN;
                end else if ((amp_acc>>AGC_WIN_SHIFT) < (AGC_TARGET - AGC_VFAR)) begin
                    if ((agc_gain + (agc_gain>>2)) < AGC_GAIN_MAX)
                        agc_gain <= agc_gain + (agc_gain>>2);       // x1.25
                    else agc_gain <= AGC_GAIN_MAX;
                end else if ((amp_acc>>AGC_WIN_SHIFT) > (AGC_TARGET + AGC_FAR)) begin
                    if ((agc_gain - (agc_gain>>4)) > AGC_GAIN_MIN)
                        agc_gain <= agc_gain - (agc_gain>>4);       // ÷1.0625
                    else agc_gain <= AGC_GAIN_MIN;
                end else if ((amp_acc>>AGC_WIN_SHIFT) < (AGC_TARGET - AGC_FAR)) begin
                    if ((agc_gain + (agc_gain>>4)) < AGC_GAIN_MAX)
                        agc_gain <= agc_gain + (agc_gain>>4);       // x1.0625
                    else agc_gain <= AGC_GAIN_MAX;
                end else if ((amp_acc>>AGC_WIN_SHIFT) > (AGC_TARGET + AGC_DEAD)) begin
                    if (agc_gain > AGC_GAIN_MIN+AGC_COARSE) agc_gain <= agc_gain - AGC_COARSE;
                end else if ((amp_acc>>AGC_WIN_SHIFT) < (AGC_TARGET - AGC_DEAD)) begin
                    if (agc_gain < AGC_GAIN_MAX-AGC_COARSE) agc_gain <= agc_gain + AGC_COARSE;
                end

                // v3.4: an UNHEALTHY window is either CLIPPING (railing, from
                // v3.2) OR NOISY (too many zero-crossings). The noise test is
                // the key addition: when the AGC successfully normalizes noise
                // to ~target it is NOT clipping and its amplitude is in-band, so
                // clip/amplitude tests both pass it as "healthy" — only the
                // high zero-crossing rate (which the AGC cannot flatten) reveals
                // it as noise. wdog_bad captures either condition.
                // (noisy_win uses zc_last, updated at this same window end.)
                if (settle_cnt >= SETTLE_WINS && ((clip_cnt > CLIP_THRESH) || bad_freq_win))
                    wdog_win_cnt <= wdog_win_cnt + 1;
                else if ((clip_cnt <= CLIP_THRESH) && !bad_freq_win)
                    wdog_win_cnt <= 0;  // clean window: reset watchdog
                clip_cnt <= 0;          // clear clip counter for next window

                // v3.1: true-convergence pulse for disarming the watchdog in
                // the FSM block. Evaluated ONLY here at window end, so
                // amp_acc>>AGC_WIN_SHIFT is the full-window average (not a
                // mid-window partial sum). In dead-zone AND gain not at
                // ceiling = genuinely locked, not clipping at max gain.
                if ((amp_acc>>AGC_WIN_SHIFT) >= (AGC_TARGET - AGC_DEAD) &&
                    (amp_acc>>AGC_WIN_SHIFT) <= (AGC_TARGET + AGC_DEAD) &&
                    agc_gain < AGC_GAIN_MAX - AGC_COARSE &&
                    clip_cnt <= CLIP_THRESH &&                   // v3.2: not railing
                    !bad_freq_win)                               // v3.5: and freq content sane
                    wdog_converged <= 1'b1;

                amp_acc<=0;
            end
        end
    end
    end
end

// Wide product (16b x 19b = 35b) so high gain x large sample can't wrap 32b.
wire signed [47:0] agc_prod = $signed(demod_clean) * $signed({1'b0, agc_gain});
wire signed [47:0] agc_out  = agc_prod >>> 8;
wire signed [15:0] agc_final = (agc_out > 48'sd32767)  ? 16'sd32767 :
                               (agc_out < -48'sd32768) ? -16'sd32768 : agc_out[15:0];

// ============ v3.4: zero-crossing freq estimate — band boost + NOISE detect ===
// agc_final is amplitude-normalized, so estimate modulation frequency by
// counting HYSTERETIC zero-crossings over one AGC window (2^20 clk @ 50MHz =
// 20.97ms). crossings = 2*f*T:  300Hz->12.6, 400Hz->16.8, 500Hz->21.0.
// Two uses of the per-window count (latched into zc_last, stable for reuse):
//  (a) BAND BOOST of the DAC path (compensates the non-flat post-amp):
//        300-400Hz (zc 12-16) -> x310/256 (+21%),
//        400-500Hz (zc 17-21) -> x282/256 (+10%), else unity.
//      AGC measures PRE-boost agc_final, so it does NOT regulate the boost away.
//  (b) NOISE DETECT for the watchdog: a 2-3kHz tone gives ~84-126 crossings/
//      window, but band-limited noise (post-LPF) gives ~180-255. So a high
//      crossing count is the ONE feature the AGC can't normalize away, and is
//      how we finally distinguish "AGC-normalized noise" (which looked healthy
//      by amplitude/clip) from a real locked tone. zc_last >= ZC_NOISE => noisy.
localparam signed [15:0] ZC_HYST  = 16'sd2000;
localparam [7:0] ZC_NOISE = 8'd150;   // >= this many crossings/window = noise (TUNE on bench)
localparam [7:0] ZC_MIN   = 8'd4;     // <  this many = dead/DC/silence (e.g. output stuck at 0)
reg [7:0] zc_cnt;
reg [7:0] zc_last;        // crossings in the most recently completed window (stable)
reg       zc_pol;         // last confirmed polarity: 1=high, 0=low

always @(posedge clk) begin
    if (!rst_n || retry_now) begin
        zc_cnt <= 8'd0; zc_pol <= 1'b0; zc_last <= 8'd0;
    end else if (state==S_DEMOD) begin
        // hysteretic edge counter: count each confirmed polarity flip
        if (!zc_pol && (agc_final > ZC_HYST)) begin
            zc_pol <= 1'b1;
            if (zc_cnt != 8'hFF) zc_cnt <= zc_cnt + 1'b1;
        end else if (zc_pol && (agc_final < -ZC_HYST)) begin
            zc_pol <= 1'b0;
            if (zc_cnt != 8'hFF) zc_cnt <= zc_cnt + 1'b1;
        end
        // window end: latch count for reuse, restart (reset wins if both fire)
        if (agc_win_end) begin
            zc_last <= zc_cnt;
            zc_cnt  <= 8'd0;
        end
    end else begin
        zc_cnt <= 8'd0; zc_last <= 8'd0;
    end
end

// v3.5: an unhealthy window by frequency content is EITHER too many crossings
// (noise, AGC-normalized so amplitude/clip can't catch it) OR too few (output
// dead/stuck at 0 / quasi-DC, e.g. a prior FM object leaving 0 output — noise
// isn't there to trip the noise test, so the low count is what flags it).
// Only meaningful after soft-start (gated by settle_cnt in the AGC block).
wire noisy_win    = (zc_last >= ZC_NOISE);
wire dead_win     = (zc_last <  ZC_MIN);
wire bad_freq_win = noisy_win || dead_win;   // used by watchdog (see AGC block)

// Band-dependent boost multiplier (Q8: 256 = unity). Combinational from zc_last.
// v3.5: bands re-split so integer freqs land cleanly inside ONE band (no boost
// dithering at 400/500Hz). crossings = 2*f*T (T=20.97ms): 300Hz=12.6,
// 400Hz=16.8, 500Hz=21.0.
//   300-400Hz -> zc 12-17 -> x302/256 (+18%)
//   400-500Hz -> zc 18-22 -> x282/256 (+10%)   (upper bound 22 keeps 500Hz in-band)
reg [8:0] boost_mul;
always @(*) begin
    if      (zc_last >= 8'd12 && zc_last <= 8'd17) boost_mul = 9'd302; // 300-400Hz +18%
    else if (zc_last >= 8'd18 && zc_last <= 8'd22) boost_mul = 9'd282; // 400-500Hz +10%
    else                                           boost_mul = 9'd256; // unity
end

wire signed [31:0] boost_prod = $signed(agc_final) * $signed({1'b0, boost_mul});
wire signed [31:0] boost_out  = boost_prod >>> 8;
wire signed [15:0] agc_boosted = (boost_mul == 9'd256) ? agc_final :
                                 (boost_out > 32'sd32767)  ? 16'sd32767 :
                                 (boost_out < -32'sd32768) ? -16'sd32768 : boost_out[15:0];

// ---- Diagnostic node select ----
localparam DIAG_GAIN = 3;
wire signed [31:0] diag_sel = (DIAG_NODE==3'd1) ? ($signed(fm_demod_out) <<< DIAG_GAIN) :
                              (DIAG_NODE==3'd2) ? ($signed(raw_out)      <<< DIAG_GAIN) :
                              (DIAG_NODE==3'd3) ? ($signed(demod_clean)  <<< DIAG_GAIN) :
                              (DIAG_NODE==3'd4) ? ($signed(am_demod_out) <<< DIAG_GAIN) :
                              (DIAG_NODE==3'd5) ? am_env_dc :
                              (DIAG_NODE==3'd6) ? am_env_ac :
                                                  32'sd0;
wire signed [15:0] diag_sat = (diag_sel>32'sd32767) ? 16'sd32767 :
                              (diag_sel<-32'sd32768) ? -16'sd32768 : diag_sel[15:0];

wire signed [15:0] dac_src = (state!=S_DEMOD) ? 16'sd0 :
                             (DIAG_NODE==3'd0) ? agc_boosted : diag_sat;

// ===================== DAC output =====================
wire [DAC_WIDTH-1:0] dac_raw;
generate
    if (DAC_WIDTH>=16) begin
        wire [15:0] dac_off = dac_src ^ {1'b1,{15{1'b0}}};
        assign dac_raw = dac_off[15:16-DAC_WIDTH];
    end else begin
        wire signed [DAC_WIDTH-1:0] dac_trunc;
        assign dac_trunc = dac_src[15:16-DAC_WIDTH];
        assign dac_raw = dac_trunc ^ {1'b1,{(DAC_WIDTH-1){1'b0}}};
    end
endgenerate

always @(posedge clk) begin
    if (!rst_n) dac_data <= 0; else dac_data <= dac_raw;
end

endmodule
