// =============================================================================
// fm_demodulator_improved.v - FM discriminator with CORDIC limiter
//   When BYPASS_NCO_LPF=0 (default): full chain including NCO + mixer + LPF.
//   When BYPASS_NCO_LPF=1: skips NCO/mixer/LPF, uses external i_in/q_in directly
//     (shared NCO+LPF from fm_am_demod_top). fm_in/freq_word are ignored.
// =============================================================================
module fm_demodulator_improved #(
    parameter CLK_FREQ    = 50000000,
    parameter DISCR_SCALE = 8,
    parameter LPF_TAPS    = 16,
    parameter POST_TAPS   = 64,
    parameter BYPASS_NCO_LPF = 0    // 1 = use external filtered IQ
) (
    input  wire               clk,
    input  wire               rst_n,
    // Legacy ports (used when BYPASS_NCO_LPF=0):
    input  wire signed [15:0] fm_in,
    input  wire        [31:0] freq_word,
    // External filtered IQ ports (used when BYPASS_NCO_LPF=1):
    input  wire signed [23:0] i_in,
    input  wire signed [23:0] q_in,
    output reg  signed [15:0] demod_out
);

    localparam PHASE_WIDTH = 32;

    // ---- internal IQ (from either internal or external path) ----
    wire signed [23:0] i_filt_int, q_filt_int;

    generate
        if (BYPASS_NCO_LPF) begin : gen_bypass
            // Use external filtered IQ directly
            assign i_filt_int = i_in;
            assign q_filt_int = q_in;
        end else begin : gen_full
            // ---- NCO: 32-bit DDS with 65-entry quarter-wave LUT ----
            reg [PHASE_WIDTH-1:0] phase_acc;
            reg signed [15:0] lo_cos, lo_sin;

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
                if (!rst_n) begin
                    phase_acc <= 0; lo_cos <= 16'sd32767; lo_sin <= 16'sd0;
                end else begin
                    phase_acc <= phase_acc + freq_word;
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

            // ---- Mixer + LPF ----
            reg signed [31:0] i_mixed, q_mixed;
            reg signed [23:0] i_tap [0:31], q_tap [0:31];
            reg signed [29:0] i_sum, q_sum, i_sum_s1, q_sum_s1;
            reg signed [23:0] i_filt_reg, q_filt_reg;
            integer k;

            localparam LPF_SHIFT = (LPF_TAPS==8)?3:(LPF_TAPS==16)?4:(LPF_TAPS==32)?5:4;

            always @(posedge clk) begin
                if (!rst_n) begin
                    i_mixed<=0; q_mixed<=0; i_filt_reg<=0; q_filt_reg<=0;
                    i_sum<=0; q_sum<=0; i_sum_s1<=0; q_sum_s1<=0;
                    for (k=0;k<32;k=k+1) begin i_tap[k]<=0; q_tap[k]<=0; end
                end else begin
                    i_mixed <= fm_in * lo_cos;
                    q_mixed <= fm_in * lo_sin;
                    i_tap[0] <= i_mixed[30:7];
                    q_tap[0] <= q_mixed[30:7];
                    for (k=1;k<32;k=k+1) begin i_tap[k]<=i_tap[k-1]; q_tap[k]<=q_tap[k-1]; end

                    i_sum_s1 <= $signed({ {6{i_tap[0][23]}},i_tap[0]}) +$signed({ {6{i_tap[1][23]}},i_tap[1]})
                              +$signed({ {6{i_tap[2][23]}},i_tap[2]}) +$signed({ {6{i_tap[3][23]}},i_tap[3]})
                              +$signed({ {6{i_tap[4][23]}},i_tap[4]}) +$signed({ {6{i_tap[5][23]}},i_tap[5]})
                              +$signed({ {6{i_tap[6][23]}},i_tap[6]}) +$signed({ {6{i_tap[7][23]}},i_tap[7]});
                    q_sum_s1 <= $signed({ {6{q_tap[0][23]}},q_tap[0]}) +$signed({ {6{q_tap[1][23]}},q_tap[1]})
                              +$signed({ {6{q_tap[2][23]}},q_tap[2]}) +$signed({ {6{q_tap[3][23]}},q_tap[3]})
                              +$signed({ {6{q_tap[4][23]}},q_tap[4]}) +$signed({ {6{q_tap[5][23]}},q_tap[5]})
                              +$signed({ {6{q_tap[6][23]}},q_tap[6]}) +$signed({ {6{q_tap[7][23]}},q_tap[7]});

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

                    i_filt_reg <= i_sum[29:LPF_SHIFT];
                    q_filt_reg <= q_sum[29:LPF_SHIFT];
                end
            end
            assign i_filt_int = i_filt_reg;
            assign q_filt_int = q_filt_reg;
        end
    endgenerate

    // ===================== CORDIC limiter + Discriminator + Post-filter =====================
    wire signed [17:0] i_norm, q_norm;

    cordic_limiter #(.IN_WIDTH(24), .STAGES(16)) u_limiter (
        .clk(clk), .rst_n(rst_n),
        .i_in(i_filt_int), .q_in(q_filt_int),
        .i_norm(i_norm), .q_norm(q_norm)
    );

    reg signed [17:0] i_prev, q_prev;
    reg signed [47:0] num;
    reg signed [31:0] discr;
    reg signed [31:0] d_tap [0:255];
    reg signed [40:0] d_accum;
    reg signed [31:0] d_filtered;
    integer k;

    localparam POST_SHIFT = (POST_TAPS==32)?5:(POST_TAPS==64)?6:(POST_TAPS==128)?7:(POST_TAPS==256)?8:6;

    always @(posedge clk) begin
        if (!rst_n) begin
            i_prev<=0; q_prev<=0; num<=0; discr<=0; d_filtered<=0; demod_out<=0; d_accum<=0;
        end else begin
            num    <= (i_norm * q_prev) - (q_norm * i_prev);
            i_prev <= i_norm;
            q_prev <= q_norm;
            discr <= num >>> DISCR_SCALE;

            d_tap[0] <= discr;
            for (k=1;k<256;k=k+1) d_tap[k] <= d_tap[k-1];

            d_accum <= $signed(d_accum)
                     - $signed({ {(41-32){d_tap[POST_TAPS-1][31]}}, d_tap[POST_TAPS-1] })
                     + $signed({ {(41-32){discr[31]}}, discr });
            d_filtered <= d_accum >>> POST_SHIFT;

            if ($signed(d_filtered) > 32'sd32767)
                demod_out <= 16'sd32767;
            else if ($signed(d_filtered) < -32'sd32768)
                demod_out <= -16'sd32768;
            else
                demod_out <= d_filtered[15:0];
        end
    end

endmodule
