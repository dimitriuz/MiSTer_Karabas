// vframe_gen.sv - VBlank and VS rebuilt from the blank run of the pixel
// stream (MiSTer video_mixer inputs).
//
// Why: the machine's own VSYNC can lie outside its vertical blank. In
// upstream pentagon_video.vhd with MODE60 = '1' the 60 Hz VSYNC is driven at
// chr_row 27 (line 122: `ver_cnt /= 27 and MODE60 = '1'`), while the Spectrum
// blank covers ver_cnt(5 downto 1) = 14, rows 28-29 (lines 209-210) - the
// VSYNC falls inside the visible picture. MiSTer's video_mixer and the HDMI
// scaler need VSync inside the vertical blank (at 50 Hz the VSYNC at row 31
// is inside the rows 30-31 blank, which is why 50 Hz works). So the locked
// output does not use the machine VSYNC at all: this module finds the run of
// fully blank lines in the stream and generates both signals from it, for
// every mode. While it is still unlocked (core start, and after every mode,
// VSync or DS80 switch until two matching frames lock it again) it passes
// the machine VSYNC through instead, so the scaler always has a sync.
//
// Algorithm (all state changes on posedge clk with ce = 1; the inputs change
// only with ce):
//  - Line boundary: hs_n falling edge (compared at the ce clocks). HSYNC sits
//    inside the horizontal blank in both machine video generators, so the
//    previous line was fully output in blanking and the boundary is always
//    reached with blank = 1.
//  - seen marks a line as visible if any ce clock of it had blank = 0
//    (including the boundary clock itself); cleared at every boundary.
//  - run counts the consecutive non-visible lines that ended most recently
//    (saturating at 1023); a visible line ending resets it.
//  - Anchor: a boundary where the line that just ended was visible and the
//    run before it was >= MIN_RUN. That line is frame line 0.
//  - ln is the frame line number of the line in progress, reset to 1 for the
//    line after every anchor and wrapping at the stored total (before the
//    first measurement, where no total is known, it saturates at 1023).
//  - At an anchor the frame that just completed is measured from the previous
//    anchor's line 0: m_total is its line count, m_vis = m_total - run the
//    frame line number of the first line of the blank run that ended at this
//    anchor. The first anchor after reset only starts the counting.
//  - Lock: at a measuring anchor with m_total == total, m_vis == vis and the
//    anchor line at frame number 0 under the stored count, the module locks
//    (two identical frames lock it). Any other anchor unlocks, stores the new
//    measurement and re-anchors ln. A visible pixel seen while vblank = 1 is
//    a stale geometry seen live: it unlocks as well, until the next anchor
//    measures and two matching frames lock again.
//  - Locked outputs are registered at boundaries and constant over a line:
//    vblank covers the frame lines vis..total-1 (the whole blank run: by
//    construction the run ends the frame, frame line 0 is its first visible
//    line), vs covers VS_OFF..VS_OFF+VS_LEN-1 lines inside it.
//  - Unlocked outputs fall back to the machine sync: vblank = 0 and vs is the
//    machine VSYNC (vs_n inverted, registered on every ce clock), so the
//    scaler still sees a sync while the module waits for two matching frames.
//  - The outputs for the line starting at a boundary are driven by the lock
//    decision made on that boundary, not by the old locked value: an unlock
//    raised there (a non-matching anchor, or a visible pixel on the boundary
//    clock) already gives that line the unlocked outputs. An unlock raised
//    mid-line (a visible pixel inside an asserted vblank) takes effect on
//    that ce clock's next ce clock: vblank drops and vs switches to the
//    machine VS at once, without waiting for the next boundary.
`default_nettype none

module vframe_gen #(
    parameter int MIN_RUN = 6,   // fully blank lines that make a vertical blank
    parameter int VS_OFF  = 1,   // VS starts this many lines into the blank run
    parameter int VS_LEN  = 3    // VS length in lines
) (
    input  wire clk,             // clk_sdr (112.5 MHz)
    input  wire ce,              // pixel strobe (vid_ce); inputs change only with ce
    input  wire hs_n,            // machine HSYNC as popped from the FIFO, active low (vid_r[2])
    input  wire blank,           // 1 = blanking, normalised (vid_r[0])
    input  wire vs_n,            // machine VSYNC as popped from the FIFO, active low (vid_r[1])
    output reg  vblank = 1'b0,
    output reg  vs     = 1'b0    // active high
);

reg        hs_n_d = 1'b0;     // hs_n at the previous ce clock
reg        seen   = 1'b0;     // the line in progress had a visible pixel
reg [9:0]  run    = 10'd0;    // consecutive non-visible lines ended
reg [9:0]  c      = 10'd0;    // boundaries since the previous anchor
reg [9:0]  ln     = 10'd0;    // frame line number of the line in progress
reg        have_anchor = 1'b0;
reg [9:0]  total  = 10'd0;    // measured frame geometry
reg [9:0]  vis    = 10'd0;    // (0 = nothing measured yet)
reg        locked = 1'b0;

wire boundary     = ce && !hs_n && hs_n_d;
wire line_visible = seen || !blank;     // blank = 0 also on the boundary clock
wire anchor       = line_visible && (run >= MIN_RUN[9:0]);

wire [10:0] m_total = {1'b0, c} + 11'd1;        // lines anchor..anchor
wire [10:0] m_vis   = m_total - {1'b0, run};    // >= 1: the anchor line is visible
wire match  = (c != 1023) && (m_total[9:0] == total) && (m_vis[9:0] == vis)
              && (ln == 10'd0);
// ln advances under the stored total (so an anchor lands on frame number 0
// after one measured frame); before the first measurement it saturates.
wire [9:0] ln_next = (total != 10'd0 && ln + 10'd1 == total) ? 10'd0
                 : (total == 10'd0 && ln == 10'd1023)       ? 10'd1023
                 : ln + 10'd1;
// next-boundary values of the output factors
// A visible pixel inside an asserted vblank is a stale geometry seen live: it
// unlocks, and no lock decision taken on this same boundary may hide it.
wire        unlock_live = vblank && !blank;
wire        anchor_lock = anchor && have_anchor && match;
wire        locked_n    = unlock_live ? 1'b0 : (anchor ? anchor_lock : locked);
wire [9:0]  ln_o        = anchor ? 10'd1 : ln_next;
wire [9:0]  vis_o       = (anchor && !match && c != 1023) ? m_vis[9:0] : vis;

always @(posedge clk) begin
    if (ce) begin
        hs_n_d <= hs_n;
        if (boundary) begin
            seen <= 1'b0;
            run  <= line_visible ? 10'd0
                 : (run == 10'd1023) ? run : run + 10'd1;
            if (anchor) begin
                if (have_anchor && !match && c != 10'd1023) begin
                    total <= m_total[9:0];
                    vis   <= m_vis[9:0];
                end
                have_anchor <= 1'b1;
                ln <= 10'd1;               // the line in progress was line 0
                c  <= 10'd0;
            end else begin
                ln <= ln_next;
                c  <= (c == 10'd1023) ? c : c + 10'd1;
            end
            // the line starting at this boundary is driven by this boundary's
            // decision, so an unlock here takes effect on that line at once
            locked <= locked_n;
            if (locked_n) begin
                vblank <= (ln_o >= vis_o);
                vs     <= ({1'b0, ln_o} >= {1'b0, vis_o} + VS_OFF)
                          && ({1'b0, ln_o} <  {1'b0, vis_o} + (VS_OFF + VS_LEN));
            end else begin                 // unlocked: the machine sync
                vblank <= 1'b0;
                vs     <= ~vs_n;
            end
        end else begin
            if (!blank)
                seen <= 1'b1;
            if (unlock_live || !locked) begin
                locked <= 1'b0;            // an unlock drops the outputs on the
                vblank <= 1'b0;            // next ce clock, mid-line or not
                vs     <= ~vs_n;
            end
        end
    end
end

endmodule

`default_nettype wire
