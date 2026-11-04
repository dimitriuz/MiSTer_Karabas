// vblank_gen.sv - the vertical blanking window of the Profi RGB output.
//
// profi has no VBlank output: it runs the video chain with a gated clock and
// only signals blanking per pixel (RGB_BLANK). MiSTer's video_mixer wants a
// frame-level VBlank, so this counts the lines of every frame (one count per
// rising RGB_HS, restarted on rising RGB_VS) and records the first and last
// line of the frame that had any ce clock with blank = 0.
//
// vblank then says: the current line is outside the window recorded by the
// previous frame (0 for the whole first frame, before any window exists).
// One frame of latency is inherent to that: video_mode.vhd derives a line's
// blanking from counters whose visible line follows one line behind, so at
// a mode switch the new frame's window first appears on the frame after
// it. That shift is not a mode-change edge (the switch itself lands in the
// vblank region between frames) and costs only one frame of accuracy.
//
// clk      the clock it runs on (clk_sdr at the top, the video clock)
// ce       one strobe per popped pixel word (the video CDC's ce_out at the
//          top; ADC_CLK = ENA_RGB on a clk_bus-side use)
// hs, vs   RGB_HS, RGB_VS as profi drives them (the polarity only fixes the
//          frame/line reference: both edges count from the same signals)
// blank    RGB_BLANK
`default_nettype none

module vblank_gen (
    input  wire clk,
    input  wire ce,
    input  wire hs,
    input  wire vs,
    input  wire blank,
    output reg  vblank = 1'b0
);

reg [9:0] line = 10'd0;        // lines since the last vs rising (hs rising: +1)
reg [9:0] first = 10'd0;       // window of the previous frame
reg [9:0] last  = 10'd0;
reg       seen  = 1'b0;        // window valid? (set at the frame after the first)
reg [9:0] nxt_first = 10'd0;   // window being recorded from the current frame
reg [9:0] nxt_last  = 10'd0;
reg       nxt_seen  = 1'b0;
reg       vs_d = 1'b0, hs_d = 1'b0;

wire vs_rise = vs && !vs_d;
wire hs_rise = hs && !hs_d;
wire [9:0] line_n = vs_rise ? 10'd0 : line + {9'd0, hs_rise};

always @(posedge clk) begin
    vs_d <= vs;
    hs_d <= hs;
    if (vs_rise) begin
        // commit the window of the frame that just ended; vblank for the new
        // line 0 is computed from it right away, not from the old registers
        line      <= 10'd0;
        first     <= nxt_first;
        last      <= nxt_last;
        seen      <= nxt_seen;
        nxt_first <= 10'd0;
        nxt_last  <= 10'd0;
        nxt_seen  <= 1'b0;
        vblank    <= nxt_seen && (line_n < nxt_first || line_n > nxt_last);
    end else begin
        if (hs_rise)
            line <= line_n;
        if (ce && !blank) begin
            if (!nxt_seen) begin
                nxt_seen  <= 1'b1;
                nxt_first <= line_n;
            end
            nxt_last <= line_n;
        end
        vblank <= seen && (line_n < first || line_n > last);
    end
end

endmodule

`default_nettype wire
