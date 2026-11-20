// core_beacon.sv - a heartbeat for debugging a core that does not come up.
//
// A dead build (no video sync, Main_MiSTer spinning in findPLLpar) says nothing; this
// module lives on clk_sys (the 50 MHz input, no PLL) and prints one line every WIN clocks
// on a UART line (115200 8N1) that the HPS reads as /dev/ttyS1:
//
//   S<ff> <bus> <mem> <vid> <vs> <cpu> <seq>\r\n        (all hex)
//
//   ff    flags, sampled levels: [7] machine async reset (PLL not locked), [6] machine reset,
//         [5] SDRAM init done, [4:0] spare inputs of the top
//   bus   edges of a divided clk_bus bit seen in the window (28 MHz / 2048 * 2 per second)
//   mem   the same for the SDRAM clock, vid for clk_vid, vs the edges of VGA_VS,
//   cpu   the edges of a bit of the CPU T-state counter
//   seq   8-bit line counter (shows that clk_sys and this module are alive)
//
// A domain whose clock is dead shows 0000. The toggles come from free-running counters in
// their own domains (nothing here is reset by them).
`default_nettype none

module core_beacon #(
    parameter integer CLKS_PER_BIT = 434,
    parameter integer WIN          = 6_400_000     // 128 ms at 50 MHz
) (
    input  wire       clk,
    input  wire [7:0] flags,
    input  wire       t_bus, t_mem, t_vid, t_vs, t_cpu,
    output reg        tx = 1'b1
);
    reg [2:0] sb = 3'd0, sm = 3'd0, sv = 3'd0, ss = 3'd0, sc = 3'd0;
    reg [7:0] fl_s1 = 8'd0, fl_s2 = 8'd0;
    always @(posedge clk) begin
        sb <= {sb[1:0], t_bus}; sm <= {sm[1:0], t_mem}; sv <= {sv[1:0], t_vid};
        ss <= {ss[1:0], t_vs};  sc <= {sc[1:0], t_cpu};
        fl_s1 <= flags; fl_s2 <= fl_s1;
    end
    reg [15:0] cb = 16'd0, cm = 16'd0, cv = 16'd0, cs = 16'd0, cc = 16'd0;
    reg [15:0] nb = 16'd0, nm = 16'd0, nv = 16'd0, ns = 16'd0, nc = 16'd0;
    reg  [7:0] seq = 8'd0, nf = 8'd0, nseq = 8'd0;
    reg [22:0] win = 23'd0;
    reg        go = 1'b0;

    always @(posedge clk) begin
        go  <= 1'b0;
        win <= win + 23'd1;
        if (sb[2] != sb[1]) cb <= cb + 16'd1;
        if (sm[2] != sm[1]) cm <= cm + 16'd1;
        if (sv[2] != sv[1]) cv <= cv + 16'd1;
        if (ss[2] != ss[1]) cs <= cs + 16'd1;
        if (sc[2] != sc[1]) cc <= cc + 16'd1;
        if (win == WIN - 1) begin
            win <= 23'd0;
            nb <= cb; nm <= cm; nv <= cv; ns <= cs; nc <= cc; nf <= fl_s2; nseq <= seq;
            seq <= seq + 8'd1;
            cb <= 16'd0; cm <= 16'd0; cv <= 16'd0; cs <= 16'd0; cc <= 16'd0;
            go <= 1'b1;
        end
    end

    function [7:0] h(input [3:0] n);
        h = (n < 4'd10) ? (8'd48 + n) : (8'd55 + n);
    endfunction

    wire [263:0] line = {
        8'h53, h(nf[7:4]), h(nf[3:0]), 8'h20,
        h(nb[15:12]), h(nb[11:8]), h(nb[7:4]), h(nb[3:0]), 8'h20,
        h(nm[15:12]), h(nm[11:8]), h(nm[7:4]), h(nm[3:0]), 8'h20,
        h(nv[15:12]), h(nv[11:8]), h(nv[7:4]), h(nv[3:0]), 8'h20,
        h(ns[15:12]), h(ns[11:8]), h(ns[7:4]), h(ns[3:0]), 8'h20,
        h(nc[15:12]), h(nc[11:8]), h(nc[7:4]), h(nc[3:0]), 8'h20,
        h(nseq[7:4]), h(nseq[3:0]), 8'h0D, 8'h0A };            // 33 characters

    reg [263:0] buf_r = 264'd0;
    reg   [5:0] idx = 6'd33;            // characters sent; 33 = idle
    reg   [3:0] bit_i = 4'd0;
    reg   [8:0] bc = 9'd0;
    reg   [9:0] sh = 10'h3FF;
    reg         busy = 1'b0;

    always @(posedge clk) begin
        if (go) begin buf_r <= line; idx <= 6'd0; busy <= 1'b0; end
        else if (!busy && idx != 6'd33) begin
            sh    <= {1'b1, buf_r[263 -: 8], 1'b0};     // stop, data (MSB first in the word), start
            busy  <= 1'b1;
            bit_i <= 4'd0;
            bc    <= 9'd0;
            buf_r <= {buf_r[255:0], 8'd0};
            idx   <= idx + 6'd1;
        end
        else if (busy) begin
            if (bc == CLKS_PER_BIT - 1) begin
                bc <= 9'd0;
                tx <= sh[0];
                sh <= {1'b1, sh[9:1]};
                bit_i <= bit_i + 4'd1;
                if (bit_i == 4'd9) busy <= 1'b0;
            end
            else bc <= bc + 9'd1;
        end
    end
endmodule
