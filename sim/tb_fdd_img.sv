// Testbench for rtl/disk/fdd_store.sv, the floppy image store of stage 4c.
// PART A (of the two of Task 4): the store is driven directly - there is no
// fdd_src and no hps_disk_model here. A bench fill task streams the store's
// config/fill/ready handshake (the shape fdd_src will use), a bench drive
// model is the store's floppy customer (the Task 3 interface: track requests
// with toggle handshakes, the written-sector buffer, the acks) and reads the
// track buffer's port B on the second clock, and a bench host watches the
// drain handshake (block payload, ack, drain-buffer bytes). The DDR side is
// ddr_arb with the GS master driven by this bench against
// sim/models/ddram_model.sv (FAIL_TAG = "tb_fdd_img", BUSY_PCT = 20: busy
// windows are the norm here).
//
// The fill is sparse where the case does not look at the bytes: the store
// only ever reads DDR, and the model powers its memory up as zero; a
// fixture's untouched ranges are zero as well, so the reference tracks
// (generated from the very image files by `mk_disk.py reffrom`) stay
// byte-exact.
//
// Cases (each prints `PASS <case>` or `FAIL <case> ...`):
//   trd_track_exact       TRD drive A: track 0/0 (the catalog's own bytes)
//                         and track 5/1 equal reftrack byte for byte, sync
//                         flags included; H = 0 in the IDs of both sides.
//   cpm_track_exact       CP/M drive B: track 3/1, 5 x 1024, H = 1.
//   fdi_track_exact       FDI through the table port: test.fdi track 0/1 (H
//                         from the record) and wide.fdi track 0/0 (512 B
//                         sectors and the 0x40 sector: ID only, no data mark).
//   write_back            a TRD 256 B sector: the track buffer patched with
//                         data and the recomputed CRC, DDR at the TRD offset
//                         holds the new bytes, one dirty block drained with
//                         the block's DDR contents in the drain buffer, then
//                         silence; a CP/M 1024 B write drains two blocks.
//   fdi_write_volatile    an FDI write patches the buffer and DDR, and no
//                         drain ever starts.
//   request_while_filling a request before ready answers ready = 0 with the
//                         echo; after ready it builds the exact track.
//   gs_traffic_during_build GS reads and writes run through two track
//                         builds: all GS data stays correct.
//   eject_mid_fill        a config mid drain (toggle out, unacked) and mid
//                         fill clears the dirty bitmap: no second toggle,
//                         no hang, the refilled image builds exact, and the
//                         dirty path works again afterwards.
//   remount_mid_drain     a config with one drain toggle in flight and a
//                         second block queued: the ack of the dropped block
//                         must not hang and must not re-arm, the remounted
//                         image builds exact, two fresh blocks drain.
//
// Every wait is bounded by an edge count, never by a $time difference, and
// the last line printed is `tb_fdd_img: PASS` or `tb_fdd_img: FAIL <reason>`;
// run via sim/run_tb_fdd_img.sh (iverilog -g2012).
`timescale 1ns / 1ps

module tb_fdd_img;

    // ---------------- clocks ----------------
    reg clk  = 1'b0;                 // gs_clk 28.125 MHz: the store's clock
    always #17.7775 clk  = ~clk;
    reg bclk = 1'b0;                 // the bus/host clock: the drive model,
    always #20 bclk = ~bclk;         // the fill, the drain host

    // edge-count budgets (never $time arithmetic)
    localparam integer FILL_BUDGET  = 400_000;  // a fill byte across ack
    localparam integer REQ_BUDGET   = 400_000;  // a track request across ack
    localparam integer WR_BUDGET    = 400_000;  // a written sector across ack
    localparam integer DN_BUDGET    = 400_000;  // a drain block across toggle
    localparam integer WATCH_BUDGET = 100_000;  // clocks of watched silence
    localparam integer GS_BUDGET    = 20_000;   // a GS transaction

    localparam integer WATCHDOG = 15_000_000;   // gs clocks for the whole run

    // ---------------- DUT and DDR side ----------------
    reg reset = 1'b1;

    wire        f_req;
    wire [28:0] f_addr;
    wire [63:0] f_din;
    wire  [7:0] f_be;
    wire        f_rd;
    wire        f_we;
    wire        f_busy;
    wire [63:0] f_dout;
    wire        f_dout_ready;

    localparam [28:0] GS_BASE = 29'h0600_0000;  // the GS region

    reg         g_req  = 1'b0;
    reg  [28:0] g_addr = 29'd0;
    reg  [63:0] g_din  = 64'd0;
    reg   [7:0] g_be   = 8'd0;
    reg         g_rd   = 1'b0;
    reg         g_we   = 1'b0;
    wire        g_busy;
    wire [63:0] g_dout;
    wire        g_dout_ready;

    wire        ddr_rd, ddr_we;
    wire [28:0] ddr_addr;
    wire [63:0] ddr_din;
    wire  [7:0] ddr_be;
    wire  [7:0] ddr_burstcnt;
    wire        ddr_busy;
    wire [63:0] ddr_dout;
    wire        ddr_dout_ready;

    ddr_arb dut_arb (
        .clk(clk), .reset(reset),
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
        .BUSY_PCT(20),
        .FAIL_TAG("tb_fdd_img")
    ) model (
        .clk(clk),
        .force_busy(1'b0),
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

    // ---------------- the store's world ----------------
    reg         fill_tgl    = 1'b0;
    reg  [31:0] fill_word   = 32'd0;
    wire        fill_ack_tgl;

    reg         trk_req_tgl = 1'b0;
    reg   [8:0] trk_req     = 9'd0;
    wire        trk_ack_tgl;
    wire  [9:0] trk_ack;
    reg  [12:0] trk_addr_b  = 13'd0;
    wire  [8:0] trk_q_b;

    reg  [9:0]  wr_addr     = 10'd0;
    reg  [7:0]  wr_data     = 8'd0;
    reg         wr_we       = 1'b0;
    reg         wr_tgl      = 1'b0;
    reg  [35:0] wr_info     = 36'd0;
    wire        wr_ack_tgl;

    reg   [8:0] drn_addr_b  = 9'd0;
    wire  [7:0] drn_q_b;
    wire        drn_tgl;
    wire [11:0] drn_info;               // {drive, block[10:0]}
    reg         drn_ack_tgl = 1'b0;

    fdd_store dut (
        .clk(clk), .reset(reset), .clk_bus(bclk), .clk_sys(bclk),
        .f_req(f_req), .f_addr(f_addr), .f_din(f_din), .f_be(f_be),
        .f_rd(f_rd), .f_we(f_we),
        .f_busy(f_busy), .f_dout(f_dout), .f_dout_ready(f_dout_ready),
        .fill_tgl(fill_tgl), .fill_word(fill_word),
        .fill_ack_tgl(fill_ack_tgl),
        .trk_req_tgl(trk_req_tgl), .trk_req(trk_req),
        .trk_ack_tgl(trk_ack_tgl), .trk_ack(trk_ack),
        .trk_addr_b(trk_addr_b), .trk_q_b(trk_q_b),
        .wr_addr(wr_addr), .wr_data(wr_data), .wr_we(wr_we),
        .wr_info(wr_info), .wr_tgl(wr_tgl), .wr_ack_tgl(wr_ack_tgl),
        .drn_addr_b(drn_addr_b), .drn_q_b(drn_q_b),
        .drn_tgl(drn_tgl), .drn_info(drn_info),
        .drn_ack_tgl(drn_ack_tgl)
    );

    // ---------------- the fixtures ----------------
    localparam integer TRD_B  = 655360;         // 80 tracks
    localparam integer CPM_B  = 819200;         // 80 tracks
    localparam integer PROG_W = 16384;          // fill program words
    localparam integer TRKN   = 6250;

    reg [7:0]  trd    [0:TRD_B-1];
    reg [7:0]  cpm    [0:CPM_B-1];
    reg [31:0] fdi_p  [0:PROG_W-1];             // alternating address, data
    reg [31:0] wd_p   [0:PROG_W-1];
    reg [7:0]  ref_trd0 [0:TRKN-1];
    reg [7:0]  ref_trd5 [0:TRKN-1];
    reg [7:0]  ref_cpm3 [0:TRKN-1];
    reg [7:0]  ref_cpm4 [0:TRKN-1];
    reg [7:0]  ref_fdi0 [0:TRKN-1];
    reg [7:0]  ref_wide [0:TRKN-1];
    reg        syc_trd0 [0:TRKN-1];
    reg        syc_trd5 [0:TRKN-1];
    reg        syc_cpm3 [0:TRKN-1];
    reg        syc_cpm4 [0:TRKN-1];
    reg        syc_fdi0 [0:TRKN-1];
    reg        syc_wide [0:TRKN-1];

    integer fdi_n, wd_n;                        // used words of the programs

    initial begin
        $readmemh("build/sim/fdd_img/trd.hex",   trd);
        $readmemh("build/sim/fdd_img/cpm.hex",   cpm);
        $readmemh("build/sim/fdd_img/fdi.prog",  fdi_p);
        $readmemh("build/sim/fdd_img/wide.prog", wd_p);
        $readmemh("build/sim/fdd_img/ref_trd_t0s0",     ref_trd0);
        $readmemh("build/sim/fdd_img/ref_trd_t0s0.sync", syc_trd0);
        $readmemh("build/sim/fdd_img/ref_trd_t5s1",     ref_trd5);
        $readmemh("build/sim/fdd_img/ref_trd_t5s1.sync", syc_trd5);
        $readmemh("build/sim/fdd_img/ref_cpm_t3s1",     ref_cpm3);
        $readmemh("build/sim/fdd_img/ref_cpm_t3s1.sync", syc_cpm3);
        $readmemh("build/sim/fdd_img/ref_cpm_t4s0",     ref_cpm4);
        $readmemh("build/sim/fdd_img/ref_cpm_t4s0.sync", syc_cpm4);
        $readmemh("build/sim/fdd_img/ref_fdi_t0s1",     ref_fdi0);
        $readmemh("build/sim/fdd_img/ref_fdi_t0s1.sync", syc_fdi0);
        $readmemh("build/sim/fdd_img/ref_wide_t0s0",     ref_wide);
        $readmemh("build/sim/fdd_img/ref_wide_t0s0.sync", syc_wide);
        fdi_n = 0;
        while (fdi_n < PROG_W && fdi_p[fdi_n] === fdi_p[fdi_n])
            fdi_n = fdi_n + 1;
        wd_n = 0;
        while (wd_n < PROG_W && wd_p[wd_n] === wd_p[wd_n])
            wd_n = wd_n + 1;
    end

    // ---------------- bookkeeping ----------------
    integer errors = 0, shown = 0, case_errors = 0;

    task automatic bad(input [8*72-1:0] what);
        begin
            if (shown < 8) $display("FAIL %0s", what);
            else if (shown == 8)
                $display("FAIL more failures follow (not printed)");
            shown  = shown + 1;
            errors = errors + 1;
        end
    endtask

    task automatic tfail(input [8*72-1:0] what);   // a stuck machine: end now
        begin
            $display("tb_fdd_img: FAIL %0s", what);
            $finish;
        end
    endtask

    task automatic case_start;
        begin case_errors = errors; shown = 0; end
    endtask

    task automatic case_end(input [8*40-1:0] cs);
        begin
            if (errors == case_errors) $display("PASS %0s", cs);
            else $display("FAIL %0s (%0d checks failed)",
                          cs, errors - case_errors);
        end
    endtask

    // edge-counted watchdog (no $time arithmetic: unreliable in deep runs)
    initial begin : watchdog
        integer w;
        w = 0;
        forever begin
            @(posedge clk);
            w = w + 1;
            if (w > WATCHDOG) tfail("watchdog: the run never finished");
        end
    end

    // ---------------- the fill port (the bench is fdd_src) ----------------
    // fill_word kinds: 0 config {drive, kind, tracks, sides},
    // 1 byte {addr[21:0], data}, 2 ready {drive}
    task automatic fill_send(input [31:0] word);
        integer k;
        reg seen;
        begin
            @(posedge bclk);
            fill_word <= word;
            fill_tgl  <= ~fill_tgl;
            seen      = fill_ack_tgl;
            k         = 0;
            @(posedge bclk);
            k = k + 1;
            while (fill_ack_tgl === seen) begin
                @(posedge bclk);
                k = k + 1;
                if (k > FILL_BUDGET) tfail("a fill byte was never acked");
            end
        end
    endtask

    task automatic fill_config(input d, input [1:0] kind,
                               input [6:0] tracks, input sides);
        begin
            fill_send({2'd0, d, kind, tracks, sides, 19'd0});
        end
    endtask

    task automatic fill_ready(input d);
        begin
            fill_send({2'd2, d, 29'd0});
        end
    endtask

    // image bytes lo..lo+n-1: sel 0 = trd[], 1 = cpm[]
    task automatic fill_mem(input sel, input [20:0] lo, input integer n);
        integer k;
        reg [7:0] v;
        begin
            for (k = 0; k < n; k = k + 1) begin
                v = sel ? cpm[lo + k[20:0]] : trd[lo + k[20:0]];
                fill_send({2'd1, lo + k[21:0], v});
            end
        end
    endtask

    // an FDI fill program: which 0 = fdi.prog, 1 = wide.prog
    task automatic fill_prog(input which);
        integer k, n;
        reg [31:0] aw, dw;
        begin
            n = which ? wd_n : fdi_n;
            for (k = 0; k + 1 < n; k = k + 2) begin
                aw = which ? wd_p[k] : fdi_p[k];
                dw = which ? wd_p[k + 1] : fdi_p[k + 1];
                fill_send({2'd1, aw[21:0], dw[7:0]});
            end
        end
    endtask

    // ---------------- the bench drive model ----------------
    task automatic req_track(input d, input s, input [6:0] t,
                             output rdy);
        integer k;
        reg seen;
        begin
            @(posedge bclk);
            trk_req     <= {d, s, t};
            trk_req_tgl <= ~trk_req_tgl;
            seen        = trk_ack_tgl;
            k           = 0;
            @(posedge bclk);
            k = k + 1;
            while (trk_ack_tgl === seen) begin
                @(posedge bclk);
                k = k + 1;
                if (k > REQ_BUDGET)
                    tfail("a track request was never acked");
            end
            rdy = trk_ack[9];
            if (trk_ack[8:0] !== {d, s, t}) begin
                $display("FAIL ack echo %03o is not the request %03o",
                         trk_ack[8:0], {d, s, t});
                errors = errors + 1;
            end
        end
    endtask

    // write patterns, shared by the writer and every expectation
    function automatic [7:0] pat(input integer kind, input integer j,
                                 input [7:0] c);
        begin
            case (kind)
                0:       pat = 8'hA0 ^ j[7:0];
                1:       pat = ~j[7:0];
                default: pat = j[7:0] + c;
            endcase
        end
    endfunction

    // fill the written-sector buffer (port A on bclk), toggle, wait the ack
    task automatic wr_sector(input d, input s, input [6:0] t,
                             input [7:0] C, H, R, input [2:0] N,
                             input integer len, input integer kind,
                             input [7:0] c);
        integer k;
        reg seen;
        begin
            for (k = 0; k < len; k = k + 1) begin
                @(posedge bclk);
                wr_addr <= k[9:0];
                wr_data <= pat(kind, k, c);
                wr_we   <= 1'b1;
                @(posedge bclk);
                wr_we   <= 1'b0;
            end
            @(posedge bclk);
            wr_info <= {d, s, t, C, H, R, N};
            wr_tgl  <= ~wr_tgl;
            seen    = wr_ack_tgl;
            k       = 0;
            @(posedge bclk);
            k = k + 1;
            while (wr_ack_tgl === seen) begin
                @(posedge bclk);
                k = k + 1;
                if (k > WR_BUDGET) tfail("a written sector was never acked");
            end
        end
    endtask

    // ---------------- the drain host ----------------
    integer dn_seen = 0;                        // toggles counted
    integer dnq_n   = 0;                        // toggles consumed
    integer dnq_drv [0:63];
    integer dnq_blk [0:63];

    always @(posedge drn_tgl) begin
        if (dn_seen < 64) begin
            dnq_drv[dn_seen] = drn_info[11];
            dnq_blk[dn_seen] = drn_info[10:0];
        end
        dn_seen = dn_seen + 1;
    end

    // wait until a toggle is out there, without consuming it
    task automatic wait_drain_toggle;
        integer k, n0;
        begin
            n0 = dn_seen;
            k  = 0;
            while (dn_seen == n0) begin
                @(posedge bclk);
                k = k + 1;
                if (k > DN_BUDGET) tfail("a drain block was never presented");
            end
        end
    endtask

    // the drain buffer's expected bytes: the DDR block, with the written
    // sector's pattern where that write patched it
    reg [7:0] exp_blk [0:511];

    task automatic build_exp(input imgsel, input integer blk,
                             input [20:0] file_off, input integer len,
                             input integer kind, input [7:0] c);
        integer k;
        reg [20:0] b;
        begin
            for (k = 0; k < 512; k = k + 1) begin
                b = {blk[11:0], 9'd0} + k[20:0];
                if (b >= file_off && b < file_off + len[20:0])
                    exp_blk[k] = pat(kind, b - file_off, c);
                else
                    exp_blk[k] = imgsel ? cpm[b] : trd[b];
            end
        end
    endtask

    // consume the pending toggle: payload, optionally the buffer's bytes, ack
    task automatic expect_drain(input want_drv, input [10:0] want_blk,
                                input check_data);
        integer k;
        reg [7:0] v;
        begin
            k = 0;
            while (dn_seen == dnq_n) begin
                @(posedge bclk);
                k = k + 1;
                if (k > DN_BUDGET) tfail("a drain block was never presented");
            end
            if (dnq_n >= 64) tfail("drain queue overflow");
            if (dnq_drv[dnq_n] !== want_drv || dnq_blk[dnq_n] !== want_blk) begin
                $display("FAIL drain block %0d:%0d expected %0d:%0d",
                         dnq_drv[dnq_n], dnq_blk[dnq_n], want_drv, want_blk);
                errors = errors + 1;
            end
            dnq_n = dnq_n + 1;
            if (check_data) begin
                for (k = 0; k < 512; k = k + 1) begin
                    @(posedge bclk);
                    drn_addr_b <= k[8:0];
                    @(posedge bclk);
                    @(posedge bclk);
                    v = drn_q_b;
                    if (v !== exp_blk[k]) begin
                        if (shown < 8)
                            $display("FAIL drain data [%0d] got %02x want %02x",
                                     k, v, exp_blk[k]);
                        shown  = shown + 1;
                        errors = errors + 1;
                        if (shown == 8)
                            $display("FAIL more failures follow (not printed)");
                    end
                end
            end
            @(posedge bclk);
            drn_ack_tgl <= ~drn_ack_tgl;
        end
    endtask

    // drop a pending toggle without looking (the eject cases): the store
    // must consume the late ack and stay quiet
    task automatic drain_host_ack;
        begin
            dnq_n = dnq_n + 1;
            @(posedge bclk);
            drn_ack_tgl <= ~drn_ack_tgl;
        end
    endtask

    task automatic expect_no_drain(input [8*56-1:0] why);
        integer k, n0;
        begin
            n0 = dn_seen;
            for (k = 0; (k < WATCH_BUDGET) && (dn_seen == n0); k = k + 1)
                @(posedge bclk);
            if (dn_seen != n0) begin
                $display("FAIL %0s: a drain toggle came anyway", why);
                errors = errors + 1;
            end
        end
    endtask

    // ---------------- DDR peek (the model's memory) ----------------
    // the model's FDD index: 262144 + addr[18:0], addr = {base, drive, line}
    task automatic dd_peek(input d, input [20:0] off, output [63:0] v);
        begin
            v = model.mem[262144 + d * 262144 + (off >> 3)];
        end
    endtask

    // the store's write-lane rule: byte at off lives in lane off[2:0]
    task automatic dd_expect(input [8*40-1:0] who, input d, input [20:0] lo,
                             input integer n, input integer kind,
                             input [7:0] c);
        integer k;
        reg [63:0] line;
        begin
            for (k = 0; k < n; k = k + 1) begin
                dd_peek(d, lo + k[20:0], line);
                if (line[8 * ((lo + k[20:0]) & 32'd7) +: 8] !==
                    pat(kind, k, c)) begin
                    if (shown < 8)
                        $display("FAIL %0s ddr[%0d:%0d] got %02x want %02x",
                                 who, d, lo + k[20:0],
                                 line[8 * ((lo + k[20:0]) & 32'd7) +: 8],
                                 pat(kind, k, c));
                    shown  = shown + 1;
                    errors = errors + 1;
                end
            end
        end
    endtask

    // ---------------- the track buffer, read drive style ----------------
    // refsel: 0 trd0, 1 trd5, 2 cpm3, 3 cpm4, 4 fdi0, 5 wide
    task automatic check_track(input [8*40-1:0] who, input integer refsel);
        integer a, stop;
        reg [7:0] w;
        reg       s, gs;
        begin
            stop = 0;
            for (a = 0; (a < TRKN) && !stop; a = a + 1) begin
                @(posedge bclk);
                trk_addr_b <= a[12:0];
            @(posedge bclk);
                @(posedge bclk);
                gs = trk_q_b[8];
                case (refsel)
                    0: begin w = ref_trd0[a]; s = syc_trd0[a]; end
                    1: begin w = ref_trd5[a]; s = syc_trd5[a]; end
                    2: begin w = ref_cpm3[a]; s = syc_cpm3[a]; end
                    3: begin w = ref_cpm4[a]; s = syc_cpm4[a]; end
                    4: begin w = ref_fdi0[a]; s = syc_fdi0[a]; end
                    default: begin w = ref_wide[a]; s = syc_wide[a]; end
                endcase
                if (trk_q_b[7:0] !== w || gs !== s) begin
                    $display("FAIL %0s track[%0d] got {%b,%02x} want {%b,%02x}",
                             who, a, gs, trk_q_b[7:0], s, w);
                    errors = errors + 1;
                    stop = 1;
                end
            end
        end
    endtask

    // a patched sector: pattern bytes and the recomputed data CRC, read
    // back from the track buffer
    function automatic [15:0] crc_step(input [15:0] c, input [7:0] b);
        integer i;
        reg [15:0] x;
        begin
            x = c ^ {b, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                x = x[15] ? {x[14:0], 1'b0} ^ 16'h1021 : {x[14:0], 1'b0};
            crc_step = x;
        end
    endfunction

    task automatic check_patch(input [8*40-1:0] who, input [12:0] buf_at,
                               input integer len, input integer kind,
                               input [7:0] c);
        integer a, stop;
        reg [7:0] w;
        reg       s;
        reg [15:0] crc;
        begin
            stop = 0;
            for (a = 0; (a < len) && !stop; a = a + 1) begin
                @(posedge bclk);
                trk_addr_b <= buf_at + a[12:0];
            @(posedge bclk);
                @(posedge bclk);
                w  = pat(kind, a, c);
                s  = trk_q_b[8];
                if (trk_q_b[7:0] !== w || s !== 1'b0) begin
                    $display("FAIL %0s patched[%0d] got {%b,%02x} want %02x",
                             who, a, trk_q_b[8], trk_q_b[7:0], w);
                    errors = errors + 1;
                    stop = 1;
                end
            end
            crc = 16'hFFFF;
            crc = crc_step(crc, 8'hA1); crc = crc_step(crc, 8'hA1);
            crc = crc_step(crc, 8'hA1); crc = crc_step(crc, 8'hFB);
            for (a = 0; a < len; a = a + 1)
                crc = crc_step(crc, pat(kind, a, c));
            @(posedge bclk);
            trk_addr_b <= buf_at + len[12:0];
            @(posedge bclk);
            @(posedge bclk);
            s = trk_q_b[8];
            if (trk_q_b[7:0] !== crc[15:8] || s !== 1'b0) begin
                $display("FAIL %0s crc hi got %02x want %02x",
                         who, trk_q_b[7:0], crc[15:8]);
                errors = errors + 1;
            end
            @(posedge bclk);
            trk_addr_b <= buf_at + len[12:0] + 13'd1;
            @(posedge bclk);
            @(posedge bclk);
            if (trk_q_b[7:0] !== crc[7:0]) begin
                $display("FAIL %0s crc lo got %02x want %02x",
                         who, trk_q_b[7:0], crc[7:0]);
                errors = errors + 1;
            end
        end
    endtask

    // ---------------- FDI meta: parse a fill program ----------------
    // table layout (the store's): header {tag 2'b11, track, byte} with the
    // DataOffset LE in bytes 0..3 and the count in byte 4; records
    // {tag 2'b10, track, sector, byte} = C,H,R,N,flags,off_lo,off_hi
    reg [7:0]  ti_doffb [0:1][0:3];
    reg [7:0]  ti_cnt   [0:1];
    reg [7:0]  ti_c     [0:1][0:31];
    reg [7:0]  ti_hh    [0:1][0:31];
    reg [7:0]  ti_r     [0:1][0:31];
    reg [7:0]  ti_n     [0:1][0:31];
    reg [7:0]  ti_oflo  [0:1][0:31];
    reg [7:0]  ti_ofhi  [0:1][0:31];
    integer    ti_trk;                           // the track the program held

    task automatic parse_fdi(input which);
        integer k, t, sec, b, n;
        reg [31:0] a;
        reg [7:0]  v;
        begin
            ti_doffb[0][0] = 8'd0; ti_doffb[0][1] = 8'd0;
            ti_doffb[0][2] = 8'd0; ti_doffb[0][3] = 8'd0;
            ti_doffb[1][0] = 8'd0; ti_doffb[1][1] = 8'd0;
            ti_doffb[1][2] = 8'd0; ti_doffb[1][3] = 8'd0;
            ti_cnt[0] = 8'd0;      ti_cnt[1] = 8'd0;
            ti_trk    = -1;
            n = which ? wd_n : fdi_n;
            for (k = 0; k + 1 < n; k = k + 2) begin
                a = which ? wd_p[k] : fdi_p[k];
                v = which ? wd_p[k + 1][7:0] : fdi_p[k + 1][7:0];
                if (a[21]) begin
                    if (a[20]) begin                    // a track header
                        t = a[10:3];
                        if (t <= 1) begin
                            ti_trk = t;
                            b = a[2:0];
                            if (b < 4) ti_doffb[t][b] = v;
                            else if (b == 3'd4) ti_cnt[t] = v;
                        end
                    end
                    else begin                          // a sector record
                        t   = a[15:8];
                        sec = a[7:3];
                        b   = a[2:0];
                        if (t <= 1 && sec <= 31) begin
                            ti_trk = t;
                            case (b)
                                0: ti_c[t][sec]    = v;
                                1: ti_hh[t][sec]   = v;
                                2: ti_r[t][sec]    = v;
                                3: ti_n[t][sec]    = v;
                                5: ti_oflo[t][sec] = v;
                                6: ti_ofhi[t][sec] = v;
                                default: ;
                            endcase
                        end
                    end
                end
            end
        end
    endtask

    // the file offset the store must match for a write of (C,H,R,N)
    function automatic [20:0] fdi_file_off(input [7:0] C, H, R, input [2:0] N);
        integer s;
        reg [7:0] t;
        reg [31:0] doff;
        begin
            fdi_file_off = 21'h1F_FFFF;
            t = ti_trk[0];
            doff = {ti_doffb[t][3], ti_doffb[t][2], ti_doffb[t][1],
                    ti_doffb[t][0]};
            for (s = 0; s < ti_cnt[t]; s = s + 1)
                if (ti_c[t][s] === C && ti_hh[t][s] === H &&
                    ti_r[t][s] === R && ti_n[t][s] === N)
                    fdi_file_off = doff[20:0] +
                                   {5'd0, ti_ofhi[t][s], ti_oflo[t][s]};
        end
    endfunction

    // ---------------- the GS master ----------------
    reg [63:0] ref_g [0:511];
    integer    rnd_g = 32'h1234_5678;

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
            g_we  <= 1'b1;
            g_req <= 1'b1;
            k = 0;
            @(posedge clk);
            k = k + 1;
            while (g_busy === 1'b1) begin
                @(posedge clk);
                k = k + 1;
                if (k > GS_BUDGET) tfail("gs_wr never accepted");
            end
            g_we  <= 1'b0;              // accepted on this edge
            g_req <= 1'b0;
        end
    endtask

    task automatic gs_rd(input integer line, output [63:0] d);
        integer k;
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
            g_req <= 1'b1;
            k = 0;
            @(posedge clk);
            k = k + 1;
            while (g_busy === 1'b1) begin
                @(posedge clk);
                k = k + 1;
                if (k > GS_BUDGET) tfail("gs_rd never accepted");
            end
            g_rd <= 1'b0;
            @(posedge clk);
            k = k + 1;
            while (g_dout_ready !== 1'b1) begin
                @(posedge clk);
                k = k + 1;
                if (k > GS_BUDGET) tfail("gs_rd no line back");
            end
            d     = g_dout;
            g_req <= 1'b0;
        end
    endtask

    task automatic gs_seed;
        integer k;
        begin
            for (k = 0; k < 512; k = k + 1) begin
                ref_g[k] = (k * 64'h9E37_79B9_7F4A_7C15) ^ 64'h5A5A;
                gs_wr(k, ref_g[k], 8'hFF);
            end
        end
    endtask

    task automatic gs_phase(input integer n_ops);
        integer k, ln;
        reg [7:0] be;
        reg [63:0] d, v;
        reg [7:0] b;
        begin
            for (k = 0; k < n_ops; k = k + 1) begin
                rnd_g = rnd_g * 32'd1664525 + 32'd1013904223;
                ln    = rnd_g % 512;
                if (ln < 0) ln = -ln;
                if (rnd_g[15]) begin
                    case (rnd_g[17:16])
                        0:       be = 8'hFF;
                        1:       be = 8'h01 << (rnd_g % 8);
                        2:       be = 8'hA5;
                        default: be = 8'h0F << (rnd_g % 4);
                    endcase
                    d = (k + 64'h4000) * 64'h9E37_79B9_7F4A_7C15;
                    gs_wr(ln, d, be);
                    for (b = 0; b < 8; b = b + 1)
                        if (be[b]) ref_g[ln][b*8 +: 8] = d[b*8 +: 8];
                end
                else begin
                    gs_rd(ln, d);
                    if (d !== ref_g[ln]) begin
                        if (shown < 8)
                            $display("FAIL gs line %0d got %016h want %016h",
                                     ln, d, ref_g[ln]);
                        shown  = shown + 1;
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    // ---------------- the run ----------------
    reg        rdy;
    reg [20:0] foff;

    localparam [1:0] KIND_TRD = 2'd0, KIND_CPM = 2'd1, KIND_FDI = 2'd2;

    initial begin : test
        @(posedge clk);
        reset <= 1'b1;
        repeat (10) @(posedge clk);
        @(posedge bclk);
        reset <= 1'b0;
        repeat (10) @(posedge clk);

        // ---------------- trd_track_exact ----------------
        case_start();
        fill_config(1'b0, KIND_TRD, 7'd80, 1'b1);
        fill_mem(0, 21'd0, 4096);                 // logical track 0: catalog
        fill_mem(0, 21'd45056, 4096);             // logical track 11: t5 s1
        fill_ready(1'b0);
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("trd t0s0: the ack says not ready");
        check_track("trd_track_exact t0s0", 0);
        req_track(1'b0, 1'b1, 7'd5, rdy);
        if (!rdy) bad("trd t5s1: the ack says not ready");
        check_track("trd_track_exact t5s1", 1);
        case_end("trd_track_exact");

        // ---------------- cpm_track_exact ----------------
        case_start();
        fill_config(1'b1, KIND_CPM, 7'd80, 1'b1);
        fill_mem(1, 21'd35840, 5120);             // logical track 7: t3 s1
        fill_ready(1'b1);
        req_track(1'b1, 1'b1, 7'd3, rdy);
        if (!rdy) bad("cpm t3s1: the ack says not ready");
        check_track("cpm_track_exact t3s1", 2);
        case_end("cpm_track_exact");

        // ---------------- fdi_track_exact ----------------
        case_start();
        fill_config(1'b0, KIND_FDI, 7'd80, 1'b1);
        fill_prog(0);                             // table + data of track 0/1
        fill_ready(1'b0);
        parse_fdi(0);
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("fdi t0s1: the ack says not ready");
        check_track("fdi_track_exact t0s1", 4);
        // the wide layout: 512 B sectors and a flags-0x40 sector
        fill_config(1'b0, KIND_FDI, 7'd80, 1'b1);
        fill_prog(1);
        fill_ready(1'b0);
        parse_fdi(1);
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("wide t0s0: the ack says not ready");
        check_track("fdi_track_exact wide t0s0", 5);
        case_end("fdi_track_exact");

        // ---------------- write_back ----------------
        case_start();
        fill_config(1'b0, KIND_TRD, 7'd80, 1'b1);
        fill_mem(0, 21'd16384, 4096);             // logical track 4: t2 s0
        fill_ready(1'b0);
        req_track(1'b0, 1'b0, 7'd2, rdy);
        if (!rdy) bad("write_back: t2s0 is not ready");
        // sector R=3, position 2: data at 2*388 + 70 = 846, file 16896
        wr_sector(1'b0, 1'b0, 7'd2, 8'd2, 8'd0, 8'd3, 3'd1, 256, 0, 8'd0);
        check_patch("write_back buffer", 13'd846, 256, 0, 8'd0);
        dd_expect("write_back ddr", 1'b0, 21'd16896, 256, 0, 8'd0);
        // one dirty block: bytes 16896..17151 live in block 33
        build_exp(0, 33, 21'd16896, 256, 0, 8'd0);
        expect_drain(1'b0, 11'd33, 1'b1);
        expect_no_drain("write_back: after the TRD block");
        // ---- a CP/M 1024 B write on drive B drains two blocks ----
        fill_config(1'b1, KIND_CPM, 7'd80, 1'b1);
        fill_mem(1, 21'd40960, 5120);             // logical track 8: t4 s0
        fill_ready(1'b1);
        req_track(1'b1, 1'b0, 7'd4, rdy);
        if (!rdy) bad("write_back cpm: t4s0 is not ready");
        // sector R=2, position 1: buffer 1156 + 70 = 1226, file 41984
        wr_sector(1'b1, 1'b0, 7'd4, 8'd4, 8'd0, 8'd2, 3'd3, 1024, 2, 8'h5C);
        check_patch("write_back cpm buffer", 13'd1226, 1024, 2, 8'h5C);
        dd_expect("write_back cpm ddr", 1'b1, 21'd41984, 1024, 2, 8'h5C);
        build_exp(1, 82, 21'd41984, 1024, 2, 8'h5C);
        expect_drain(1'b1, 11'd82, 1'b1);
        build_exp(1, 83, 21'd41984, 1024, 2, 8'h5C);
        expect_drain(1'b1, 11'd83, 1'b1);
        expect_no_drain("write_back: after the CP/M pair");
        case_end("write_back");

        // ---------------- fdi_write_volatile ----------------
        case_start();
        // re-mount the same FDI: the DDR data and the table survive a config
        fill_config(1'b0, KIND_FDI, 7'd80, 1'b1);
        fill_ready(1'b0);
        parse_fdi(0);
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("fdi_write: t0s1 is not ready");
        foff = fdi_file_off(8'd0, 8'd1, 8'd3, 3'd1);
        if (foff == 21'h1F_FFFF)
            tfail("fdi_write: no R=3 in the parsed table");
        wr_sector(1'b0, 1'b1, 7'd0, 8'd0, 8'd1, 8'd3, 3'd1, 256, 0, 8'd0);
        check_patch("fdi_write buffer", 13'd846, 256, 0, 8'd0);
        dd_expect("fdi_write ddr", 1'b0, foff, 256, 0, 8'd0);
        expect_no_drain("fdi_write_volatile: an FDI write never drains");
        case_end("fdi_write_volatile");

        // ---------------- request_while_filling ----------------
        case_start();
        fill_config(1'b0, KIND_TRD, 7'd80, 1'b1); // config, no bytes, no ready
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (rdy) bad("request_while_filling: ready before the image");
        fill_mem(0, 21'd0, 4096);             // the image bytes arrive
        fill_ready(1'b0);
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("request_while_filling: not ready after the image");
        check_track("request_while_filling t0s0", 0);
        case_end("request_while_filling");

        // ---------------- gs_traffic_during_build ----------------
        case_start();
        gs_seed();
        fork
            begin
                gs_phase(500);
            end
            begin
                req_track(1'b0, 1'b1, 7'd5, rdy);
                if (!rdy) bad("gs_traffic: t5s1 is not ready");
                check_track("gs_traffic t5s1", 1);
                req_track(1'b0, 1'b0, 7'd0, rdy);
                if (!rdy) bad("gs_traffic: t0s0 is not ready");
                check_track("gs_traffic t0s0", 0);
            end
        join
        case_end("gs_traffic_during_build");

        // ---------------- eject_mid_fill ----------------
        case_start();
        // A still holds the TRD image and t0s0's position table
        wr_sector(1'b0, 1'b0, 7'd0, 8'd0, 8'd0, 8'd3, 3'd1, 256, 0, 8'd0);
        wait_drain_toggle;                         // block 1 is out, unacked
        fill_config(1'b0, KIND_TRD, 7'd80, 1'b1); // eject mid drain
        fill_mem(0, 21'd0, 1024);                 // ... and mid fill
        drain_host_ack;                            // the host finishes anyway
        fill_mem(0, 21'd1024, 3072);
        fill_ready(1'b0);
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("eject_mid_fill: no ack after the remount");
        check_track("eject_mid_fill t0s0", 0);
        expect_no_drain("eject_mid_fill: the dropped block re-armed");
        // the dirty path still works after the eject
        wr_sector(1'b0, 1'b0, 7'd0, 8'd0, 8'd0, 8'd5, 3'd1, 256, 0, 8'd0);
        expect_drain(1'b0, 11'd2, 1'b0);
        expect_no_drain("eject_mid_fill: after the next block");
        case_end("eject_mid_fill");

        // ---------------- remount_mid_drain ----------------
        case_start();
        // B still holds CP/M t4s0; patch it, two blocks go dirty
        wr_sector(1'b1, 1'b0, 7'd4, 8'd4, 8'd0, 8'd2, 3'd3, 1024, 1, 8'd0);
        wait_drain_toggle;                         // block 82 out, 83 queued
        fill_config(1'b1, KIND_CPM, 7'd80, 1'b1); // remount mid drain
        drain_host_ack;                            // the host acks the drop
        expect_no_drain("remount_mid_drain: the queue survived");
        fill_mem(1, 21'd40960, 5120);              // refill: DDR holds the patch
        fill_ready(1'b1);
        req_track(1'b1, 1'b0, 7'd4, rdy);
        if (!rdy) bad("remount_mid_drain: t4s0 is not ready");
        check_track("remount_mid_drain t4s0", 3);
        // and again: the same write drains two fresh blocks
        wr_sector(1'b1, 1'b0, 7'd4, 8'd4, 8'd0, 8'd2, 3'd3, 1024, 1, 8'd0);
        expect_drain(1'b1, 11'd82, 1'b0);
        expect_drain(1'b1, 11'd83, 1'b0);
        expect_no_drain("remount_mid_drain: a third block");
        case_end("remount_mid_drain");

        // ---------------- verdict ----------------
        $display("tb_fdd_img: %0d errors", errors);
        if (errors == 0) $display("tb_fdd_img: PASS");
        else             $display("tb_fdd_img: FAIL %0d checks failed", errors);
        $finish;
    end : test

endmodule

`default_nettype wire
