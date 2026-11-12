// Testbench for rtl/mem/ddr_arb.sv, the DDR3 arbiter with two masters: the
// General Sound memory (gs_mem, priority) and the floppy drive store
// (fdd_store, stage 4c). The DDR side is sim/models/ddram_model.sv with
// FAIL_TAG = "tb_ddr_arb": its two accepted regions are the GS map (word
// 0x0600_0000 + line, index = addr[17:0]) and the FDD map (0x0700_0000 + line,
// index = 262144 + addr[18:0]).
//
// Both masters follow the gs_mem protocol: address, data, byte enable and the
// request are set up on one clock edge, the strobes and req are raised on the
// next, and everything is held until the transaction is served - a write until
// the accept edge (busy low), a read until its line arrives - and dropped on
// that very edge (a request left high one clock too long would earn a grant
// with no transaction behind it). Every wait is bounded by an edge count,
// never by a $time difference.
//
// Cases (each prints `<case>: ok` or `FAIL <case> ...`):
//   gs_only             1024 full-line writes and reads of the GS region with
//                       the model's latency varying, 512 partial writes with
//                       rotating byte enables, the read-back of all of it and
//                       the top lines of the region: every read equals the
//                       reference. The FDD is never granted.
//   fdd_only            the same over the FDD region, including line pairs
//                       that differ only in addr[18] (the region marker), so a
//                       truncated index would collide, and the last line the
//                       model has.
//   gs_priority         the FDD streams back-to-back reads with no idle clock
//                       between them (req high through the whole stream) while
//                       GS issues one read per 200 clocks: every GS read
//                       completes within one FDD transaction plus its own
//                       latency, at most one FDD read completes while a GS read
//                       waits, and all data is correct. Then the same with the
//                       DDR forced busy for 3..11 clocks at a time.
//   alternating_writes  both masters write and read their own lines at the same
//                       time, at the same line numbers and with the byte
//                       enables of their own choice; afterwards all of it is
//                       read back: each region holds what its own master wrote.
//   reset_idle          reset with a read in flight: both strobes go to 0, both
//                       masters see busy = 1 and neither is handed the
//                       abandoned line, and after the reset both masters
//                       complete a write and a read.
//
// The monitor checks on every clock: ddr_burstcnt is 1, never both masters get
// dout_ready, the bus only carries a request when a master is asking, and what
// the bus carries is the request of the master that is not busy.
//
// The last line printed is `tb_ddr_arb: PASS` or `tb_ddr_arb: FAIL <reason>`;
// run via sim/run_tb_ddr_arb.sh (iverilog -g2012).
`timescale 1ns / 1ps

module tb_ddr_arb;

    // ---------------- clock ----------------
    reg clk = 1'b0;
    always #17.7775 clk = ~clk;              // 28.125 MHz gs_clk

    // the two regions, as the masters form their addresses
    localparam [28:0] GS_BASE  = 29'h0600_0000;   // byte 0x3000_0000, gs_mem
    localparam [28:0] FDD_BASE = 29'h0700_0000;   // byte 0x3800_0000, fdd_store

    localparam [63:0] SALT_GS  = 64'h1111_EEEE_2222_3333;
    localparam [63:0] SALT_FDD = 64'h4444_5555_6666_7777;

    // edge-count budgets
    localparam integer BUSY_BUDGET = 4000;   // clocks a request may wait
    localparam integer GS_WAIT_BUDGET = 30;  // a GS read with the model at LAT 6
    localparam integer GS_STREAM_K = 40;     // GS reads of the priority stream
    localparam integer GS_PERIOD   = 200;    // clocks between two of them

    // the arbiter's IDLE, which it must be back in after a reset
    localparam [1:0] ST_IDLE = 2'd0;

    // ---------------- DUT ----------------
    reg         reset = 1'b1;

    reg         g_req  = 1'b0;
    reg  [28:0] g_addr = 29'd0;
    reg  [63:0] g_din  = 64'd0;
    reg   [7:0] g_be   = 8'd0;
    reg         g_rd   = 1'b0;
    reg         g_we   = 1'b0;
    wire        g_busy;
    wire [63:0] g_dout;
    wire        g_dout_ready;

    reg         f_req  = 1'b0;
    reg  [28:0] f_addr = 29'd0;
    reg  [63:0] f_din  = 64'd0;
    reg   [7:0] f_be   = 8'd0;
    reg         f_rd   = 1'b0;
    reg         f_we   = 1'b0;
    wire        f_busy;
    wire [63:0] f_dout;
    wire        f_dout_ready;

    wire        ddr_rd, ddr_we;
    wire [28:0] ddr_addr;
    wire [63:0] ddr_din;
    wire  [7:0] ddr_be;
    wire  [7:0] ddr_burstcnt;
    reg         force_busy = 1'b0;
    wire        ddr_busy;
    wire [63:0] ddr_dout;
    wire        ddr_dout_ready;

    ddr_arb dut (
        .clk(clk),
        .reset(reset),
        .g_req(g_req), .g_addr(g_addr), .g_din(g_din), .g_be(g_be),
        .g_rd(g_rd), .g_we(g_we),
        .g_busy(g_busy), .g_dout(g_dout), .g_dout_ready(g_dout_ready),
        .f_req(f_req), .f_addr(f_addr), .f_din(f_din), .f_be(f_be),
        .f_rd(f_rd), .f_we(f_we),
        .f_busy(f_busy), .f_dout(f_dout), .f_dout_ready(f_dout_ready),
        .ddr_rd(ddr_rd), .ddr_we(ddr_we),
        .ddr_addr(ddr_addr), .ddr_din(ddr_din), .ddr_be(ddr_be),
        .ddr_burstcnt(ddr_burstcnt),
        .ddr_busy(ddr_busy), .ddr_dout(ddr_dout),
        .ddr_dout_ready(ddr_dout_ready)
    );

    ddram_model #(
        .LAT(4),
        .BUSY_PCT(0),
        .FAIL_TAG("tb_ddr_arb")
    ) model (
        .clk(clk),
        .force_busy(force_busy),
        .burstcnt(ddr_burstcnt),
        .addr(ddr_addr),
        .rd(ddr_rd),
        .din(ddr_din),
        .be(ddr_be),
        .we(ddr_we),
        .dout(ddr_dout),
        .dout_ready(ddr_dout_ready),
        .busy(ddr_busy)
    );

    // ---------------- reference ----------------
    // lines 0..NREF-1 of each region are tracked; a write updates the
    // reference with the byte enables the master used.
    localparam integer NREF = 1024;
    reg [63:0] ref_g [0:NREF-1];
    reg [63:0] ref_f [0:NREF-1];

    // the top of each region, tracked on its own: for the FDD these include
    // the pairs x and x + 2^18, which differ only in addr[18] (the region
    // marker), so a truncated index would alias them
    localparam integer NHIGH = 8;
    integer    hline   [0:NHIGH-1];
    integer    hline_f [0:NHIGH-1];
    reg [63:0] hval    [0:NHIGH-1];

    integer errors = 0;
    integer shown  = 0;        // failures printed for the current case (cap 8)
    integer case_errors;
    integer i, n;
    reg [31:0] rnd_g, rnd_f;

    // FDD read completions, counted the way the masters see them
    integer f_done_cnt = 0;
    always @(posedge clk)
        if (f_dout_ready === 1'b1)
            f_done_cnt = f_done_cnt + 1;

    // the message fields are the message's own length: an over-long string is
    // right-justified into them, i.e. its head disappears
    task automatic bad(input [8*64-1:0] what);
        begin
            if (shown < 8)
                $display("FAIL %0s", what);
            else if (shown == 8)
                $display("FAIL more failures follow (not printed)");
            shown  = shown + 1;
            errors = errors + 1;
        end
    endtask

    // a stuck transaction: report and end the run (the run script greps the
    // verdict, so nothing after this matters)
    task automatic tfail(input [8*64-1:0] what);
        begin
            $display("tb_ddr_arb: FAIL %0s", what);
            $finish;
        end
    endtask

    task automatic fail64(input [8*40-1:0] name, input [28:0] addr,
                          input [63:0] got, input [63:0] want);
        begin
            if (shown < 8)
                $display("FAIL %0s addr %07h got %016h want %016h",
                         name, addr, got, want);
            else if (shown == 8)
                $display("FAIL %0s more failures follow (not printed)", name);
            shown  = shown + 1;
            errors = errors + 1;
        end
    endtask

    function automatic [63:0] be_mask(input [7:0] be);
        integer k;
        reg [63:0] m;
        begin
            m = 64'd0;
            for (k = 0; k < 8; k = k + 1)
                if (be[k]) m[k*8 +: 8] = 8'hFF;
            be_mask = m;
        end
    endfunction

    // a distinct value per k: k times an odd constant is bijective, the fold
    // is invertible, the salt separates the two regions
    function automatic [63:0] pat(input integer k, input [63:0] salt);
        reg [63:0] x;
        begin
            x   = k * 64'h9E37_79B9_7F4A_7C15;
            pat = x ^ (x >> 29) ^ salt;
        end
    endfunction

    function automatic [7:0] be_pick(input [15:0] r);
        case (r % 6)
            0:       be_pick = 8'hFF;
            1:       be_pick = 8'h01 << (r % 8);
            2:       be_pick = 8'hA5;
            3:       be_pick = 8'h5A;
            4:       be_pick = 8'h0F << (r % 4);
            default: be_pick = 8'h81;
        endcase
    endfunction

    // ---------------- the masters ----------------
    task automatic do_reset;
        begin
            @(posedge clk);
            reset <= 1'b1;
            repeat (8) @(posedge clk);
            reset <= 1'b0;
            repeat (8) @(posedge clk);
        end
    endtask

    // GS write: strobe and req held until the accept edge
    task automatic gs_wr(input integer line, input [63:0] v, input [7:0] be);
        integer k;
        begin
            @(posedge clk);
            g_addr <= GS_BASE + line;
            g_din  <= v;
            g_be   <= be;
            g_rd   <= 1'b0;
            g_we   <= 1'b0;
            g_req  <= 1'b0;
            @(posedge clk);
            g_we   <= 1'b1;
            g_req  <= 1'b1;
            k = 0;
            @(posedge clk);
            k = k + 1;
            while (g_busy === 1'b1) begin
                @(posedge clk);
                k = k + 1;
                if (k > BUSY_BUDGET) tfail("gs_wr never accepted");
            end
            g_we  <= 1'b0;              // accepted on this edge
            g_req <= 1'b0;
        end
    endtask

    // GS read: w counts the clocks from raising req to the line, fdelta the
    // FDD reads that completed while it waited
    task automatic gs_rd(input integer line, output [63:0] d,
                         output integer w, output integer fdelta);
        integer c0;
        begin
            @(posedge clk);
            g_addr <= GS_BASE + line;
            g_din  <= 64'd0;
            g_be   <= 8'hFF;
            g_rd   <= 1'b0;
            g_we   <= 1'b0;
            g_req  <= 1'b0;
            @(posedge clk);
            g_rd  <= 1'b1;
            g_req <= 1'b1;              // held until the line arrives
            c0 = f_done_cnt;
            w  = 0;
            @(posedge clk);
            w = w + 1;
            while (g_busy === 1'b1) begin
                @(posedge clk);
                w = w + 1;
                if (w > BUSY_BUDGET) tfail("gs_rd never accepted");
            end
            g_rd <= 1'b0;               // accepted
            @(posedge clk);
            w = w + 1;
            while (g_dout_ready !== 1'b1) begin
                @(posedge clk);
                w = w + 1;
                if (w > BUSY_BUDGET) tfail("gs_rd no line back");
            end
            d      = g_dout;
            g_req  <= 1'b0;             // served on this very edge
            fdelta = f_done_cnt - c0;
        end
    endtask

    task automatic fd_wr(input integer line, input [63:0] v, input [7:0] be);
        integer k;
        begin
            @(posedge clk);
            f_addr <= FDD_BASE + line;
            f_din  <= v;
            f_be   <= be;
            f_rd   <= 1'b0;
            f_we   <= 1'b0;
            f_req  <= 1'b0;
            @(posedge clk);
            f_we   <= 1'b1;
            f_req  <= 1'b1;
            k = 0;
            @(posedge clk);
            k = k + 1;
            while (f_busy === 1'b1) begin
                @(posedge clk);
                k = k + 1;
                if (k > BUSY_BUDGET) tfail("fd_wr never accepted");
            end
            f_we  <= 1'b0;
            f_req <= 1'b0;
        end
    endtask

    task automatic fd_rd(input integer line, output [63:0] d, output integer w);
        integer k;
        begin
            @(posedge clk);
            f_addr <= FDD_BASE + line;
            f_din  <= 64'd0;
            f_be   <= 8'hFF;
            f_rd   <= 1'b0;
            f_we   <= 1'b0;
            f_req  <= 1'b0;
            @(posedge clk);
            f_rd  <= 1'b1;
            f_req <= 1'b1;
            w = 0;
            k = 0;
            @(posedge clk);
            k = k + 1;
            while (f_busy === 1'b1) begin
                @(posedge clk);
                k = k + 1;
                if (k > BUSY_BUDGET) tfail("fd_rd never accepted");
            end
            f_rd <= 1'b0;
            @(posedge clk);
            w = w + 1;
            while (f_dout_ready !== 1'b1) begin
                @(posedge clk);
                w = w + 1;
                if (w > BUSY_BUDGET) tfail("fd_rd no line back");
            end
            d     = f_dout;
            f_req <= 1'b0;
        end
    endtask

    // The aggressive FDD master: count reads of lines lo..hi with no idle
    // clock between them - the next address and the strobes go up on the very
    // edge the previous line arrives, so req is high through the whole stream
    // and a grant lost to gs_mem is paid for with the rest of the stream.
    task automatic fd_stream(input integer count,
                             input integer lo, input integer hi);
        integer k, w, line, span;
        reg [63:0] d;
        begin
            span = hi - lo + 1;
            @(posedge clk);
            for (k = 0; k < count; k = k + 1) begin
                line = lo + (k % span);
                f_addr <= FDD_BASE + line;
                f_din  <= 64'd0;
                f_be   <= 8'hFF;
                f_we   <= 1'b0;
                f_rd   <= 1'b1;
                f_req  <= 1'b1;
                w = 0;
                @(posedge clk);
                w = w + 1;
                while (f_busy === 1'b1) begin
                    @(posedge clk);
                    w = w + 1;
                    if (w > BUSY_BUDGET) tfail("fd_stream never accepted");
                end
                f_rd <= 1'b0;
                w = 0;
                @(posedge clk);
                w = w + 1;
                while (f_dout_ready !== 1'b1) begin
                    @(posedge clk);
                    w = w + 1;
                    if (w > BUSY_BUDGET) tfail("fd_stream no line back");
                end
                d = f_dout;
                if (d !== ref_f[line])
                    fail64("fd_stream", FDD_BASE + line, d, ref_f[line]);
            end
            @(posedge clk);
            f_rd  <= 1'b0;
            f_we  <= 1'b0;
            f_be  <= 8'h00;
            f_req <= 1'b0;
        end
    endtask

    // ---------------- the concurrent phases ----------------
    // each is a task of its own so that two forked masters never share a loop
    // variable

    reg prio_go;
    integer gs_max_wait, gs_sum_wait, gs_reads, f0;

    task automatic gs_stream_phase(input integer k_count, input integer budget);
        integer k, w, dl;
        reg [63:0] dv;
        begin
            for (k = 0; k < k_count; k = k + 1) begin
                repeat (GS_PERIOD) @(posedge clk);
                gs_rd(k % 40, dv, w, dl);
                if (dv !== ref_g[k % 40])
                    fail64("gs_priority/gs", GS_BASE + (k % 40), dv, ref_g[k % 40]);
                if (dl > 1) begin
                    if (shown < 8)
                        $display("FAIL gs_priority: %0d FDD reads completed while a GS read waited", dl);
                    shown  = shown + 1;
                    errors = errors + 1;
                end
                if (budget > 0 && w > budget) begin
                    if (shown < 8)
                        $display("FAIL gs_priority: a GS read waited %0d clocks (budget %0d)",
                                 w, budget);
                    shown  = shown + 1;
                    errors = errors + 1;
                end
                if (w > gs_max_wait) gs_max_wait = w;
                gs_sum_wait = gs_sum_wait + w;
                gs_reads    = gs_reads + 1;
            end
        end
    endtask

    task automatic fdd_stream_phase;
        begin
            while (prio_go) fd_stream(200, 0, 63);
        end
    endtask

    // the DDR held busy in the middle of the stream: both masters just wait
    task automatic busy_phase;
        integer k;
        begin
            k = 0;
            while (prio_go) begin
                repeat (17 + (k % 7)) @(posedge clk);
                k = k + 1;
                force_busy <= 1'b1;
                repeat (3 + (k % 9)) @(posedge clk);
                force_busy <= 1'b0;
            end
            force_busy <= 1'b0;
        end
    endtask

    task automatic gs_alt_phase;
        integer k, ln, w, dl;
        reg [63:0] dv;
        reg  [7:0] bbe;
        begin
            for (k = 0; k < 600; k = k + 1) begin
                rnd_g = rnd_g * 32'd1664525 + 32'd1013904223;
                ln    = rnd_g % 512;
                if (rnd_g[15]) begin
                    bbe = be_pick(rnd_g[15:0]);
                    dv  = pat(k + 65536, SALT_GS);
                    gs_wr(ln, dv, bbe);
                    ref_g[ln] = (ref_g[ln] & ~be_mask(bbe)) | (dv & be_mask(bbe));
                end else begin
                    gs_rd(ln, dv, w, dl);
                    if (dv !== ref_g[ln])
                        fail64("alternating_writes/gs", GS_BASE + ln, dv, ref_g[ln]);
                end
                repeat (rnd_g % 4) @(posedge clk);
            end
        end
    endtask

    task automatic fd_alt_phase;
        integer k, ln, w;
        reg [63:0] dv;
        reg  [7:0] bbe;
        begin
            for (k = 0; k < 600; k = k + 1) begin
                rnd_f = rnd_f * 32'd1664525 + 32'd1013904223;
                ln    = rnd_f % 512;
                if (rnd_f[13]) begin
                    bbe = be_pick(rnd_f[15:0] + 16'd2);
                    dv  = pat(k + 131072, SALT_FDD);
                    fd_wr(ln, dv, bbe);
                    ref_f[ln] = (ref_f[ln] & ~be_mask(bbe)) | (dv & be_mask(bbe));
                end else begin
                    fd_rd(ln, dv, w);
                    if (dv !== ref_f[ln])
                        fail64("alternating_writes/fdd", FDD_BASE + ln, dv, ref_f[ln]);
                end
                repeat (rnd_f % 4) @(posedge clk);
            end
        end
    endtask

    // ---------------- contract monitor ----------------
    always @(posedge clk) begin
        if (ddr_burstcnt !== 8'd1)
            bad("ddr_burstcnt is not 1");
        if (g_dout_ready === 1'b1 && f_dout_ready === 1'b1)
            bad("dout_ready to both masters at once");
        if ((ddr_rd || ddr_we) && !g_req && !f_req)
            bad("a DDR request with no master requesting");
        if ((ddr_rd || ddr_we) && g_busy === 1'b0 &&
            (ddr_addr !== g_addr || ddr_din !== g_din || ddr_be !== g_be ||
             ddr_rd  !== g_rd   || ddr_we  !== g_we))
            bad("GS is not busy but the bus is not GS's request");
        if ((ddr_rd || ddr_we) && f_busy === 1'b0 &&
            (ddr_addr !== f_addr || ddr_din !== f_din || ddr_be !== f_be ||
             ddr_rd   !== f_rd   || ddr_we   !== f_we))
            bad("the FDD is not busy but the bus is not the FDD's request");
    end

    // ---------------- the run ----------------
    reg [63:0] d;
    reg [63:0] v;
    reg  [7:0] be;
    integer scratch, scratch2;

    initial begin
        for (i = 0; i < NREF; i = i + 1) begin
            ref_g[i] = 64'd0;
            ref_f[i] = 64'd0;
        end
        rnd_g = 32'h5EED_A117;
        rnd_f = 32'h0DD0_BEEF;
        $display("tb_ddr_arb: GS region %07h, FDD region %07h", GS_BASE, FDD_BASE);

        // ---- gs_only: the GS master alone, varying latency ----
        case_errors = errors;
        shown = 0;
        do_reset;
        for (i = 0; i < NREF; i = i + 1) begin
            model.lat = 3 + (i % 18);
            v = pat(i, SALT_GS);
            gs_wr(i, v, 8'hFF);
            ref_g[i] = v;
        end
        for (i = 0; i < NREF; i = i + 1) begin
            model.lat = 3 + (i % 11);
            gs_rd(i, d, n, scratch);
            if (d !== ref_g[i]) fail64("gs_only", GS_BASE + i, d, ref_g[i]);
        end
        // partial byte enables: the untouched bytes keep the old line
        for (i = 0; i < 512; i = i + 1) begin
            model.lat = 3 + (i % 5);
            be = (i % 3 == 0) ? (8'h01 << (i % 8)) : be_pick(i[15:0]);
            v  = pat(i + 4096, SALT_GS);
            gs_wr((i * 7) % NREF, v, be);
            ref_g[(i * 7) % NREF] =
                (ref_g[(i * 7) % NREF] & ~be_mask(be)) | (v & be_mask(be));
        end
        for (i = 0; i < NREF; i = i + 1) begin
            gs_rd(i, d, n, scratch);
            if (d !== ref_g[i]) fail64("gs_only_be", GS_BASE + i, d, ref_g[i]);
        end
        // the top of the region
        hline[0] = 262143; hline[1] = 262142; hline[2] = 262140;
        hline[3] = 131072; hline[4] = 131073; hline[5] = 65535;
        hline[6] = 262141; hline[7] = 1;
        for (i = 0; i < NHIGH; i = i + 1) begin
            hval[i] = pat(hline[i], SALT_GS);
            gs_wr(hline[i], hval[i], 8'hFF);
        end
        for (i = 0; i < NHIGH; i = i + 1) begin
            gs_rd(hline[i], d, n, scratch);
            if (d !== hval[i])
                fail64("gs_only_high", GS_BASE + hline[i], d, hval[i]);
        end
        if (errors == case_errors) $display("gs_only: ok");
        else                       $display("gs_only: FAIL");

        // ---- fdd_only: the FDD master alone ----
        case_errors = errors;
        shown = 0;
        do_reset;
        for (i = 0; i < NREF; i = i + 1) begin
            model.lat = 3 + (i % 18);
            v = pat(i, SALT_FDD);
            fd_wr(i, v, 8'hFF);
            ref_f[i] = v;
        end
        for (i = 0; i < NREF; i = i + 1) begin
            model.lat = 3 + (i % 11);
            fd_rd(i, d, n);
            if (d !== ref_f[i]) fail64("fdd_only", FDD_BASE + i, d, ref_f[i]);
        end
        for (i = 0; i < 512; i = i + 1) begin
            model.lat = 3 + (i % 5);
            be = (i % 4 == 0) ? (8'h80 >> (i % 8)) : be_pick(i[15:0] + 16'd3);
            v  = pat(i + 8192, SALT_FDD);
            fd_wr((i * 5) % NREF, v, be);
            ref_f[(i * 5) % NREF] =
                (ref_f[(i * 5) % NREF] & ~be_mask(be)) | (v & be_mask(be));
        end
        for (i = 0; i < NREF; i = i + 1) begin
            fd_rd(i, d, n);
            if (d !== ref_f[i]) fail64("fdd_only_be", FDD_BASE + i, d, ref_f[i]);
        end
        hline_f[0] = 524287; hline_f[1] = 262143; hline_f[2] = 524284;
        hline_f[3] = 262140; hline_f[4] = 262149; hline_f[5] = 5;
        hline_f[6] = 393216; hline_f[7] = 262144;
        for (i = 0; i < NHIGH; i = i + 1) begin
            hval[i] = pat(hline_f[i], SALT_FDD);
            fd_wr(hline_f[i], hval[i], 8'hFF);
        end
        for (i = 0; i < NHIGH; i = i + 1) begin
            fd_rd(hline_f[i], d, n);
            if (d !== hval[i])
                fail64("fdd_only_high", FDD_BASE + hline_f[i], d, hval[i]);
        end
        if (errors == case_errors) $display("fdd_only: ok");
        else                       $display("fdd_only: FAIL");

        // ---- gs_priority: an FDD stream that never idles ----
        case_errors = errors;
        shown = 0;
        model.lat = 6;
        do_reset;
        for (i = 0; i < 64; i = i + 1) begin
            v = pat(i, SALT_FDD);
            fd_wr(i, v, 8'hFF);
            ref_f[i] = v;
        end
        for (i = 0; i < 40; i = i + 1) begin
            v = pat(i, SALT_GS);
            gs_wr(i, v, 8'hFF);
            ref_g[i] = v;
        end
        f0          = f_done_cnt;
        gs_max_wait = 0;
        gs_sum_wait = 0;
        gs_reads    = 0;
        prio_go     = 1'b1;
        fork
            begin
                gs_stream_phase(GS_STREAM_K, GS_WAIT_BUDGET);
                prio_go = 1'b0;
            end
            fdd_stream_phase;
        join
        $display("gs_priority: %0d GS reads, max wait %0d clocks, mean %0d, %0d FDD reads completed alongside",
                 gs_reads, gs_max_wait, gs_sum_wait / gs_reads, f_done_cnt - f0);
        // the same with the DDR held busy for 3..11 clocks at a time
        for (i = 0; i < 12; i = i + 1) begin
            v = pat(i, SALT_GS);
            gs_wr(i, v, 8'hFF);
            ref_g[i] = v;
        end
        prio_go = 1'b1;
        fork
            begin
                gs_stream_phase(12, 0);
                prio_go = 1'b0;
            end
            fdd_stream_phase;
            busy_phase;
        join
        if (errors == case_errors) $display("gs_priority: ok");
        else                       $display("gs_priority: FAIL");

        // ---- alternating_writes: both masters at once ----
        case_errors = errors;
        shown = 0;
        do_reset;
        model.lat = 5;
        for (i = 0; i < 512; i = i + 1) begin
            v = pat(i, SALT_GS);
            gs_wr(i, v, 8'hFF);
            ref_g[i] = v;
            v = pat(i, SALT_FDD);
            fd_wr(i, v, 8'hFF);
            ref_f[i] = v;
        end
        fork
            gs_alt_phase;
            fd_alt_phase;
        join
        // everything read back once both masters are done
        for (i = 0; i < 512; i = i + 1) begin
            gs_rd(i, d, scratch, scratch2);
            if (d !== ref_g[i])
                fail64("alternating_writes/gs_back", GS_BASE + i, d, ref_g[i]);
            fd_rd(i, d, scratch);
            if (d !== ref_f[i])
                fail64("alternating_writes/fdd_back", FDD_BASE + i, d, ref_f[i]);
        end
        if (errors == case_errors) $display("alternating_writes: ok");
        else                       $display("alternating_writes: FAIL");

        // ---- reset_idle: reset with a read in flight ----
        case_errors = errors;
        shown = 0;
        do_reset;
        model.lat = 5;
        @(posedge clk);
        f_addr <= FDD_BASE + 7;
        f_be   <= 8'hFF;
        f_rd   <= 1'b0;
        f_we   <= 1'b0;
        f_req  <= 1'b0;
        @(posedge clk);
        f_rd  <= 1'b1;
        f_req <= 1'b1;
        n = 0;
        @(posedge clk);
        n = n + 1;
        while (f_busy === 1'b1) begin
            @(posedge clk);
            n = n + 1;
            if (n > BUSY_BUDGET) tfail("reset_idle: the FDD read was never accepted");
        end
        f_rd <= 1'b0;                   // accepted; the line is on its way
        @(posedge clk);
        reset <= 1'b1;                  // PLL lock: abort it in flight
        n = 0;
        while (n < 6) begin
            @(posedge clk);
            n = n + 1;
            if (ddr_rd !== 1'b0 || ddr_we !== 1'b0)
                bad("reset left a strobe on the DDR bus");
            if (g_busy !== 1'b1 || f_busy !== 1'b1)
                bad("a master is not busy during the reset");
        end
        // the abandoned line must not be handed to anyone
        n = 0;
        while (model.rd_in_flight === 1'b1) begin
            @(posedge clk);
            n = n + 1;
            if (n > BUSY_BUDGET) tfail("reset_idle: the abandoned read never landed");
            if (g_dout_ready === 1'b1 || f_dout_ready === 1'b1)
                bad("a master was handed the line of the aborted read");
        end
        f_rd  <= 1'b0;
        f_we  <= 1'b0;
        f_be  <= 8'h00;
        f_req <= 1'b0;
        @(posedge clk);
        reset <= 1'b0;
        repeat (8) @(posedge clk);
        if (dut.state !== ST_IDLE)
            bad("the arbiter did not come out of reset in IDLE");
        if (g_busy !== 1'b1 || f_busy !== 1'b1)
            bad("a master is not busy right after the reset");
        // and both masters work again
        fd_rd(7, d, scratch);
        if (d !== ref_f[7]) fail64("reset_idle", FDD_BASE + 7, d, ref_f[7]);
        gs_rd(3, d, scratch, scratch2);
        if (d !== ref_g[3]) fail64("reset_idle", GS_BASE + 3, d, ref_g[3]);
        v = pat(999, SALT_FDD);
        fd_wr(200, v, 8'h81);
        ref_f[200] = (ref_f[200] & ~be_mask(8'h81)) | (v & be_mask(8'h81));
        v = pat(998, SALT_GS);
        gs_wr(200, v, 8'h5A);
        ref_g[200] = (ref_g[200] & ~be_mask(8'h5A)) | (v & be_mask(8'h5A));
        fd_rd(200, d, scratch);
        if (d !== ref_f[200]) fail64("reset_idle", FDD_BASE + 200, d, ref_f[200]);
        gs_rd(200, d, scratch, scratch2);
        if (d !== ref_g[200]) fail64("reset_idle", GS_BASE + 200, d, ref_g[200]);
        if (errors == case_errors) $display("reset_idle: ok");
        else                       $display("reset_idle: FAIL");

        // ---- verdict ----
        if (errors == 0)
            $display("tb_ddr_arb: PASS");
        else
            $display("tb_ddr_arb: FAIL %0d error(s)", errors);
        $finish;
    end

    // edge-counted global watchdog (no $time arithmetic: it is unreliable in
    // deep Icarus runs)
    integer watchdog;
    initial begin
        watchdog = 0;
        forever begin
            @(posedge clk);
            watchdog = watchdog + 1;
            if (watchdog > 8000000) begin
                $display("tb_ddr_arb: FAIL global timeout");
                $finish;
            end
        end
    end

endmodule
