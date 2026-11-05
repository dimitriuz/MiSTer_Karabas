// tb_vframe_gen.sv - testbench for rtl/video/vframe_gen.sv.
//
// There is no "frame start" in the stream: the DUT must find its own anchor.
// A generator drives a continuous line stream: clk any period, ce every 4th
// clock, 448 ce pixels per line, blank = 1 on pixels 376..447 (horizontal
// blank), hs_n = 0 on pixels 392..423, blank = 1 on the whole line for the
// lines of a segment's blank run. The stream is a sequence of segments, each
// with a frame period P lines, a blank-run start B and length L (the lines
// B..B+L-1 of every period are fully blank), drawn for a number of periods
// before the next segment takes over at a line boundary, without reset in
// between:
//   1. P=320 B=304 L=16, 6 periods (Pentagon 50 Hz shape)
//   2. P=264 B=248 L=16, 6 periods (Pentagon 60 Hz shape)
//   3. P=272 B=0   L=32, 6 periods (blank run at the period start)
//   4. P=320 B=304 L=16, 40 periods (the 50 Hz shape again; 40 so that even
//      a lock lost 30 periods back is re-acquired before the run ends)
//
// Checks on every line of every segment from its fourth period on (the first
// three periods of a segment are lock time; during them only the "vs never on
// a visible pixel" rule is checked, and that one on every period):
//  - vblank and vs are constant over a line (sampled on every ce clock and
//    compared with the value at the line's first pixel after the boundary);
//  - vblank = 1 exactly on the L blank-run lines,
//  - vs = 1 exactly on blank-run lines B+1 .. B+3,
//  - no ce clock with blank = 0 while vblank = 1,
//  - no ce clock with vs = 1 and blank = 0 (the VS sits inside the blank).
//
// The DUT aligns its lines to the falling hs_n and may change its outputs
// there, so a DUT line is the pixel run from pixel 392 of one period line to
// pixel 391 of the next. Its outputs describe the period line whose active
// pixels they contain: pixels 0..391 of a period line belong to the DUT line
// of that period line, pixels 392..447 already to the next one (the pixels
// of the previous period line inside a DUT line lie in its horizontal blank,
// which is why the alignment is still exact). The line checks therefore run
// at pixel 200, unambiguously owned by one period line; the "constant over
// the line" anchor is taken at pixel 392, where the outputs may change.
//
// The stimulus runs on the negedge of clk with blocking assignments; the DUT
// samples on the posedge. The watchdog counts clock edges (no $time
// arithmetic: iverilog's time comparisons are not trustworthy past a few ms).
`timescale 1ns / 1ps
`default_nettype none

module tb_vframe_gen;

localparam integer CPL = 448;    // clk clocks per line
localparam integer HV0 = 376;    // first horizontal blank pixel
localparam integer HS0 = 392;    // hs_n falls (the DUT's line boundary)
localparam integer HS1 = 423;    // hs_n rises

reg clk = 1'b0;
always #5 clk = ~clk;            // 10 ns period, ce every 4th clock

reg ce    = 1'b0;
reg hs_n  = 1'b1;
reg blank = 1'b1;
wire vblank;
wire vs;

vframe_gen dut (
    .clk(clk), .ce(ce), .hs_n(hs_n), .blank(blank),
    .vblank(vblank), .vs(vs)
);

integer errors = 0;

task automatic err(input [8*40:1] what);
    begin
        if (errors < 10)
            $display("tb_vframe_gen: error seg %0d period %0d line %0d: %0s (vblank %b vs %b blank %b hs_n %b)",
                     segno, g_pno, g_line % gP, what, vblank, vs, blank, hs_n);
        errors = errors + 1;
    end
endtask

// ---------------------------------------------------------------- generator
integer segno  = 0;              // current segment (1..4)
integer g_pno  = 0;              // current period within the segment
integer g_line = 0;              // period line being drawn
integer gp     = 0;              // pixel of that line being driven
integer gP = 320, gB = 304, gL = 16;   // current segment geometry
reg done = 1'b0;

task automatic draw_line(input is_blank_line);
    begin
        for (gp = 0; gp < CPL; gp = gp + 1) begin
            @(negedge clk);
            ce     = 1'b1;
            hs_n   = (gp >= HS0 && gp < HS1 + 1) ? 1'b0 : 1'b1;
            blank  = (gp >= HV0 || is_blank_line) ? 1'b1 : 1'b0;
            @(negedge clk);
            ce     = 1'b0;
        end
    end
endtask

task automatic run_seg(input integer seg, P, B, L, nper);
    integer per;
    begin
        segno = seg;
        gP = P; gB = B; gL = L;
        g_pno = 0;
        for (per = 0; per < nper; per = per + 1) begin
            for (g_line = 0; g_line < P; g_line = g_line + 1)
                draw_line(B <= g_line && g_line < B + L);
            g_pno = g_pno + 1;
        end
    end
endtask

initial begin : genproc
    run_seg(1, 320, 304, 16, 6);
    run_seg(2, 264, 248, 16, 6);
    run_seg(3, 272,   0, 32, 6);
    run_seg(4, 320, 304, 16, 40);
    done = 1'b1;
end

initial begin : watchdog               // 17936 lines of stimulus + slack
    repeat (36000 * CPL) @(negedge clk);
    $display("tb_vframe_gen: error watchdog after 36000 lines (%0d errors so far)", errors);
    $display("tb_vframe_gen: FAIL watchdog");
    $fatal(1);
end

// ------------------------------------------------------------------ checks
reg  x_vb, x_vs;                       // outputs at the previous ce clock
reg  have_x = 1'b0;
reg  p4ok   = 1'b0;                    // the line in progress is checked
reg  exp_vb, exp_vs;

initial forever begin
    @(posedge clk); #1;                 // just after the posedge that
    if (ce === 1'b1) begin              // sampled this pixel's ce = 1
        if (vs === 1'b1 && blank === 1'b0)          // every period
            err("vs on a non-blank pixel");
        if (gp == 0 || gp == HS0)                   // the pixel run owned by
            p4ok = (g_pno >= 3);                    // a period line is checked
        if (gp == HS0) begin                        // first pixel of a DUT
            x_vb = vblank;                          // outputs describe the
            x_vs = vs;                              // next period line
            have_x = 1'b1;
        end else begin
            if (have_x && (vblank !== x_vb || vs !== x_vs))
                err("vblank/vs not constant over the line");
            // pixel 200 is on the period line that owns the DUT line, the
            // boundary pixel 392 on the next one already: check there, where
            // the line is unambiguous
            if (p4ok && gp == 200) begin
                exp_vb = ((g_line % gP) >= gB) && ((g_line % gP) < gB + gL);
                exp_vs = ((g_line % gP) >  gB) && ((g_line % gP) < gB + 4);
                if (x_vb !== 1'bx && x_vs !== 1'bx && vblank !== exp_vb)
                    err("vblank wrong for the blank run");
                if (x_vb !== 1'bx && x_vs !== 1'bx && vs !== exp_vs)
                    err("vs wrong (expected on lines B+1..B+3)");
            end
        end
        if (p4ok && vblank === 1'b1 && blank === 1'b0)
            err("vblank on a non-blank pixel");
    end
end

initial begin
    wait (done === 1'b1);
    if (errors == 0)
        $display("tb_vframe_gen: PASS");
    else
        $display("tb_vframe_gen: FAIL %0d errors", errors);
    $finish;
end

endmodule

`default_nettype wire
