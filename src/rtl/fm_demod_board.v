// =============================================================================
// fm_demod_board.v - XI050CD board-level top wrapper
//   * MMCM (MMCME2_BASE) from 25 MHz oscillator
//       VCO = 25 MHz * 30 / 1 = 750 MHz
//       CLKOUT0 = 750/3.375 = 222.222 MHz (forward to C2 via ODDR)
//       CLKOUT1 = 750/15    = 50 MHz      (core + ADC/DAC clocks)
//   * AD9226 (12-bit ADC) -> core adc_data[11:0]  (IOB-registered for timing)
//   * core dac_data[13:0] (DAC_WIDTH=14, offset binary) -> DAC904E db[13:0]
//   * ad9226_clk / dac904e_clk are the 50 MHz core clock forwarded via ODDR
//   * o_test_clk is the 222.222 MHz test clock forwarded via ODDR (C2)
// =============================================================================
module fm_demod_board (
    input  wire        i_clk_25m,        // W19, 25 MHz board crystal
    input  wire        rst_n,            // V18 (i_key[0]), active-low

    input  wire [11:0] ad9226_data,      // AD9226 12-bit data
    output wire        ad9226_clk,       // AD9226 encode clock (50 MHz)

    output wire [13:0] dac904e_db,       // DAC904E 14-bit data
    output wire        dac904e_clk,      // DAC904E clock (50 MHz)

    output wire [3:0]  o_led,            // status LEDs (active-low)

    output wire        o_test_clk        // C2, 222.222 MHz test clock output
);

    // -------------------- 25 -> 50 MHz + 222.222 MHz MMCM ---------------
    // VCO = 25 MHz * 30 / 1 = 750 MHz
    // CLKOUT0: 750/3.375   = 222.222 MHz (fractional)
    // CLKOUT1: 750/15      = 50 MHz      (integer)
    wire clk50_unbuf, clk50;
    wire clk222_unbuf, clk222;
    wire clkfb_unbuf, clkfb;
    wire locked;

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKIN1_PERIOD      (40.000),   // 25 MHz
        .DIVCLK_DIVIDE      (1),
        .CLKFBOUT_MULT_F    (30.000),   // VCO = 750 MHz
        .CLKFBOUT_PHASE     (0.000),
        .CLKOUT0_DIVIDE_F   (3.375),    // 222.222 MHz  (750/3.375)
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT0_PHASE      (0.000),
        .CLKOUT1_DIVIDE     (15),       // 50 MHz  (750/15)
        .CLKOUT1_DUTY_CYCLE (0.500),
        .CLKOUT1_PHASE      (0.000),
        .STARTUP_WAIT       ("FALSE")
    ) mmcm_inst (
        .CLKOUT0  (clk222_unbuf),
        .CLKOUT0B (),
        .CLKOUT1  (clk50_unbuf),
        .CLKOUT1B (),
        .CLKOUT2  (),
        .CLKOUT2B (),
        .CLKOUT3  (),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .CLKFBOUT (clkfb_unbuf),
        .CLKFBOUTB(),
        .LOCKED   (locked),
        .CLKIN1   (i_clk_25m),
        .PWRDWN   (1'b0),
        .RST      (~rst_n),
        .CLKFBIN  (clkfb)
    );

    BUFG bufg_fb   (.I(clkfb_unbuf),  .O(clkfb));
    BUFG bufg_clk  (.I(clk50_unbuf),  .O(clk50));
    BUFG bufg_clk222 (.I(clk222_unbuf), .O(clk222));

    // -------------------- Reset synchronizer --------------------
    // rst_n is async push-button; sync it to clk50 for clean internal use.
    // DSP48 blocks require synchronous reset for register packing.
    reg [2:0] rst_sync;
    always @(posedge clk50) begin
        rst_sync <= {rst_sync[1:0], rst_n};
    end

    wire core_rst_n = rst_sync[2] & locked;

    // -------------------- ADC input IOB registers --------------------
    // Capture ADC data at IOB flip-flops for minimal input delay and
    // to decouple the source-synchronous forwarded-clock domain from
    // the internal 50 MHz core clock.
    (* IOB = "TRUE" *) reg [11:0] adc_data_iob;
    always @(posedge clk50) begin
        adc_data_iob <= ad9226_data;
    end

    // -------------------- FM/AM auto-detect demod core (DAC_WIDTH = 14) --------------------
    wire [13:0] dac14;

    wire core_is_fm;
    wire core_mode_valid;
    wire core_retry_led;

    // Production: DIAG_NODE=0 (normal output), FORCE_MODE=0 (auto FM/AM).
    // FM/AM decision now uses the robust peak method (env max/min over the
    // calibration window), not the fragile DC-tracker AC method.
    fm_am_demod_top #(
        .ADC_WIDTH         (12),
        .DAC_WIDTH         (14),
        .ADC_OFFSET_BINARY (1),
        .FORCE_MODE        (2'd0),
        .DIAG_NODE         (3'd0)
    ) u_core (
        .clk          (clk50),
        .rst_n        (core_rst_n),
        .adc_data     (adc_data_iob),
        .dac_data     (dac14),
        .o_is_fm      (core_is_fm),
        .o_mode_valid (core_mode_valid),
        .o_retry_led  (core_retry_led)
    );

    assign dac904e_db = dac14;

    // -------------------- Mode indicator LEDs --------------------
    // Board LEDs are ACTIVE-LOW (drive 0 to light). Before the FM/AM decision
    // is locked (core_mode_valid=0) both LEDs are off. After:
    //   LED0 only -> FM detected, LED3 only -> AM detected.
    // v3.5: when the retry limit is hit (core_retry_led=1) the mode decision is
    // NOT trustworthy (default-FM fallback, no real lock), so blank the FM/AM
    // LEDs and light ONLY LED1. Gate both mode LEDs with ~core_retry_led.
    assign o_led[0] = ~(core_mode_valid &  core_is_fm & ~core_retry_led);  // FM (0 = on)
    assign o_led[1] = ~core_retry_led;                     // Bug 4: retry-limit LED
    assign o_led[2] = 1'b1;   // off
    assign o_led[3] = ~(core_mode_valid & ~core_is_fm & ~core_retry_led);  // AM (0 = on)

    // -------------------- forward 50 MHz to ADC / DAC clocks --------------------
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) oddr_adc_clk (
        .Q (ad9226_clk), .C (clk50), .CE (1'b1),
        .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
    );

    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) oddr_dac_clk (
        .Q (dac904e_clk), .C (clk50), .CE (1'b1),
        .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
    );

    // -------------------- forward 222.222 MHz to C2 --------------------
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) oddr_test_clk (
        .Q (o_test_clk), .C (clk222), .CE (1'b1),
        .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
    );

endmodule
