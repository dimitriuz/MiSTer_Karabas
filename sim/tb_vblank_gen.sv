// tb_vblank_gen.sv - testbench for rtl/video/vblank_gen.sv.
//
// A synthetic 312-line frame: 448 clk clocks per line, ce every 4th clock,
// blank outside lines 48-287 and outside line clocks 64-383. From the second
// frame on, vblank must be 1 exactly on lines 0-47 and 288-311 (the window
// recorded by the previous frame), and 0 everywhere; during the first frame
// it must be 0 on every line. Then the frame switches to 320 lines with the
// active window 40-279: the switch is tracked one frame later.
//
// The stimulus runs on the negedge of clk with blocking assignments; the DUT
// samples on the posedge. The watchdog counts clock edges (no $time
// arithmetic: iverilog's time comparisons are not trustworthy past a few ms).
`timescale 1ns / 1ps
`default_nettype none

module tb_vblank_gen;

localparam integer CPL = 448;   // clk clocks per line

reg clk = 1'b0;
always #5 clk = ~clk;

reg ce = 1'b0, hs = 1'b0, vs = 1'b0, blank = 1'b1;
wire vblank;

vblank_gen dut (
    .clk(clk), .ce(ce), .hs(hs), .vs(vs), .blank(blank), .vblank(vblank)
);

integer errors = 0;
integer frame_no = 0;
// expected vblank window for the frame being stimulated (its source is the
// previous frame): exp_first < 0 means "the first frame: vblank 0 always".
integer exp_first = -1, exp_last = -1;

// one frame: len lines, ce clocks with blank = 0 on lines fa..la only.
task automatic frame(input integer len, input integer fa, input integer la);
    integer l, c;
    begin
        frame_no = frame_no + 1;
        for (l = 0; l < len; l = l + 1) begin
            for (c = 0; c < CPL; c = c + 1) begin
                @(negedge clk);
                hs    = (c < 48);                              // rising at line start
                vs    = (l == 0 && c < 160);                   // rising at frame start
                ce    = (c % 4 == 0);
                blank = !((l >= fa && l <= la) && (c >= 64 && c < 384));
                if (c == 200) begin  // mid-line: the DUT is settled on this line
                    if (vblank !== 1'b1 && vblank !== 1'b0) begin
                        errors = errors + 1;
                        $display("frame %0d line %0d: vblank is %b (not 0/1)", frame_no, l, vblank);
                    end else if (exp_first < 0 && vblank !== 1'b0) begin
                        errors = errors + 1;
                        $display("frame %0d line %0d: vblank is 1 during the first frame", frame_no, l);
                    end else if (exp_first >= 0 &&
                                 vblank !== ((l < exp_first || l > exp_last) ? 1'b1 : 1'b0)) begin
                        errors = errors + 1;
                        $display("frame %0d line %0d: vblank %b, window %0d..%0d expected %b",
                                 frame_no, l, vblank, exp_first, exp_last,
                                 ((l < exp_first || l > exp_last) ? 1'b1 : 1'b0));
                    end
                end
            end
        end
    end
endtask

// watchdog: 1616 lines + slack, in clock edges
initial begin : watchdog
    repeat (1700 * CPL) @(negedge clk);
    $display("tb_vblank_gen: FAIL watchdog after 1700 lines (errors so far %0d)", errors);
    $finish;
end
initial begin
    frame(312, 48, 287);                      // first frame: vblank 0 all frame
    exp_first = 48; exp_last = 287;           // the window the frame above records
    frame(312, 48, 287);
    frame(312, 48, 287);
    frame(320, 40, 279);                      // switch tracked one frame late
    exp_first = 40; exp_last = 279;
    frame(320, 40, 279);
    if (errors == 0)
        $display("tb_vblank_gen: PASS");
    else
        $display("tb_vblank_gen: FAIL %0d vblank mismatches", errors);
    $finish;
end

endmodule

`default_nettype wire
