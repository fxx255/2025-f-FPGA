// =============================================================================
// cordic_limiter.v - Constant-envelope limiter via CORDIC vectoring
//
// Removes the amplitude (A) dependence of the delay-line FM discriminator.
// A pipelined CORDIC drives TWO datapaths sharing the same per-stage sigma:
//   - Vectoring path (i_in,q_in): decides sigma_i from the y-sign to rotate the
//     input vector onto the +x axis. (Result discarded; only sigmas are used.)
//   - Rotation path (AMP_PRE,0)  : rotated by the same sigmas, ends up at angle
//     phi = atan2(q_in,i_in) with FIXED magnitude AMP -> constant envelope.
//
// No multiplier / divider / LUT. 16 stages, 1 sample/clk throughput.
// Latency = STAGES + 2 clocks (quadrant pre-rotation + output register).
//
// AMP = round(AMP_TARGET / CORDIC_GAIN), CORDIC_GAIN ~= 1.6467602 for 16 stages,
// so the rotation path's intrinsic growth lands the envelope at ~AMP_TARGET.
// =============================================================================
module cordic_limiter #(
    parameter IN_WIDTH  = 24,        // matches i_filtered/q_filtered width
    parameter STAGES    = 16,
    parameter signed [17:0] AMP_PRE = 18'sd9949   // 16384 / 1.64676
) (
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire signed [IN_WIDTH-1:0]  i_in,
    input  wire signed [IN_WIDTH-1:0]  q_in,
    output reg  signed [17:0]          i_norm,   // constant-envelope (~±16384)
    output reg  signed [17:0]          q_norm
);

    // Datapath widths
    localparam VW = IN_WIDTH + 3;    // vectoring path (input + gain growth headroom)
    localparam RW = 20;              // rotation path (AMP_PRE ~2^14, small)
    localparam SIGN = VW - 1;

    // Pipeline registers, one set per stage (0 = after quadrant pre-rotation)
    reg signed [VW-1:0] xv [0:STAGES];
    reg signed [VW-1:0] yv [0:STAGES];
    reg signed [RW-1:0] xr [0:STAGES];
    reg signed [RW-1:0] yr [0:STAGES];

    // -------- Stage 0: quadrant pre-rotation into the right half-plane --------
    // Vectoring path applies +/-90 deg when i_in<0; rotation path (AMP_PRE,0)
    // applies the OPPOSITE pre-rotation so its final angle matches the input.
    always @(posedge clk) begin
        if (!rst_n) begin
            xv[0] <= 0; yv[0] <= 0; xr[0] <= 0; yr[0] <= 0;
        end else if (i_in >= 0) begin
            xv[0] <= i_in;  yv[0] <= q_in;          // no pre-rotation
            xr[0] <= AMP_PRE; yr[0] <= 18'sd0;
        end else if (q_in >= 0) begin
            xv[0] <= q_in;  yv[0] <= -i_in;         // vectoring rotate -90
            xr[0] <= 18'sd0; yr[0] <= AMP_PRE;      // rotation  rotate +90
        end else begin
            xv[0] <= -q_in; yv[0] <= i_in;          // vectoring rotate +90
            xr[0] <= 18'sd0; yr[0] <= -AMP_PRE;     // rotation  rotate -90
        end
    end

    // -------- CORDIC iteration stages (shared sigma from vectoring y-sign) -----
    genvar gi;
    generate
        for (gi = 0; gi < STAGES; gi = gi + 1) begin : cordic_stage
            always @(posedge clk) begin
                if (!rst_n) begin
                    xv[gi+1] <= 0; yv[gi+1] <= 0;
                    xr[gi+1] <= 0; yr[gi+1] <= 0;
                end else if (yv[gi][SIGN]) begin
                    // yv < 0 -> sigma = +1 (vectoring); rotation uses -sigma
                    xv[gi+1] <= xv[gi] - (yv[gi] >>> gi);
                    yv[gi+1] <= yv[gi] + (xv[gi] >>> gi);
                    xr[gi+1] <= xr[gi] + (yr[gi] >>> gi);
                    yr[gi+1] <= yr[gi] - (xr[gi] >>> gi);
                end else begin
                    // yv >= 0 -> sigma = -1
                    xv[gi+1] <= xv[gi] + (yv[gi] >>> gi);
                    yv[gi+1] <= yv[gi] - (xv[gi] >>> gi);
                    xr[gi+1] <= xr[gi] - (yr[gi] >>> gi);
                    yr[gi+1] <= yr[gi] + (xr[gi] >>> gi);
                end
            end
        end
    endgenerate

    // -------- Output: rotation path = constant-envelope (I,Q) at input phase ---
    always @(posedge clk) begin
        if (!rst_n) begin
            i_norm <= 0; q_norm <= 0;
        end else begin
            i_norm <= xr[STAGES][17:0];
            q_norm <= yr[STAGES][17:0];
        end
    end

endmodule
