// =============================================================================
// fft_scanner_wrapper.v - 1024-pt opencores FFT adapter (pipelined for timing)
// =============================================================================
module fft_scanner_wrapper (
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [15:0] sample_in,
    input  wire               scan_start,
    output reg                scan_done,
    output reg  [31:0]        freq_word,
    output reg  [9:0]         peak_bin,
    output reg  [31:0]        peak_mag
);

localparam S_IDLE=2'd0, S_WAIT_SYNC=2'd1, S_SCAN=2'd2, S_DONE=2'd3;
reg [1:0] state;
reg [9:0] cnt;
reg       fft_reset;
reg       sync_latched;
reg       sync_skip;   // v3.5: skip 1st FFT frame after reset (RAM still has stale data)

// FFT instance: 16-bit in, 22-bit out (44-bit packed)
wire [31:0] fft_in = {sample_in, 16'd0};
wire [43:0] fft_out;
wire        fft_sync;

fftmain fft_inst (
    .i_clk(clk), .i_reset(fft_reset), .i_ce(1'b1),
    .i_sample(fft_in), .o_result(fft_out), .o_sync(fft_sync)
);

// ---- Magnitude squared (DSP48 inferred) ----
// Pipeline Stage 1: register FFT output
(* DONT_RETIME = "TRUE" *) reg signed [15:0] out_re_r;
(* DONT_RETIME = "TRUE" *) reg signed [15:0] out_im_r;

wire signed [15:0] out_re = $signed(fft_out[43:28]);
wire signed [15:0] out_im = $signed(fft_out[21:6]);

always @(posedge clk) begin
    out_re_r <= out_re;
    out_im_r <= out_im;
end

// Pipeline Stage 2: compute magnitude squared (registered outputs to DSP)
(* DONT_RETIME = "TRUE" *) reg [31:0] mag_sq_r;

always @(posedge clk) begin
    mag_sq_r <= ($signed(out_re_r) * $signed(out_re_r))
              + ($signed(out_im_r) * $signed(out_im_r));
end

// Pipeline Stage 3: peak comparison (registered)
(* DONT_RETIME = "TRUE" *) reg [31:0] best_mag;
(* DONT_RETIME = "TRUE" *) reg [9:0]  best_bin;
(* DONT_RETIME = "TRUE" *) reg [9:0]  cnt_pipe1;
(* DONT_RETIME = "TRUE" *) reg [9:0]  cnt_pipe2;
(* DONT_RETIME = "TRUE" *) reg [1:0]  state_pipe1;
(* DONT_RETIME = "TRUE" *) reg [1:0]  state_pipe2;
(* DONT_RETIME = "TRUE" *) reg       fft_sync_r;

// Pipeline alignment: delay cnt and state to match mag_sq pipeline (2 cycles)
always @(posedge clk) begin
    fft_sync_r  <= fft_sync;
    cnt_pipe1   <= cnt;
    cnt_pipe2   <= cnt_pipe1;
    state_pipe1 <= state;
    state_pipe2 <= state_pipe1;
end

// Peak detection with pipelined magnitude
always @(posedge clk) begin
    if (!rst_n) begin
        best_mag <= 32'd0;
        best_bin <= 10'd0;
    end else if (state_pipe2 == S_SCAN) begin
        if (cnt_pipe2 > 10'd0 && cnt_pipe2 <= 10'd511) begin
            if (mag_sq_r > best_mag) begin
                best_mag <= mag_sq_r;
                best_bin <= cnt_pipe2;
            end
        end
    end else if (state == S_IDLE) begin
        best_mag <= 32'd0;
        best_bin <= 10'd0;
    end
end

// ---- Top-level FSM ----
always @(posedge clk) begin
    if (!rst_n) begin
        state<=S_IDLE; scan_done<=0; freq_word<=0; peak_bin<=0; peak_mag<=0;
        cnt<=0; fft_reset<=1; sync_latched<=0; sync_skip<=1;
    end else begin
        case (state)
            S_IDLE: begin
                fft_reset<=1; scan_done<=0; sync_latched<=0; sync_skip<=1;
                if (scan_start) begin
                    fft_reset<=0; cnt<=0;
                    state<=S_WAIT_SYNC;
                end
            end
            S_WAIT_SYNC: begin
                // v3.5: The pipelined FFT stage RAMs (imem/omem) are NOT zeroed
                // at reset.  The first o_sync pulse after reset therefore marks a
                // frame that mixes new samples with stale-RAM data, producing a
                // corrupted result — this is the root cause of both the "need 2nd
                // RST" and "watchdog retry cannot re-acquire" bugs.  Skip the
                // first frame, use the second (which the first already primed
                // with fresh data).  fft_reset stays 0 across both frames.
                if (fft_sync && !sync_latched) begin
                    if (sync_skip) begin
                        sync_skip <= 1'b0;    // ignore 1st frame, wait for 2nd
                    end else begin
                        sync_latched<=1; cnt<=0; state<=S_SCAN;
                    end
                end
            end
            S_SCAN: begin
                if (cnt==10'd1023) state<=S_DONE; else cnt<=cnt+1;
            end
            S_DONE: begin
                freq_word<={best_bin,22'd0};
                peak_bin<=best_bin; peak_mag<=best_mag; scan_done<=1;
                if (!scan_start) begin state<=S_IDLE; scan_done<=0; end
            end
            default: state<=S_IDLE;
        endcase
    end
end

endmodule
