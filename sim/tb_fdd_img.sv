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
// PART B (the second half of Task 4) adds rtl/disk/fdd_src.sv and
// sim/models/hps_disk_model.sv: the same store, now fed by the module that
// owns hps_io's disk slots, the ioctl download and the OSD geometry bits.
// `host_en` holds fdd_src in reset for every case above and the mux at its
// instance switches the store's fill and drain ports over once (it never
// flips back), so Part A keeps its exact behaviour. fdd_src runs on bclk:
// the store samples the fill and drain toggles through its own
// synchronisers, and bclk is the clock its drain buffer's far side (the
// module's clk_sys) stands for here. The new cases:
//   geometry_auto         the size -> geometry table: 655360 TRD-80, 819200
//                         CP/M-80 (100 tracks do not fit TRD), 409600 TRD-50,
//                         10240 CP/M-1, 688128 TRD-84, 12345 no image.
//   geometry_override     status[35:34]: 2 forces CP/M (409600 -> 40), 1
//                         forces TRD (819200 -> no image), 3 behaves as auto.
//   mount_order           the whole fill stream of a mount: the config first,
//                         then image bytes 0..size-1 in order, every byte the
//                         model's own byte, one sd_rd per sector, ready last.
//   trd_via_host          a TRD image filled through the hps path: track 0/1
//                         equals reffrom byte for byte, sync flags included.
//   readonly              img_readonly at mount: wprt high, the fill works,
//                         and a dirty block the store presents is never
//                         written back; a writable mount is.
//   write_drain_to_host   a 256 B write across two blocks lands in the hps
//                         image at each block's LBA, byte for byte.
//   fdi_download          an FDI through ioctl index 1 (drive A) and 2 (drive
//                         B), the wide layout, a one-side image, and index 0
//                         left alone; a truncated, bad-magic or over-cylinder
//                         header sends no config and no ready, and the drive
//                         keeps the image it had.
//   eject_mid_fill_host   a mount with size 0 during a fill: the config says
//                         empty, no ready goes out, the next request is not
//                         ready, and the following mount fills exact.
//   remount_mid_drain_host  a new mount of the drive while its drain block is
//                         being copied: the block is dropped (those bytes
//                         belong to the image that is gone), the new image
//                         fills and builds exact.
//
// Every wait is bounded by an edge count, never by a $time difference, and
// the last line printed is `tb_fdd_img: PASS` or `tb_fdd_img: FAIL <reason>`;
// run via sim/run_tb_fdd_img.sh (iverilog -g2012).
`timescale 1ns / 1ps

module tb_fdd_img;

    // ---------------- clocks ----------------
    reg clk  = 1'b0;                 // gs_clk 28.125 MHz: the store's clock
    always #17.7775 clk  = ~clk;
    reg bclk = 1'b0;                 // the bus clock: the drive model, Part A's
    always #20 bclk = ~bclk;         // fill and drain host - and clk_sys, the
                                     // clock of fdd_src and hps_disk_model

    // edge-count budgets (never $time arithmetic)
    localparam integer FILL_BUDGET  = 400_000;  // a fill byte across ack
    localparam integer REQ_BUDGET   = 400_000;  // a track request across ack
    localparam integer WR_BUDGET    = 400_000;  // a written sector across ack
    localparam integer DN_BUDGET    = 400_000;  // a drain block across toggle
    localparam integer WATCH_BUDGET = 100_000;  // clocks of watched silence
    localparam integer GS_BUDGET    = 20_000;   // a GS transaction

    localparam integer WATCHDOG = 60_000_000;   // gs clocks for the whole run

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

    // the store's host side: Part A's own drivers until `host_en`, then
    // fdd_src's (the mux assigns below, next to its instance)
    reg host_en = 1'b0;
    wire        st_fill_tgl;
    wire [31:0] st_fill_word;
    wire        st_drn_ack_tgl;
    wire [8:0]  st_drn_addr_b;

    fdd_store dut (
        .clk(clk), .reset(reset), .clk_bus(bclk), .clk_sys(bclk),
        .f_req(f_req), .f_addr(f_addr), .f_din(f_din), .f_be(f_be),
        .f_rd(f_rd), .f_we(f_we),
        .f_busy(f_busy), .f_dout(f_dout), .f_dout_ready(f_dout_ready),
        .fill_tgl(st_fill_tgl), .fill_word(st_fill_word),
        .fill_ack_tgl(fill_ack_tgl),
        .trk_req_tgl(trk_req_tgl), .trk_req(trk_req),
        .trk_ack_tgl(trk_ack_tgl), .trk_ack(trk_ack),
        .trk_addr_b(trk_addr_b), .trk_q_b(trk_q_b),
        .wr_addr(wr_addr), .wr_data(wr_data), .wr_we(wr_we),
        .wr_info(wr_info), .wr_tgl(wr_tgl), .wr_ack_tgl(wr_ack_tgl),
        .drn_addr_b(st_drn_addr_b), .drn_q_b(drn_q_b),
        .drn_tgl(drn_tgl), .drn_info(drn_info),
        .drn_ack_tgl(st_drn_ack_tgl)
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

    reg         lrq_valid = 1'b0;               // the last track request's
    reg         lrq_d     = 1'b0;               // drive, for the interrupt
    reg [8:0]   lrq_req   = 9'd0;               // echo the store replays

    task automatic fill_config(input d, input [1:0] kind,
                               input [6:0] tracks, input sides);
        integer k;
        reg seen;
        begin
            fill_send({2'd0, d, kind, tracks, sides, 19'd0});
            // A remount of the drive that streams interrupts it: the store
            // answers an unsolicited not-ready with the last echo (ruling
            // I3). It lands two clocks after the fill ack when the store
            // was idle; a config that kills a build answers earlier still,
            // and no second one follows.
            if (lrq_valid && lrq_d == d) begin
                seen = trk_ack_tgl;
                k = 0;
                @(posedge bclk);
                while (trk_ack_tgl === seen && k < 32) begin
                    @(posedge bclk);
                    k = k + 1;
                end
            end
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
            lrq_valid  = 1'b1;
            lrq_d      = d;
            lrq_req    = {d, s, t};
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

    // a request whose ack is collected later, and a bare wait for one ack
    task automatic req_nowait(input d, input s, input [6:0] t);
        begin
            @(posedge bclk);
            trk_req     <= {d, s, t};
            trk_req_tgl <= ~trk_req_tgl;
            lrq_valid   = 1'b1;
            lrq_d       = d;
            lrq_req     = {d, s, t};
        end
    endtask

    task automatic ack_wait(input [8*40-1:0] who,
                            input d, input s, input [6:0] t,
                            output rdy);
        integer k;
        reg seen;
        begin
            seen = trk_ack_tgl;
            k    = 0;
            @(posedge bclk);
            while (trk_ack_tgl === seen) begin
                @(posedge bclk);
                k = k + 1;
                if (k > REQ_BUDGET) tfail("a track request was never acked");
            end
            rdy = trk_ack[9];
            if (trk_ack[8:0] !== {d, s, t}) begin
                $display("FAIL %0s: ack echo %03o is not the request %03o",
                         who, trk_ack[8:0], {d, s, t});
                errors = errors + 1;
            end
        end
    endtask

    // a sector write whose ack is collected later
    reg wr_seen;
    task automatic wr_issue(input d, input s, input [6:0] t,
                            input [7:0] C, H, R, input [2:0] N,
                            input integer len, input integer kind,
                            input [7:0] c);
        integer k;
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
            wr_info    <= {d, s, t, C, H, R, N};
            wr_tgl     <= ~wr_tgl;
            wr_seen    = wr_ack_tgl;
        end
    endtask

    // the scheduler's race: the write and the request toggle on the very
    // same bclk edge, so one IDLE visit must serve the write first
    task automatic wr_race_req(input d, input s, input [6:0] t,
                               input [7:0] C, H, R, input [2:0] N,
                               input integer len, input integer kind,
                               input [7:0] c,
                               input rd, input rs, input [6:0] rt);
        integer k;
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
            wr_info     <= {d, s, t, C, H, R, N};
            wr_tgl      <= ~wr_tgl;
            wr_seen     = wr_ack_tgl;
            trk_req     <= {rd, rs, rt};
            trk_req_tgl <= ~trk_req_tgl;
            lrq_valid   = 1'b1;
            lrq_d       = rd;
            lrq_req     = {rd, rs, rt};
        end
    endtask

    task automatic wr_expect(input [8*40-1:0] who);
        integer k;
        begin
            k = 0;
            @(posedge bclk);
            while (wr_ack_tgl === wr_seen) begin
                @(posedge bclk);
                k = k + 1;
                if (k > WR_BUDGET) tfail("a written sector was never acked");
            end
        end
    endtask

    reg fa_seen;

    // the remount's race: the config toggles on the very edge the request
    // does, so it lands while the store is already in the builder
    task automatic req_race_config(input d, input s, input [6:0] t);
        begin
            fa_seen = fill_ack_tgl;
            @(posedge bclk);
            trk_req     <= {d, s, t};
            trk_req_tgl <= ~trk_req_tgl;
            fill_word   <= {2'd0, d, 2'd0, 7'd80, 1'b1, 19'd0};
            fill_tgl    <= ~fill_tgl;
            lrq_valid   = 1'b1;
            lrq_d       = d;
            lrq_req     = {d, s, t};
        end
    endtask

    // one raw image byte (a forged FDI block writes its own table bytes)
    task automatic fill_raw(input [21:0] a, input [7:0] v);
        begin
            fill_send({2'd1, a, v});
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
    integer dn_seen = 0;                        // presentations counted
    integer dnq_n   = 0;                        // presentations consumed
    reg     dn_armed = 1'b0;                    // armed on reset release:
                                                // the X to 0 of the output
    integer dnq_drv [0:63];                     // is not a presentation
    integer dnq_blk [0:63];

    always @(negedge reset) dn_armed = 1'b1;
    always @(drn_tgl) if (dn_armed) begin
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

    // ==================== PART B: fdd_src as the host ====================
    // hps_io's disk slots (sim/models/hps_disk_model.sv), the ioctl download
    // and the OSD status word drive rtl/disk/fdd_src.sv, and that module
    // drives the store's fill and drain ports in place of the tasks above.
    // The four st_* wires are the mux; host_en switches it once, at the first
    // host case, and holds the module in reset until then.
    wire        hs_fill_tgl;
    wire [31:0] hs_fill_word;
    wire        hs_drn_ack_tgl;
    wire [8:0]  hs_drn_addr_b;

    wire       hs_rst = reset | ~host_en;

    reg  [1:0]   hs_mounted = 2'b00;
    reg  [63:0]  hs_size    = 64'd0;
    reg          hs_ro      = 1'b0;
    reg  [127:0] hs_status  = 128'd0;

    wire [1:0]   hs_sd_rd, hs_sd_wr, hs_sd_ack;
    wire [31:0]  hs_sd_lba;
    wire [8:0]   hs_buff_addr;
    wire [7:0]   hs_buff_dout, hs_buff_din;
    wire         hs_buff_wr;
    wire [1:0]   hs_wprt, hs_past_end;

    reg          io_download = 1'b0;
    reg  [15:0]  io_index    = 16'd0;
    reg          io_wr       = 1'b0;
    reg  [7:0]   io_dout     = 8'd0;
    wire         io_wait;

    assign st_fill_tgl    = host_en ? hs_fill_tgl    : fill_tgl;
    assign st_fill_word   = host_en ? hs_fill_word   : fill_word;
    assign st_drn_ack_tgl = host_en ? hs_drn_ack_tgl : drn_ack_tgl;
    assign st_drn_addr_b  = host_en ? hs_drn_addr_b  : drn_addr_b;

    hps_disk_model #(.LAT_CLKS(10)) hps (
        .clk(bclk), .img_size(hs_size),
        .rd(hs_sd_rd), .wr(hs_sd_wr),
        .lba_a(hs_sd_lba), .lba_b(hs_sd_lba),
        .ack(hs_sd_ack),
        .buff_addr(hs_buff_addr), .buff_dout(hs_buff_dout),
        .buff_wr(hs_buff_wr), .buff_din(hs_buff_din),
        .past_end(hs_past_end)
    );

    fdd_src src (
        .clk_sys(bclk), .reset_sys(hs_rst),
        .img_mounted(hs_mounted), .img_size(hs_size),
        .img_readonly(hs_ro),
        .sd_rd(hs_sd_rd), .sd_wr(hs_sd_wr), .sd_lba(hs_sd_lba),
        .sd_ack(hs_sd_ack),
        .sd_buff_addr(hs_buff_addr), .sd_buff_dout(hs_buff_dout),
        .sd_buff_din(hs_buff_din), .sd_buff_wr(hs_buff_wr),
        .status(hs_status),
        .ioctl_download(io_download), .ioctl_index(io_index),
        .ioctl_wr(io_wr), .ioctl_addr(27'd0), .ioctl_dout(io_dout),
        .ioctl_wait(io_wait),
        .wprt(hs_wprt),
        .fill_tgl(hs_fill_tgl), .fill_word(hs_fill_word),
        .fill_ack_tgl(fill_ack_tgl),
        .drn_addr_b(hs_drn_addr_b), .drn_q_b(drn_q_b),
        .drn_tgl(drn_tgl), .drn_info(drn_info),
        .drn_ack_tgl(hs_drn_ack_tgl)
    );


    // the two files of the hps slots: slot a holds drive A's, slot b drive
    // B's. himg/hpmg keep the original bytes while hps.mem is what a drive
    // writes, so a write-back that should not have happened stays visible.
    reg [7:0] himg [0:16383];
    reg [7:0] hpmg [0:16383];

    // ---------------- what fdd_src sends the store ----------------
    integer mon_on = 0;
    integer mon_n = 0, mon_cfg = 0, mon_rdy = 0, mon_cfg_at = -1;
    integer mon_bytes = 0, mon_seqbad = 0, mon_databad = 0;
    integer mon_maxa = -1, mon_seq = 0;
    integer mon_memchk = -1;                 // hps slot the bytes must match
    integer mon_sdrd = 0, mon_sdwr = 0, mon_drn = 0;
    integer mon_tgl = 0;                     // every host fill toggle
    integer mon_dlm = 0;                     // bytes must match the downloaded
    integer mon_dlbase = 0;                  // file, from its data area on
    integer mon_badaddr = -1;                // the first byte that lied
    reg [31:0] mon_cfgw = 32'd0;

    task automatic mon_reset;
        begin
            mon_n = 0; mon_cfg = 0; mon_rdy = 0; mon_cfg_at = -1;
            mon_bytes = 0; mon_seqbad = 0; mon_databad = 0;
            mon_maxa = -1; mon_seq = 0; mon_memchk = -1;
            mon_sdrd = 0; mon_sdwr = 0; mon_drn = 0; mon_cfgw = 32'd0;
            mon_dlm = 0; mon_dlbase = 0; mon_badaddr = -1;
        end
    endtask

    // A case of Part B opens its counters only after the stream of the
    // previous case has stopped: a mount preempts an in-flight fill at the
    // next sector boundary, so the old geometry's last words arrive within a
    // few thousand clocks, and a case that started counting before that would
    // count the previous image's bytes as its own.
    task automatic host_case_start;
        integer k, n0;
        begin
            mon_on = 0;
            n0 = mon_tgl;
            k  = 0;
            while (k < 3000) begin
                @(posedge bclk);
                if (mon_tgl != n0) begin
                    n0 = mon_tgl;
                    k  = 0;
                end
                else
                    k = k + 1;
            end
            hps.past_end = 2'b00;             // sticky inside the model
            // and each case owns a pristine pair of images: the write-backs
            // of an earlier case must not be read as this case's own bytes
            for (k = 0; k < 16384; k = k + 1) hps.mem[0][k] = himg[k];
            for (k = 0; k < 10240; k = k + 1) hps.mem[1][k] = hpmg[k];
            case_start();
            mon_reset();
            mon_on = 1;
        end
    endtask

    // What fdd_src pushes the store. The line is a toggle and not a pulse
    // (the store watches it for any change), so the monitor watches any change
    // as well; the word changes in the same clock as its toggle, which is why
    // the sample is taken one delta after it.
    always @(hs_fill_tgl) begin
        #1;
        if (mon_on) begin
            if (hs_fill_word[31:30] == 2'd0) begin
                mon_cfg  = mon_cfg + 1;
                mon_cfgw = hs_fill_word;
                if (mon_cfg_at < 0) mon_cfg_at = mon_n;
            end
            else if (hs_fill_word[31:30] == 2'd2)
                mon_rdy = mon_rdy + 1;
            else if (!hs_fill_word[29]) begin          // an image byte
                mon_bytes = mon_bytes + 1;
                if (hs_fill_word[29:8] !== mon_seq[21:0])
                    mon_seqbad = mon_seqbad + 1;
                mon_seq  = hs_fill_word[29:8] + 1;
                mon_maxa = hs_fill_word[29:8];
                if ((mon_memchk >= 0 &&
                     hps.mem[mon_memchk][hs_fill_word[29:8]] !==
                                                        hs_fill_word[7:0]) ||
                    (mon_dlm != 0 &&
                     dl_mem[mon_dlbase + hs_fill_word[29:8]] !==
                                                        hs_fill_word[7:0])) begin
                    mon_databad = mon_databad + 1;
                    if (mon_badaddr < 0) mon_badaddr = hs_fill_word[29:8];
                end
            end
            mon_n = mon_n + 1;
        end
    end

    always @(hs_fill_tgl) mon_tgl = mon_tgl + 1;
    always @(drn_tgl) if (mon_on) mon_drn = mon_drn + 1;

    always @(posedge hs_sd_rd[0] or posedge hs_sd_rd[1])
        if (mon_on) mon_sdrd = mon_sdrd + 1;
    always @(posedge hs_sd_wr[0] or posedge hs_sd_wr[1])
        if (mon_on) mon_sdwr = mon_sdwr + 1;

    // ---------------- the host's driving tasks ----------------
    // Main's order, as tb_img_src has it: `0x1c` raises img_mounted for one
    // clk and the `0x1d` size words follow inside the same burst, so a size
    // sampled on the pulse is the previous image's (0 at the first mount).
    // Every signal of the burst is driven with a nonblocking assignment: a
    // blocking write at the clock edge leaves the module reading the new port
    // value together with the previous value of anything derived from it
    // (mount_ev is img_mounted & ~old_mounted), so the mount edge is missed -
    // which is what blocking writes here did.
    task automatic host_mount(input [1:0] bits, input [63:0] size, input ro);
        begin
            hs_ro      <= ro;
            @(posedge bclk);
            hs_mounted <= bits;
            @(posedge bclk);
            hs_mounted <= 2'b00;
            repeat (3) @(posedge bclk);
            hs_size    <= size;
            repeat (3) @(posedge bclk);
        end
    endtask

    localparam integer MNT_BUDGET = 60_000;    // bclk for one mount settle
    localparam integer FILL_ALL   = 4_000_000; // bclk for a whole image fill

    task automatic wait_cfg(input [8*40-1:0] who, output [31:0] w);
        integer k, n0;
        begin
            n0 = mon_cfg;
            k  = 0;
            while (mon_cfg == n0 && k < MNT_BUDGET) begin
                @(posedge bclk);
                k = k + 1;
            end
            if (mon_cfg == n0) begin
                $display("FAIL %0s: no fill config after the mount", who);
                // a mount that never crosses is the hardest thing here to
                // read off the bus, so dump the module's own state with it
                $display("  rst=%b reset=%b mon=%b im=%b old=%b ev=%b pend=%b mnt=%b/%b st=%0d act=%b jb=%d settle=%0d age=%d sc=%b lba=%08x ack=%b size=%0d",
                         hs_rst, reset, mon_on, hs_mounted, src.old_mounted,
                         src.ev_pend, src.chg_pend,
                         {src.mnt_lvl[1], src.mnt_lvl[0]},
                         {src.mnt_valid[1], src.mnt_valid[0]},
                         src.st, src.fl_act, src.jb, src.settle, src.ev_age,
                         src.size_chg, hs_sd_lba, hs_sd_ack, hs_size);
                errors = errors + 1;
            end
            else
                w = mon_cfgw;
        end
    endtask

    task automatic wait_rdy(input [8*40-1:0] who);
        integer k, n0;
        begin
            n0 = mon_rdy;
            k  = 0;
            while (mon_rdy == n0 && k < FILL_ALL) begin
                @(posedge bclk);
                k = k + 1;
            end
            if (mon_rdy == n0) tfail("a host fill never sent ready");
        end
    endtask

    // n clocks of watched silence: a config or a ready that comes is a
    // failure of the case's premise, reported once
    task automatic quiet(input [8*56-1:0] why, input want_cfg, input want_rdy,
                         input integer n);
        integer k, c0, r0;
        reg report_c, report_r;
        begin
            c0 = mon_cfg; r0 = mon_rdy;
            report_c = want_cfg; report_r = want_rdy;
            for (k = 0; k < n; k = k + 1) begin
                @(posedge bclk);
                if (mon_cfg != c0 && report_c) begin
                    if (shown < 8)
                        $display("FAIL %0s: a fill config came anyway", why);
                    shown  = shown + 1;
                    errors = errors + 1;
                    report_c = 0;
                end
                if (mon_rdy != r0 && report_r) begin
                    if (shown < 8)
                        $display("FAIL %0s: a ready came anyway", why);
                    shown  = shown + 1;
                    errors = errors + 1;
                    report_r = 0;
                end
            end
        end
    endtask

    task automatic wait_push(input integer n);
        integer k;
        begin
            k = 0;
            while (mon_bytes < n && k < FILL_ALL) begin
                @(posedge bclk);
                k = k + 1;
            end
            if (mon_bytes < n) tfail("a host fill stopped early");
        end
    endtask

    // ---------------- the ioctl source ----------------
    reg [7:0] dl_mem [0:65535];
    integer   dl_n = 0;

    task automatic dl_load(input integer which);
        integer k;
        begin
            for (k = 0; k < 65536; k = k + 1) dl_mem[k] = 8'hxx;
            case (which)
                0: $readmemh("build/sim/fdd_img/dl.hex",    dl_mem);
                1: $readmemh("build/sim/fdd_img/dlw.hex",   dl_mem);
                2: $readmemh("build/sim/fdd_img/dl1.hex",   dl_mem);
                3: $readmemh("build/sim/fdd_img/dlcut.hex", dl_mem);
                4: $readmemh("build/sim/fdd_img/dlbad.hex", dl_mem);
                default: $readmemh("build/sim/fdd_img/dlbig.hex", dl_mem);
            endcase
            dl_n = 0;
            while (dl_n < 65536 && dl_mem[dl_n] !== 8'hxx)
                dl_n = dl_n + 1;
            if (dl_n == 0) tfail("a download fixture is empty");
            // every image byte the download pushes must be the file's own
            // byte at the same place of its data area
            mon_dlm    = 1;
            mon_dlbase = {dl_mem[11], dl_mem[10]};
        end
    endtask

    // hps_io's source side: a byte is presented for one clk_sys on a clock
    // where the core's ioctl_wait is down, which is the core's own promise
    // that it takes the byte there and then. `mode` is the case's premise:
    //   1 - the window is claimed: the wait rises for it within eight clocks
    //       of the window opening (a core that ignores the window and then
    //       fills the drive with something else fails here), and it is down
    //       again when the window closes
    //   0 - the file must never be claimed (index 0 is boot.rom's): the wait
    //       stays low for the whole window
    //   2 - claimed, then let go (a header that aborts): the wait may rise
    //       while the header streams and must fall by the end
    // Driven nonblocking, as the mount burst is: the module must sample a
    // settled value of every input.
    task automatic host_download(input [15:0] index, input integer mode);
        integer k, w, lost;
        reg seen, saw;
        begin
            saw  = 1'b0;
            lost = 0;
            // Drives and samples both sit 1 ns off the clock edge: what the
            // module samples is then what it will see, and a wait read after an
            // edge is the one the module raised on it.
            @(posedge bclk);
            #1;
            io_index    = index;
            io_download = 1'b1;

            // the claim, before a single byte is strobed
            w    = 0;
            seen = 1'b0;
            while (w < 8 && !seen) begin
                @(posedge bclk);
                #1;
                seen = (io_wait === 1'b1);
                w    = w + 1;
            end
            if (mode == 0 && seen) begin
                $display("FAIL ioctl index %0d was claimed after all", index);
                errors = errors + 1;
            end
            if (mode == 1 && !seen) begin
                $display("FAIL index %0d: the window was never claimed", index);
                errors = errors + 1;
            end

            // hps_io's source contract (sys/hps_io.sv: ioctl_wr is a one-clock
            // strobe that carries the byte, and hps_io itself never consults
            // the wait): the source stops on the wait between bytes, strobes
            // every byte for exactly one clock, and holds nothing back. A core
            // that lets a strobe pass without taking it loses the byte, and the
            // check below catches that - a core that took a byte holds its wait
            // up on the strobe clock.
            for (k = 0; k < dl_n; k = k + 1) begin
                w = 0;
                while ((io_wait === 1'b1) && w < FILL_BUDGET) begin
                    @(posedge bclk);
                    #1;
                    w = w + 1;
                end
                if (w >= FILL_BUDGET) tfail("the ioctl wait never fell");
                io_dout = dl_mem[k];
                io_wr   = 1'b1;
                @(posedge bclk);            // the strobe is sampled on this
                #1;
                io_wr   = 1'b0;             // clock, and it carries the byte
                seen    = (io_wait === 1'b1);
                saw     = saw || seen;
                if (!seen && mode == 1) begin
                    if (lost == 0)
                        $display("FAIL index %0d: byte %0d was never taken",
                                 index, k);
                    lost = lost + 1;
                end
            end
            io_wr = 1'b0;
            if (mode == 0 && saw) begin
                $display("FAIL index %0d was claimed after all", index);
                errors = errors + 1;
            end
            if (mode == 1 && lost != 0) begin
                $display("FAIL index %0d: %0d bytes were never taken",
                         index, lost);
                errors = errors + 1;
            end
            // hps_io ends a download by lowering ioctl_download; the core is
            // allowed to use the window for its last bytes, so the release is
            // waited for instead of assumed.
            io_download = 1'b0;
            if (mode != 0) begin
                w = 0;
                while ((io_wait === 1'b1) && w < 400) begin
                    @(posedge bclk);
                    #1;
                    w = w + 1;
                end
                if (io_wait === 1'b1) begin
                    $display("FAIL index %0d: the window was never given back",
                             index);
                    errors = errors + 1;
                end
            end
            #1;
        end
    endtask

    // ---------------- the reference tracks of Part B ----------------
    reg [7:0] ref_bh [0:TRKN-1];
    reg       syc_bh [0:TRKN-1];

    task automatic ref_load(input integer which);
        begin
            case (which)
                0: begin
                    $readmemh("build/sim/fdd_img/ref_trdh_t0s0",      ref_bh);
                    $readmemh("build/sim/fdd_img/ref_trdh_t0s0.sync",  syc_bh);
                end
                1: begin
                    $readmemh("build/sim/fdd_img/ref_trdh_t0s1",      ref_bh);
                    $readmemh("build/sim/fdd_img/ref_trdh_t0s1.sync",  syc_bh);
                end
                2: begin
                    $readmemh("build/sim/fdd_img/ref_cpmh_t0s0",      ref_bh);
                    $readmemh("build/sim/fdd_img/ref_cpmh_t0s0.sync",  syc_bh);
                end
                3: begin
                    $readmemh("build/sim/fdd_img/ref_dl_t0s1",        ref_bh);
                    $readmemh("build/sim/fdd_img/ref_dl_t0s1.sync",    syc_bh);
                end
                4: begin
                    $readmemh("build/sim/fdd_img/ref_dlw_t0s0",       ref_bh);
                    $readmemh("build/sim/fdd_img/ref_dlw_t0s0.sync",   syc_bh);
                end
                default: begin
                    $readmemh("build/sim/fdd_img/ref_dl1_t1s0",       ref_bh);
                    $readmemh("build/sim/fdd_img/ref_dl1_t1s0.sync",   syc_bh);
                end
            endcase
        end
    endtask

    task automatic check_bh(input [8*40-1:0] who);
        integer a, stop;
        begin
            stop = 0;
            for (a = 0; (a < TRKN) && !stop; a = a + 1) begin
                @(posedge bclk);
                trk_addr_b <= a[12:0];
                @(posedge bclk);
                @(posedge bclk);
                if (trk_q_b[7:0] !== ref_bh[a] || trk_q_b[8] !== syc_bh[a]) begin
                    if (shown < 8)
                        $display("FAIL %0s track[%0d] got {%b,%02x} want {%b,%02x}",
                                 who, a, trk_q_b[8], trk_q_b[7:0],
                                 syc_bh[a], ref_bh[a]);
                    shown  = shown + 1;
                    errors = errors + 1;
                    stop   = 1;
                end
            end
        end
    endtask

    // the config word a mount or a download is expected to send
    task automatic expect_cfg(input [8*40-1:0] who, input d, input [1:0] kind,
                              input [6:0] tracks, input sides);
        reg [31:0] w;
        begin
            wait_cfg(who, w);
            if (w !== {2'd0, d, kind, tracks, sides, 19'd0}) begin
                $display("FAIL %0s: config %08x is not {%0d,%0d,%0d,%0d}",
                         who, w, d, kind, tracks, sides);
                errors = errors + 1;
            end
        end
    endtask

    // n clocks without a single write-back request
    task automatic quiet_writes(input [8*56-1:0] why, input integer n);
        integer k, w0;
        begin
            w0 = mon_sdwr;
            k  = 0;
            while (k < n) begin
                @(posedge bclk);
                k = k + 1;
                if (mon_sdwr != w0) begin
                    $display("FAIL %0s: a dirty block was written back", why);
                    errors = errors + 1;
                    k = n;
                end
            end
        end
    endtask

    // The host takes a moment to answer, and then copies the block byte by
    // byte: its bytes only exist in the file once that burst has ended, so a
    // case that reads them back waits for the interface to fall idle again,
    // not for the request's pulse.
    task automatic wait_write_done(input [8*40-1:0] why);
        integer k;
        begin
            k = 0;
            while (!((hps.ack[0] === 1'b1) || (hps.ack[1] === 1'b1)) &&
                   k < FILL_ALL) begin
                @(posedge bclk);
                k = k + 1;
            end
            if (k >= FILL_ALL) begin
                $display("FAIL %0s: the host never answered the write-back", why);
                errors = errors + 1;
            end
            k = 0;
            while (!(hps.ack == 2'b00) && k < FILL_ALL) begin
                @(posedge bclk);
                k = k + 1;
            end
            if (k >= FILL_ALL) begin
                $display("FAIL %0s: the write-back never ended", why);
                errors = errors + 1;
            end
            repeat (4) @(posedge bclk);
        end
    endtask

    // ---------------- the run ----------------
    reg        rdy;
    reg [20:0] foff;
    integer drn0, wr0;                  // a drain count, an sd_wr count
    integer e0;                         // an expected byte
    reg [31:0] hw;                      // a config word as it arrived

    localparam [1:0] KIND_TRD = 2'd0, KIND_CPM = 2'd1, KIND_FDI = 2'd2;

    initial begin : test
        integer k, r, b, i;
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

        // ---------------- bounds_not_ready ----------------
        // a 40 track single sided mount: the store answers out of range
        // requests with a not-ready, the last legal one stays ready
        case_start();
        fill_config(1'b0, KIND_TRD, 7'd40, 1'b0);
        fill_ready(1'b0);
        req_track(1'b0, 1'b0, 7'd40, rdy);
        if (rdy) bad("bounds: track 40 of a 40 track mount is ready");
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (rdy) bad("bounds: side 1 of a single sided mount is ready");
        req_track(1'b0, 1'b0, 7'd39, rdy);
        if (!rdy) bad("bounds: track 39 of 40 must be ready");
        case_end("bounds_not_ready");

        // ---------------- redirty_during_drain ----------------
        // the block picked for drain is written again before its ack: it
        // must be drained a second time carrying both writes
        case_start();
        fill_config(1'b0, KIND_TRD, 7'd80, 1'b1);
        fill_mem(0, 21'd0, 4096);
        fill_ready(1'b0);
        req_track(1'b0, 1'b0, 7'd0, rdy);
        wr_sector(1'b0, 1'b0, 7'd0, 8'd0, 8'd0, 8'd3, 3'd1, 256, 0, 8'd0);
        wait_drain_toggle;                          // block 1 picked, no ack
        wr_sector(1'b0, 1'b0, 7'd0, 8'd0, 8'd0, 8'd4, 3'd1, 256, 2, 8'h5C);
        // the first drain may mix: only its identity and ack matter
        expect_drain(1'b0, 11'd1, 1'b0);
        build_exp(0, 1, 21'd512, 256, 0, 8'd0);     // R3: A0^j at 512..767
        for (k = 256; k < 512; k = k + 1)           // R4: 5C+j at 768..1023
            exp_blk[k] = pat(2, k - 256, 8'h5C);
        expect_drain(1'b0, 11'd1, 1'b1);            // the re-dirty drains
        expect_no_drain("redirty: a third drain of block 1");
        case_end("redirty_during_drain");

        // ---------------- remount_aborts_build ----------------
        // a config that lands during a build of the same drive answers the
        // waiting request with a not-ready and leaves the drive unready
        case_start();
        fill_config(1'b0, KIND_TRD, 7'd80, 1'b1);
        fill_mem(0, 21'd0, 4096);
        fill_ready(1'b0);
        req_race_config(1'b0, 1'b0, 7'd0);          // the config toggles on
        k = 0;                                      // the request's own edge
        @(posedge bclk);
        while (fill_ack_tgl === fa_seen) begin
            @(posedge bclk);
            k = k + 1;
            if (k > FILL_BUDGET) tfail("the racing config was never acked");
        end
        ack_wait("abort", 1'b0, 1'b0, 7'd0, rdy);   // the kill's not-ready
        if (rdy) bad("abort: the kill must ack the old request not-ready");
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (rdy) bad("abort: still ready right after the remount");
        fill_mem(0, 21'd0, 4096);
        fill_ready(1'b0);
        req_track(1'b0, 1'b0, 7'd0, rdy);           // state survived
        if (!rdy) bad("abort: the remounted drive never streamed");
        check_track("abort: rebuilt after the abort", 0);
        case_end("remount_aborts_build");

        // ---------------- write_and_request ----------------
        // a write and a new request pending together: the write must keep
        // the position table it was asked for, not the requested track's
        case_start();
        req_track(1'b0, 1'b1, 7'd5, rdy);           // stream t5s1 (A loaded)
        if (!rdy) bad("w+r: t5s1 not ready");
        wr_race_req(1'b0, 1'b1, 7'd5, 8'd5, 8'd1, 8'd3, 3'd1, 256, 2, 8'h31,
                    1'b0, 1'b0, 7'd0);              // both toggle on one edge
        ack_wait("w+r", 1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("w+r: t0s0 not ready");
        wr_expect("w+r");
        dd_expect("w+r: t5s1 file bytes", 1'b0, 21'd45568, 256, 2, 8'h31);
        build_exp(0, 89, 21'd45568, 256, 2, 8'h31);
        expect_drain(1'b0, 11'd89, 1'b1);
        expect_no_drain("w+r: a second block");
        case_end("write_and_request");

        // ---------------- fdi_drive1_forged ----------------
        // FDI on drive 1 (position tables hold two drives) and a forged
        // track 2/1 block the bench built byte by byte: write-back must
        // match it by C,H,R,N and patch drive 1's own DDR window
        case_start();
        fill_config(1'b1, KIND_FDI, 7'd80, 1'b1);
        fill_prog(0);                               // the real track 0/1
        // header: ti = track 2 side 1 (2*2+1), DataOffset 0x2000, 4 records
        fill_raw(22'h300000 | (5 << 3) | 0, 8'h00);
        fill_raw(22'h300000 | (5 << 3) | 1, 8'h20);
        fill_raw(22'h300000 | (5 << 3) | 2, 8'h00);
        fill_raw(22'h300000 | (5 << 3) | 3, 8'h00);
        fill_raw(22'h300000 | (5 << 3) | 4, 8'd4);
        for (r = 0; r < 4; r = r + 1)
            for (b = 0; b < 7; b = b + 1)
                fill_raw(22'h200000 | (5 << 8) | (r << 3) | b[2:0],
                         (b == 0) ? 8'd2    : (b == 1) ? 8'd1  :
                         (b == 2) ? (r + 1) : (b == 3) ? 8'd1  :
                         (b == 4) ? ((r == 3) ? 8'h40 : 8'd0) :
                         (b == 6) ? {5'd0, r[2:0]}     : 8'd0);
        for (i = 0; i < 1024; i = i + 1)
            fill_raw(21'h2000 + i[20:0], pat(2, i, 8'h5A));
        fill_ready(1'b1);
        req_track(1'b1, 1'b1, 7'd0, rdy);           // the real block, drive 1
        if (!rdy) bad("fdi1: drive 1 track 0 not ready");
        check_track("fdi1 t0s1", 4);
        req_track(1'b1, 1'b1, 7'd2, rdy);           // the forged block
        if (!rdy) bad("fdi1: the forged track 2 is not ready");
        for (r = 0; r < 3; r = r + 1)              // record 4 has no data
            check_patch("fdi1 forged", 13'd70 + r * 388, 256, 2, 8'h5A);
        wr_sector(1'b1, 1'b1, 7'd2, 8'd2, 8'd1, 8'd3, 3'd1, 256, 2, 8'h77);
        check_patch("fdi1 patched", 13'd846, 256, 2, 8'h77);
        dd_expect("fdi1: forged data", 1'b1, 21'h2200, 256, 2, 8'h77);
        wr_sector(1'b1, 1'b1, 7'd2, 8'd2, 8'd1, 8'd2, 3'd1, 256, 1, 8'd0);
        check_patch("fdi1 patched 2", 13'd458, 256, 1, 8'd0);
        dd_expect("fdi1: record 2", 1'b1, 21'h2100, 256, 1, 8'd0);
        wr_sector(1'b1, 1'b1, 7'd2, 8'd2, 8'd1, 8'd4, 3'd1, 256, 1, 8'd0);
        dd_expect("fdi1: no data stays", 1'b1, 21'h2300, 256, 2, 8'h5A);
        expect_no_drain("fdi1: an FDI write never drains");
        case_end("fdi_drive1_forged");

        // ---------------- fdi_overflow ----------------
        // six 1 KiB records do not fit the 8 KiB track buffer: not ready
        case_start();
        fill_config(1'b1, KIND_FDI, 7'd80, 1'b1);
        fill_raw(22'h300000 | (6 << 3) | 0, 8'h00);
        fill_raw(22'h300000 | (6 << 3) | 1, 8'h00);
        fill_raw(22'h300000 | (6 << 3) | 2, 8'h40);
        fill_raw(22'h300000 | (6 << 3) | 3, 8'h00);
        fill_raw(22'h300000 | (6 << 3) | 4, 8'd6);
        for (r = 0; r < 6; r = r + 1)
            for (b = 0; b < 7; b = b + 1)
                fill_raw(22'h200000 | (6 << 8) | (r << 3) | b[2:0],
                         (b == 0) ? 8'd3    : (b == 2) ? (r + 1) :
                         (b == 3) ? 8'd3    :
                         (b == 6) ? {3'd0, r[2:0], 2'd0} : 8'd0);
        for (i = 0; i < 5120; i = i + 1)            // the first five records
            fill_raw(21'h4000 + i[20:0], pat(2, i, 8'h11));
        fill_ready(1'b1);
        req_track(1'b1, 1'b0, 7'd3, rdy);
        if (rdy) bad("overflow: 6 x 1024 B does not fit 8 KiB");
        case_end("fdi_overflow");


        // ==================== PART B: fdd_src as the host ==================
        // From here the store is fed by fdd_src: its reset is released, the
        // fill and drain ports switch over, and the two image files go into
        // the hps slots (slot a is drive A's, slot b drive B's).
        $readmemh("build/sim/fdd_img/trdh.hex", himg);
        $readmemh("build/sim/fdd_img/cpmh.hex", hpmg);
        for (k = 0; k < 16384; k = k + 1) hps.mem[0][k] = himg[k];
        for (k = 0; k < 10240; k = k + 1) hps.mem[1][k] = hpmg[k];
        host_en = 1'b1;
        mon_on  = 1;
        repeat (40) @(posedge bclk);

        // ---------------- geometry_auto ----------------
        // Every size resolves on its own; the next mount lands while the
        // previous fill is still streaming, which is the normal case.
        host_case_start();
        if (hs_wprt !== 2'b11) bad("geometry_auto: a drive with no image is writable");
        host_mount(2'b01, 64'd655360, 1'b0);
        expect_cfg("auto 655360", 1'b0, KIND_TRD, 7'd80, 1'b1);
        mon_reset();
        host_mount(2'b01, 64'd819200, 1'b0);      // 100 tracks: not TRD
        expect_cfg("auto 819200", 1'b0, KIND_CPM, 7'd80, 1'b1);
        mon_reset();
        host_mount(2'b01, 64'd409600, 1'b0);      // fits both: TRD wins
        expect_cfg("auto 409600", 1'b0, KIND_TRD, 7'd50, 1'b1);
        mon_reset();
        host_mount(2'b01, 64'd10240, 1'b0);       // 10240 is not a TRD size
        expect_cfg("auto 10240", 1'b0, KIND_CPM, 7'd1, 1'b1);
        mon_reset();
        host_mount(2'b01, 64'd688128, 1'b0);      // 84 tracks: the cap
        expect_cfg("auto 688128", 1'b0, KIND_TRD, 7'd84, 1'b1);
        // a size that fits neither geometry: an empty drive, and no ready
        mon_reset();
        host_mount(2'b01, 64'd12345, 1'b0);
        expect_cfg("auto 12345", 1'b0, KIND_TRD, 7'd0, 1'b0);
        quiet("auto 12345", 0, 1, 4000);
        host_mount(2'b01, 64'd0, 1'b0);
        wait_cfg("the eject of 12345", hw);
        case_end("geometry_auto");

        // ---------------- geometry_override ----------------
        // status[35:34] is sampled with the size, at the settle.
        host_case_start();
        hs_status       = 128'd0;
        hs_status[34]   = 1'b1;                   // force TRD
        host_mount(2'b01, 64'd819200, 1'b0);
        expect_cfg("force TRD 819200", 1'b0, KIND_TRD, 7'd0, 1'b0);
        quiet("force TRD 819200", 0, 1, 4000);
        mon_reset();
        hs_status       = 128'd0;
        hs_status[35]   = 1'b1;                   // force CP/M
        host_mount(2'b01, 64'd409600, 1'b0);
        expect_cfg("force CPM 409600", 1'b0, KIND_CPM, 7'd40, 1'b1);
        mon_reset();
        hs_status       = 128'd0;
        hs_status[35:34] = 2'd3;                  // not a selection: auto
        host_mount(2'b01, 64'd409600, 1'b0);
        expect_cfg("status 3 is auto", 1'b0, KIND_TRD, 7'd50, 1'b1);
        hs_status = 128'd0;
        host_mount(2'b01, 64'd0, 1'b0);
        wait_cfg("the last eject", hw);
        case_end("geometry_override");

        // ---------------- mount_order ----------------
        // The whole stream of one mount: the config first, then the image's
        // bytes 0..size-1 in order, each of them the hps slot's own byte, one
        // sd_rd per sector, and the ready as the last word. A design that
        // samples the size on the mount pulse fills nothing at all here.
        host_case_start();
        mon_memchk = 0;
        host_mount(2'b01, 64'd16384, 1'b0);
        expect_cfg("mount_order", 1'b0, KIND_TRD, 7'd2, 1'b1);
        if (mon_cfg_at !== 0)
            bad("mount_order: the config was not the first word");
        wait_rdy("mount_order");
        if (mon_cfg   !== 1)     bad("mount_order: more than one config");
        if (mon_rdy   !== 1)     bad("mount_order: more than one ready");
        if (mon_bytes !== 16384) bad("mount_order: not every image byte went");
        if (mon_seqbad !== 0)
            bad("mount_order: the addresses are not 0..size-1 in order");
        if (mon_maxa  !== 16383) bad("mount_order: the last byte is not size-1");
        if (mon_databad !== 0)
            bad("mount_order: a fill byte is not the hps slot's own byte");
        if (mon_sdrd  !== 32)
            bad("mount_order: the sector reads are not one per 512 bytes");
        if (mon_n !== mon_bytes + 2)
            bad("mount_order: the stream is not config, bytes, ready");
        if (hs_past_end !== 2'b00)
            bad("mount_order: a sector past the end of the image was read");
        if (hs_wprt[0] !== 1'b0)
            bad("mount_order: wprt is high for a writable image");
        case_end("mount_order");

        // ---------------- trd_via_host ----------------
        // The image the host path filled builds a track byte for byte.
        host_case_start();
        ref_load(1);                              // ref_trdh_t0s1
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("trd_via_host: track 0/1 is not ready");
        check_bh("trd_via_host t0s1");
        case_end("trd_via_host");

        // ---------------- readonly ----------------
        host_case_start();
        host_mount(2'b01, 64'd8192, 1'b1);        // the same file, read-only
        expect_cfg("readonly", 1'b0, KIND_TRD, 7'd1, 1'b1);
        if (hs_wprt[0] !== 1'b1) bad("readonly: wprt stayed low");
        wait_rdy("readonly");
        ref_load(0);                              // ref_trdh_t0s0
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("readonly: a read-only image did not build");
        check_bh("readonly t0s0");
        // sector R=3, position 0: the track buffer byte is 0*388+70 = 70, the
        // file bytes are 512..767, so the dirty block is block 1 (512..1023).
        drn0 = mon_drn;
        wr0  = mon_sdwr;
        wr_sector(1'b0, 1'b0, 7'd0, 8'd0, 8'd0, 8'd3, 3'd1, 256, 0, 8'd0);
        dd_expect("readonly ddr", 1'b0, 21'd512, 256, 0, 8'd0);
        k = 0;
        while (mon_drn == drn0 && k < DN_BUDGET) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (mon_drn == drn0) tfail("readonly: the write presented no drain");
        // The store does not know about read-only, so the block is presented;
        // the module eats it: no sector is ever written to the host's file and
        // every byte of the block keeps the value the mount put there.
        quiet_writes("readonly", 40_000);
        for (k = 0; k < 512; k = k + 1)
            if (hps.mem[0][512 + k] !== himg[512 + k]) begin
                if (shown < 8)
                    $display("FAIL readonly: a read-only image holds %02x at %0d",
                             hps.mem[0][512 + k], 512 + k);
                shown  = shown + 1;
                errors = errors + 1;
                k = 512;
            end
        // and the drive is still usable
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("readonly: the drive stopped answering");
        case_end("readonly");

        // ---------------- write_drain_to_host ----------------
        // One 512-byte block of a writable image goes back the way it came:
        // at its own LBA, the bytes the write did not touch still the file's.
        host_case_start();
        host_mount(2'b01, 64'd8192, 1'b0);
        expect_cfg("write_drain", 1'b0, KIND_TRD, 7'd1, 1'b1);
        if (hs_wprt[0] !== 1'b0)
            bad("write_drain: wprt is high for a writable image");
        wait_rdy("write_drain");
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("write_drain: track 0/0 is not ready");
        drn0 = mon_drn;
        wr0  = mon_sdwr;
        // sector R=3, position 0: buffer 70, file 512..767, block 1
        wr_sector(1'b0, 1'b0, 7'd0, 8'd0, 8'd0, 8'd3, 3'd1, 256, 0, 8'd0);
        dd_expect("write_drain ddr", 1'b0, 21'd512, 256, 0, 8'd0);
        k = 0;
        while (mon_sdwr < wr0 + 1 && k < FILL_ALL) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (mon_sdwr < wr0 + 1)
            tfail("write_drain: the dirty block never reached the host");
        wait_write_done("write_drain");
        if (mon_drn != drn0 + 1) begin
            $display("FAIL write_drain: %0d drain blocks for one dirty block",
                     mon_drn - drn0);
            errors = errors + 1;
        end
        quiet_writes("write_drain: no second block", 4000);
        // the whole of block 1: the 256 written bytes and the 256 that were
        // already there, in the order the host asked for them
        for (k = 0; k < 512; k = k + 1) begin
            if (k < 256) e0 = pat(0, k, 8'd0);
            else         e0 = himg[512 + k];
            if (hps.mem[0][512 + k] !== e0[7:0]) begin
                if (shown < 8)
                    $display("FAIL write_drain host[%0d] got %02x want %02x",
                             512 + k, hps.mem[0][512 + k], e0[7:0]);
                shown  = shown + 1;
                errors = errors + 1;
            end
        end
        case_end("write_drain_to_host");

        // ---------------- fdi_download ----------------
        host_case_start();
        dl_load(0);                               // one cylinder, two sides
        host_download(16'd1, 1);
        if (mon_cfg !== 1 || mon_rdy !== 1) begin
            $display("FAIL fdi_download A: %0d configs, %0d readies, %0d words, cfg=%h",
                     mon_cfg, mon_rdy, mon_n, mon_cfgw);
            errors = errors + 1;
        end
        if (mon_databad != 0) begin
            $display("FAIL fdi_download A: %0d bytes are not the file's, first at %0d", //
                     mon_databad, mon_badaddr);
            errors = errors + 1;
        end
        // the data area must have arrived whole: one byte per address, in
        // order, up to the file's last byte
        if (mon_seqbad != 0 ||
            mon_bytes !== dl_n - {dl_mem[11], dl_mem[10]} ||
            mon_maxa !== dl_n - {dl_mem[11], dl_mem[10]} - 1) begin
            $display("FAIL fdi_download A: %0d bytes, %0d out of order, last %0d, want %0d bytes to %0d", //
                     mon_bytes, mon_seqbad, mon_maxa,
                     dl_n - {dl_mem[11], dl_mem[10]},
                     dl_n - {dl_mem[11], dl_mem[10]} - 1);
            errors = errors + 1;
        end
        if (mon_cfgw !== {2'd0, 1'b0, KIND_FDI, 7'd1, 1'b1, 19'd0})
            bad("fdi_download: drive A's config is not the FDI's own header");
        ref_load(3);                              // ref_dl_t0s1
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("fdi_download: the downloaded track 0/1 is not ready");
        check_bh("fdi_download dl t0s1");
        // index 2 is drive B's, and the wide layout's 512 B sectors with it
        mon_reset();
        dl_load(1);
        host_download(16'd2, 1);
        if (mon_cfg !== 1 || mon_rdy !== 1) begin
            $display("FAIL fdi_download B: %0d configs, %0d readies, %0d words, cfg=%h",
                     mon_cfg, mon_rdy, mon_n, mon_cfgw);
            errors = errors + 1;
        end
        if (mon_databad != 0) begin
            $display("FAIL fdi_download B: %0d bytes are not the file's, first at %0d", //
                     mon_databad, mon_badaddr);
            errors = errors + 1;
        end
        if (mon_cfgw !== {2'd0, 1'b1, KIND_FDI, 7'd1, 1'b1, 19'd0})
            bad("fdi_download: drive B's config names the wrong drive");
        ref_load(4);                              // ref_dlw_t0s0
        req_track(1'b1, 1'b0, 7'd0, rdy);
        if (!rdy) bad("fdi_download: drive B's wide track is not ready");
        check_bh("fdi_download wide t0s0");
        // A one-side image: its blocks live where the store asks for them
        // (track*2+side), which is twice their number in the file.
        mon_reset();
        dl_load(2);                               // two cylinders, one side
        host_download(16'd1, 1);
        if (mon_cfgw !== {2'd0, 1'b0, KIND_FDI, 7'd2, 1'b0, 19'd0})
            bad("fdi_download: the one-side config lost its side count");
        ref_load(5);                              // ref_dl1_t1s0
        req_track(1'b0, 1'b0, 7'd1, rdy);
        if (!rdy) bad("fdi_download: the one-side image's track 1 is not ready");
        check_bh("fdi_download one-side t1s0");
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (rdy) bad("fdi_download: a one-side image answered for side 1");
        // index 0 is boot.rom's: the whole window is somebody else's
        mon_reset();
        dl_load(0);
        host_download(16'd0, 0);
        quiet("ioctl index 0", 1, 1, 2000);
        // three headers that must not be trusted: no config, no ready, and
        // the image the drive already has keeps working
        dl_load(3);
        host_download(16'd1, 2);
        quiet("the truncated header", 1, 1, 2000);
        dl_load(4);
        host_download(16'd1, 2);
        quiet("the bad magic", 1, 1, 2000);
        dl_load(5);
        host_download(16'd1, 2);
        quiet("the over-cylinder header", 1, 1, 2000);
        if (mon_cfg !== 0 || mon_rdy !== 0)
            bad("fdi_download: an aborted header still reached the store");
        req_track(1'b0, 1'b0, 7'd1, rdy);
        if (!rdy) bad("fdi_download: the aborts took the drive's image");
        check_bh("fdi_download the image survives the aborts");
        case_end("fdi_download");

        // ---------------- eject_mid_fill_host ----------------
        host_case_start();
        host_mount(2'b01, 64'd16384, 1'b0);
        expect_cfg("eject_mid_fill", 1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_push(1200);                          // well inside the fill
        host_mount(2'b01, 64'd0, 1'b0);
        wait_cfg("the eject", hw);
        if (hw !== {2'd0, 1'b0, KIND_TRD, 7'd0, 1'b0, 19'd0})
            bad("eject_mid_fill: the eject's config is not an empty drive");
        quiet("the aborted fill", 0, 1, 6000);
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (rdy) bad("eject_mid_fill: an ejected drive answered ready");
        mon_reset();
        host_mount(2'b01, 64'd8192, 1'b0);
        expect_cfg("the mount after the eject", 1'b0, KIND_TRD, 7'd1, 1'b1);
        wait_rdy("the mount after the eject");
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("eject_mid_fill: the drive never came back");
        ref_load(0);
        check_bh("eject_mid_fill after the remount");
        case_end("eject_mid_fill_host");

        // ---------------- remount_mid_drain_host ----------------
        // The mount lands while the drive's dirty block is being copied out
        // of the store: those bytes belong to the mount that is gone, and
        // putting them at the same LBA of the new one would corrupt it.
        host_case_start();
        host_mount(2'b01, 64'd8192, 1'b0);
        expect_cfg("remount_mid_drain", 1'b0, KIND_TRD, 7'd1, 1'b1);
        wait_rdy("remount_mid_drain");
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("remount_mid_drain: track 0/0 is not ready");
        drn0 = mon_drn;
        wr_sector(1'b0, 1'b0, 7'd0, 8'd0, 8'd0, 8'd3, 3'd1, 256, 0, 8'd0);
        k = 0;
        while (mon_drn == drn0 && k < DN_BUDGET) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (mon_drn == drn0) tfail("remount_mid_drain: no drain was presented");
        // the new file is a different size, which is what lets the mount land
        // inside the copy: a size change settles the mount in 1023 clocks,
        // while a same-size mount waits the 4095-clock fallback and would
        // land after the block had already been written.
        host_mount(2'b01, 64'd16384, 1'b0);         // mid copy
        wr0 = mon_sdwr;
        // the copy in flight belongs to the image that is gone: none of its
        // bytes may reach the new file, which stands at the same LBA
        quiet_writes("remount_mid_drain", 40_000);
        for (k = 0; k < 512; k = k + 1)
            if (hps.mem[0][512 + k] !== himg[512 + k]) begin
                if (shown < 8)
                    $display("FAIL remount_mid_drain: the stale block wrote %0d",
                             512 + k);
                shown  = shown + 1;
                errors = errors + 1;
                k = 512;
            end
        // the remount's config lands while the case is still watching for the
        // stale block, so it is read from the counters rather than waited for
        if (mon_cfg !== 2 ||
            mon_cfgw !== {2'd0, 1'b0, KIND_TRD, 7'd2, 1'b1, 19'd0}) begin
            $display("FAIL remount_mid_drain: %0d configs, last %h", //
                     mon_cfg, mon_cfgw);
            errors = errors + 1;
        end
        wait_rdy("the remount");
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("remount_mid_drain: the new mount is not ready");
        ref_load(0);
        check_bh("remount_mid_drain after the remount");
        // the dirty path works again on the new mount: sector R=4 of track 0
        // is the file's 768..1023, still block 1
        wr0 = mon_sdwr;
        wr_sector(1'b0, 1'b0, 7'd0, 8'd0, 8'd0, 8'd4, 3'd1, 256, 1, 8'd0);
        k = 0;
        while (mon_sdwr < wr0 + 1 && k < FILL_ALL) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (mon_sdwr < wr0 + 1)
            tfail("remount_mid_drain: no dirty block reached the host again");
        wait_write_done("remount_mid_drain");
        dd_expect("remount_mid_drain ddr", 1'b0, 21'd768, 256, 1, 8'd0);
        for (k = 0; k < 256; k = k + 1)
            if (hps.mem[0][768 + k] !== pat(1, k, 8'd0)) begin
                if (shown < 8)
                    $display("FAIL remount_mid_drain fresh[%0d] got %02x want %02x",
                             k, hps.mem[0][768 + k], pat(1, k, 8'd0));
                shown  = shown + 1;
                errors = errors + 1;
                k = 256;
            end
        case_end("remount_mid_drain_host");


        // ---------------- verdict ----------------
        $display("tb_fdd_img: %0d errors", errors);
        if (errors == 0) $display("tb_fdd_img: PASS");
        else             $display("tb_fdd_img: FAIL %0d checks failed", errors);
        $finish;
    end : test

endmodule

`default_nettype wire
