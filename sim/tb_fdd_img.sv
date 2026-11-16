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
//                         10240 CP/M-1, 688128 TRD-84, 12345 no image, and
//                         the cap over the whole sector count (1474560 and
//                         1056768 no image, 696320 CP/M-68).
//   geometry_override     status[35:34]: 2 forces CP/M (409600 -> 40), 1
//                         forces TRD (819200 -> no image), 1 over the cap
//                         (696320 -> no image), 3 behaves as auto.
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
//   host_mount_b          drive B is the other hps slot: its own config, its
//                         own track, its own write-back (slot b, drive A's
//                         file not one byte moved), and hs_wprt per drive.
//   fdi_wprotect          byte 3 of the FDI header is the file's write-protect
//                         flag: it locks its own drive and leaves the other
//                         one, and the file still fills exact; a block whose
//                         sector count is over the store's 32 record slots
//                         gets its config and never its ready.
//   download_after_aborted  a download that stops mid-stream (a header that
//                         ends the file, a refused magic) lets go of the byte
//                         it holds, so the next file's first byte is there.
//   download_over_fill    a download while the other drive is filling: the
//                         store's port changes hands at the next push (the
//                         download's ready goes out with that fill still
//                         short of its last sector) and the fill runs again
//                         afterwards and comes up.
//   download_then_mount   a mount of the drive whose file is streaming ends
//                         the download, byte in hand included; the mounted
//                         image wins, and the next file of that index lands
//                         from its first byte.
//   fdi_overlong_block    a block that really carries 33 records is refused:
//                         its config reaches the store, its ready never does,
//                         and the drive stays not-ready.
//   drain_under_download  a dirty block of drive A and a file for drive B at
//                         once: the write-back waits for the host instead of
//                         asking the host the download holds, and both land.
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
    integer by0;                                // fill bytes at a claim clock
    reg prem_hit;                               // a case's premise, measured
    integer m_w;                                // a hand-paced byte's wait loop
    integer m2_b0;                              // fill bytes at the wrap poke
    integer sdw0;                               // a write-back request baseline

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
            // the host-ownership invariant, watched on the wire: no disk
            // request was standing for long behind the download's wait (that
            // is mon_stall, reported where it happens), and none was raised
            // into the wait at all (mon_raise, this module's own rule)
            if (host_en && mon_raise != 0) begin
                $display("FAIL %0s: a disk request was raised while the download's wait stood (%0d)",
                         cs, mon_raise);
                errors = errors + 1;
            end
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

    // The host that feeds the ioctl download channel is the host that serves
    // the disk slots: one thread, so while it sits in a download's wait loop
    // no *new* slot request reaches it. A transfer already under way is left
    // alone - the gate closes only between transfers, which is where hps_io
    // decides whether it is busy.
    // A case can hold one drive's disk acknowledge down. That is what the host
    // does while it sits inside a download's wait loop, and it is the state the
    // module must never stay in: the request it waits on is a request to the
    // host that is waiting for the module. The model still sees the module's
    // request (it is the one that answers it); only the module is left without
    // an answer.
    reg  [1:0] hold_ack = 2'b00;
    wire [1:0] host_ack = hs_sd_ack & ~hold_ack;

    wire       host_here = (io_wait === 1'b1) && (hs_sd_ack == 2'b00);
    wire [1:0] mdl_rd    = hs_sd_rd & ~{2{host_here}};
    wire [1:0] mdl_wr    = hs_sd_wr & ~{2{host_here}};

    hps_disk_model #(.LAT_CLKS(10)) hps (
        .clk(bclk), .img_size(hs_size),
        .rd(mdl_rd), .wr(mdl_wr),
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
        .sd_ack(host_ack),
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
            mon_dlm = 0; mon_dlbase = 0; mon_badaddr = -1; mon_stall = 0;
            mon_raise = 0;
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
            // each case owns a pristine pair of images: an earlier case's
            // write-back must never be read as this case's own byte. Behind
            // the fixture lies a marker that is neither the fixture's byte nor
            // a write pattern's, so a comparison that runs past the end of a
            // small fixture says "not the file's byte" instead of passing on
            // whatever the memory happened to hold
            for (k = 0; k < 65536; k = k + 1) begin
                hps.mem[0][k] = 8'h5A;
                hps.mem[1][k] = 8'h5A;
            end
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
            else if (hs_fill_word[31:30] == 2'd2) begin
                mon_rdy = mon_rdy + 1;
                // how far the drive's own fill had come when this ready went
                // out: the proof that a download did not wait for a fill
                mon_at_rdy = mon_sdrd1;
            end
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
    // sector reads of drive B alone (a download streams no sector read, so
    // this counts one fill), and the read count a ready was sent at
    integer mon_sdrd1 = 0;
    integer mon_at_rdy = 0;
    always @(posedge hs_sd_rd[1]) if (mon_on) mon_sdrd1 = mon_sdrd1 + 1;
    // clocks on which the module held a disk slot request while its download
    // held ioctl_wait: that request asks the host the download has stopped,
    // which is the deadlock the review's rule is about
    // Clocks on which the module held a disk slot request while its download
    // held ioctl_wait: that request asks the host the download has stopped,
    // which is the deadlock the review's rule is about. A request that already
    // stands when the window opens is withdrawn within a few clocks; a request
    // that keeps standing is the bug, so the count is watched on the wire and
    // reported on the clock it crosses - while the machine is still there to
    // be read - and not at the next case boundary, where the run has moved on.
    integer mon_stall = 0;
    always @(posedge bclk)
        if (!hs_rst && mon_on && (io_wait === 1'b1) &&
            ((hs_sd_rd !== 2'b00) || (hs_sd_wr !== 2'b00))) begin
            mon_stall = mon_stall + 1;
            if (mon_stall == 65) begin
                $display("FAIL a disk request stood %0d clocks behind the download's wait (rd=%b wr=%b st=%0d dact=%b)",
                         mon_stall, hs_sd_rd, hs_sd_wr, src.st, src.dl_act);
                shown  = shown + 1;
                errors = errors + 1;
            end
        end
        else if (mon_stall > 64)
            mon_stall = 0;

    // The raise side of the same rule: a request that is already standing
    // when a window opens is withdrawn on the next clock, which is allowed -
    // the host has not been asked anything yet on that clock. A request that
    // is *raised* on a clock whose wait is up is the module knocking on a
    // door it is holding shut itself, and no clock of that is allowed.
    integer mon_raise = 0;
    always @(posedge hs_sd_rd[0] or posedge hs_sd_rd[1] or
             posedge hs_sd_wr[0] or posedge hs_sd_wr[1])
        if (!hs_rst && mon_on && (io_wait === 1'b1))
            mon_raise = mon_raise + 1;
    always @(drn_tgl) if (mon_on) mon_drn = mon_drn + 1;

    always @(posedge hs_sd_rd[0] or posedge hs_sd_rd[1])
        if (mon_on) mon_sdrd = mon_sdrd + 1;

    // sector writes, either drive (did a write-back reach the host)
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

    // what the machine was doing when a drive refused to come up: both halves
    // of the module, because "no ready" can be a fill that stopped, a download
    // that never ended, or a mount that never crossed
    task automatic dump_stall(input [8*40-1:0] who, input integer k);
        begin
            $display("FAIL %0s: no ready after %0d clocks", who, k);
            $display("  st=%0d act=%b drv=%b sec=%0d nsec=%0d pend=%b run=%b ragain=%b fdi=%b dact=%b down=%b jb=%d mnt=%b/%b ack=%b rd=%b gate=%b wait=%b store=%0d n=%0d",
                     src.st, src.fl_act, src.fl_drv, src.f_sec, src.f_nsec,
                     src.chg_pend, src.chg_run, src.fl_again, src.fdi,
                     src.dl_act, src.dl_own, src.jb,
                     {src.mnt_lvl[1], src.mnt_lvl[0]},
                     {src.mnt_valid[1], src.mnt_valid[0]},
                     hs_sd_ack, hs_sd_rd, src.rd_gate, io_wait,
                     dut.state, mon_bytes);
            $display("  dl ph=%0d kill=%b max=%b pos=%0d off_data=%0d nblk=%0d blk=%0d cnt=%0d rec=%0d idx=%0d widx=%0d hdr=%02x%02x%02x%02x",
                     src.dl_phase, src.dl_kill, src.max_bad, src.t_pos,
                     src.off_data, src.t_nblk, src.t_blk, src.t_cnt,
                     src.t_rec, src.t_idx, src.dl_widx,
                     src.hdr[0], src.hdr[1], src.hdr[2], src.hdr[3]);
        end
    endtask

    // the next ready: a mount whose fill is still reading its sectors
    task automatic wait_rdy(input [8*40-1:0] who);
        integer k, n0;
        begin
            n0 = mon_rdy;
            k  = 0;
            while (mon_rdy == n0 && k < FILL_ALL) begin
                @(posedge bclk);
                k = k + 1;
            end
            if (mon_rdy == n0) begin
                dump_stall(who, k);
                tfail("a host fill never sent ready");
            end
        end
    endtask

    // a ready count of at least `want`: a download's ready can arrive while
    // the host's own byte loop is still running, so a case that starts
    // counting from zero has to wait for the level and not for the edge it
    // was not watching
    task automatic wait_rdy_n(input [8*40-1:0] who, input integer want);
        integer k;
        begin
            k = 0;
            while (mon_rdy < want && k < FILL_ALL) begin
                @(posedge bclk);
                k = k + 1;
            end
            if (mon_rdy < want) begin
                dump_stall(who, k);
                tfail("a downloaded image never sent ready");
            end
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
                5: $readmemh("build/sim/fdd_img/dlbig.hex", dl_mem);
                6: $readmemh("build/sim/fdd_img/dlwp.hex",  dl_mem);
                7: $readmemh("build/sim/fdd_img/dlc33.hex", dl_mem);
                default: $readmemh("build/sim/fdd_img/dl33.hex", dl_mem);
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
    task automatic host_stream(input [15:0] index, input integer mode);
        integer k, w, lost;
        reg seen, saw;
        begin
            saw  = 1'b0;
            lost = 0;
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

    // The claim and the stream, for everything that does not care which clock
    // the window is claimed on. The claim is a level the module watches, so it
    // goes up one clock edge and stays up; a case that has to land inside a
    // few clocks of a state raises io_download itself and calls host_stream.
    task automatic host_download(input [15:0] index, input integer mode);
        begin
            @(posedge bclk);
            #1;
            io_index    = index;
            io_download = 1'b1;
            host_stream(index, mode);
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
    integer cf0, rf0;                   // a config / ready baseline
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
        // The cap has to be checked on the whole sector count: 1474560 is the
        // TRD image of 180 tracks, whose 16-bit count still fits in 8 bits -
        // a count kept in 7 bits folds 180 onto 52 and the module streams a
        // 52-track drive out of a file three times too big. Both geometries
        // are over the cap here, so: an empty drive and no ready.
        mon_reset();
        host_mount(2'b01, 64'd1474560, 1'b0);
        expect_cfg("auto 1474560", 1'b0, KIND_TRD, 7'd0, 1'b0);
        quiet("auto 1474560", 0, 1, 4000);
        mon_reset();
        host_mount(2'b01, 64'd1056768, 1'b0);     // 20480 sectors, both over
        expect_cfg("auto 1056768", 1'b0, KIND_TRD, 7'd0, 1'b0);
        quiet("auto 1056768", 0, 1, 4000);
        // 696320 bytes is TRD-85: over the cap, and the geometry below the
        // cap is CP/M-68. The next mount lands on this fill, so only the
        // geometry is proven here, not the stream.
        mon_reset();
        host_mount(2'b01, 64'd696320, 1'b0);
        expect_cfg("auto 696320", 1'b0, KIND_CPM, 7'd68, 1'b1);
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
        // A forced geometry over the cap is refused as well: with TRD forced,
        // 696320 is TRD-85, and behind a selection the user made there is no
        // fallthrough to a smaller geometry.
        mon_reset();
        hs_status       = 128'd0;
        hs_status[34]   = 1'b1;                   // force TRD
        host_mount(2'b01, 64'd696320, 1'b0);
        expect_cfg("force TRD 696320", 1'b0, KIND_TRD, 7'd0, 1'b0);
        quiet("force TRD 696320", 0, 1, 4000);
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

        // ---------------- host_mount_b ----------------
        // Drive B is not drive A with another config bit: its image is the
        // other hps slot, its config says d=1, its lock is hs_wprt[1], and
        // its write-back has to land in that other slot's bytes. Drive A
        // carries an image of its own all the way through and must not move.
        host_case_start();
        mon_memchk = -1;
        host_mount(2'b01, 64'd16384, 1'b0);
        expect_cfg("host_mount_b A", 1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_rdy("host_mount_b A");
        host_mount(2'b10, 64'd10240, 1'b0);
        expect_cfg("host_mount_b B", 1'b1, KIND_CPM, 7'd1, 1'b1);
        wait_rdy("host_mount_b B");
        if (hs_wprt !== 2'b00)
            bad("host_mount_b: two writable images are not both writable");
        ref_load(2);                          // ref_cpmh_t0s0, the slot b image
        req_track(1'b1, 1'b0, 7'd0, rdy);
        if (!rdy) bad("host_mount_b: drive B's track is not ready");
        check_bh("host_mount_b B t0s0");
        // A write to B comes back in slot b: sector R=2 of a 1024-byte
        // geometry is the file's 1024..1279, which is its block 2, LBA 2.
        wr0 = mon_sdwr;
        wr_sector(1'b1, 1'b0, 7'd0, 8'd0, 8'd0, 8'd2, 3'd3, 256, 1, 8'd0);
        k = 0;
        while (mon_sdwr < wr0 + 1 && k < FILL_ALL) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (mon_sdwr < wr0 + 1)
            tfail("host_mount_b: B's dirty block never reached the host");
        wait_write_done("host_mount_b");
        e0 = 0;
        for (k = 0; k < 256; k = k + 1)
            if (hps.mem[1][1024 + k] !== pat(1, k, 8'd0)) e0 = e0 + 1;
        if (e0 != 0) begin
            $display("FAIL host_mount_b: %0d bytes of B's block missed slot b", e0);
            errors = errors + 1;
        end
        e0 = 0;
        for (k = 0; k < 1024; k = k + 1)
            if (hps.mem[0][k] !== himg[k]) e0 = e0 + 1;
        if (e0 != 0) begin
            $display("FAIL host_mount_b: %0d of A's file's bytes moved", e0);
            errors = errors + 1;
        end
        // a read-only image locks its own drive and leaves the other one free
        host_mount(2'b10, 64'd0, 1'b0);
        wait_cfg("the eject of B", hw);
        host_mount(2'b10, 64'd10240, 1'b1);
        expect_cfg("host_mount_b B read-only", 1'b1, KIND_CPM, 7'd1, 1'b1);
        if (hs_wprt !== 2'b10)
            bad("host_mount_b: hs_wprt is not 10 for a writable A and a locked B");
        case_end("host_mount_b");

        // ---------------- fdi_wprotect ----------------
        // An FDI carries a write-protect flag of its own in byte 3 of its
        // header (the field mk_disk leaves as the format's version 0), and
        // there is no mount burst behind a download that could say anything
        // else. The flag is only half the answer: the host has no file behind
        // a downloaded image, so a write to such a drive has nowhere to go
        // back to and the drive is locked whatever its header says. Only a
        // mount, which brings a file with it, opens a drive again.
        host_case_start();
        mon_memchk = -1;
        dl_load(0);                               // dl.fdi: the flag is clear
        host_download(16'd1, 1);
        if (mon_rdy !== 1) bad("fdi_wprotect: the plain file never arrived");
        if (hs_wprt[0] !== 1'b1)
            bad("fdi_wprotect: a downloaded image was left writable");
        mon_reset();
        dl_load(6);                               // dlwp.fdi: byte 3 is 1
        host_download(16'd1, 1);
        if (mon_rdy !== 1) begin
            $display("FAIL fdi_wprotect: the file with its flag set sent %0d readies",
                     mon_rdy);
            errors = errors + 1;
        end
        if (hs_wprt[0] !== 1'b1)
            bad("fdi_wprotect: the file's lock flag never reached the drive");
        ref_load(3);                              // and the image is the file's
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("fdi_wprotect: the downloaded track is not ready");
        check_bh("fdi_wprotect dl t0s1");
        // the other drive keeps its own state: both are downloads now, so
        // both are locked, and neither lock says anything about the other
        mon_reset();
        dl_load(0);
        host_download(16'd2, 1);
        if (hs_wprt !== 2'b11) begin
            $display("FAIL fdi_wprotect: wprt %b with two downloaded images",
                     hs_wprt);
            errors = errors + 1;
        end
        // A block whose sector count is over the store's 32 record slots must
        // not be counted into the table at all (it would wrap onto slot 0 and
        // build a track out of the following block's header). The config is
        // already out when the count is read, so the refusal is a drive that
        // never gets its ready.
        mon_reset();
        dl_load(7);                               // dlc33.fdi: 33 records
        host_download(16'd1, 2);
        quiet("the 33-record block", 0, 1, 4000);
        if (mon_cfg !== 1)
            bad("the 33-record block: its header never reached the store");
        if (hs_wprt[0] !== 1'b1)
            bad("the 33-record block: a refused file left the drive writable");
        // A mount is the only thing that ends a downloaded image: it brings
        // the file a write-back needs, and with it goes the lock - of this
        // drive only, because the mask is per drive.
        mon_reset();
        host_mount(2'b01, 64'd16384, 1'b0);
        expect_cfg("fdi_wprotect remount", 1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_rdy("fdi_wprotect remount");
        if (hs_wprt[0] !== 1'b0)
            bad("fdi_wprotect: a mounted file did not unlock its drive");
        if (hs_wprt[1] !== 1'b1)
            bad("fdi_wprotect: unlocking A opened B as well");
        case_end("fdi_wprotect");

        // ---------------- download_after_aborted ----------------
        // hps_io holds no byte of its own: every byte is a strobe the core
        // either takes or loses. A download that stops in the middle of the
        // stream - a file that ends inside its header, a header refused for
        // its magic - therefore has to let go of the byte it is holding, or
        // the wait stays up and the next download begins with a byte missing:
        // a file whose magic is three bytes short.
        host_case_start();
        mon_memchk = -1;
        dl_load(3);                               // eight bytes: no header
        host_download(16'd1, 2);
        quiet("the truncated file", 0, 1, 2000);
        mon_reset();
        dl_load(0);
        host_download(16'd1, 1);
        if (mon_cfg !== 1 || mon_rdy !== 1) begin
            $display("FAIL download_after_aborted: %0d configs, %0d readies",
                     mon_cfg, mon_rdy);
            errors = errors + 1;
        end
        if (mon_cfgw !== {2'd0, 1'b0, KIND_FDI, 7'd1, 1'b1, 19'd0})
            bad("download_after_aborted: the second file's header is not the config");
        ref_load(3);
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("download_after_aborted: the drive is not ready");
        check_bh("download_after_aborted after the truncated file");
        // the same after a header that was read and refused
        mon_reset();
        dl_load(4);                               // a wrong magic
        host_download(16'd1, 2);
        quiet("the bad magic", 0, 1, 2000);
        mon_reset();
        dl_load(0);
        host_download(16'd1, 1);
        if (mon_rdy !== 1)
            bad("download_after_aborted: nothing landed after the bad magic");
        check_bh("download_after_aborted after the bad magic");
        case_end("download_after_aborted");

        // ---------------- download_then_mount ----------------
        // hps_io keeps nothing of its own: while a file is streaming, every
        // byte is a strobe the core took or lost. A mount of that drive ends
        // the download - the file the OSD just picked is the drive's image
        // now - and the window goes with it, the byte in hand included. A
        // module that still counts itself as holding that byte never takes
        // the first byte of the next file either, and the next download is a
        // file whose magic is one byte short.
        host_case_start();
        mon_memchk = -1;
        dl_load(0);
        cf0 = mon_cfg;
        rf0 = mon_rdy;
        fork
            host_download(16'd1, 2);
            begin
                repeat (60) @(posedge bclk);
                host_mount(2'b01, 64'd16384, 1'b0);
            end
        join
        // The mount's config and ready cannot be waited for from here: the
        // source is only let go once, and the mount settles, dispatches and
        // fills while it is still streaming. Both are read from the counters.
        if (mon_cfg <= cf0)
            bad("download_then_mount: the mount never sent a config");
        if (mon_cfgw !== {2'd0, 1'b0, KIND_TRD, 7'd2, 1'b1, 19'd0})
            bad("download_then_mount: the drive's config is not the mount's TRD image");
        k = 0;
        while (mon_rdy <= rf0 && k < FILL_ALL) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (mon_rdy <= rf0) tfail("download_then_mount: the mount never sent ready");
        ref_load(0);                              // the mount's own file won
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("download_then_mount: the mounted image is not ready");
        check_bh("download_then_mount the mount won the download");
        // and a fresh window of the same index works from its first byte
        mon_reset();
        dl_load(0);
        host_download(16'd1, 1);
        if (mon_cfg !== 1 || mon_rdy !== 1) begin
            $display("FAIL download_then_mount: %0d configs, %0d readies after the mount",
                     mon_cfg, mon_rdy);
            errors = errors + 1;
        end
        ref_load(3);
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("download_then_mount: the second download never built a track");
        check_bh("download_then_mount the second download");
        case_end("download_then_mount");


        // ---------------- download_over_fill ----------------
        // The host is one thread: while it is inside a download's wait loop
        // it is not listening to the disk slots, so a fill that keeps asking
        // for sectors makes a download behind it wait forever. The store's
        // port therefore changes hands at the next store push, and the fill
        // that was in the way runs again afterwards.
        host_case_start();
        mon_memchk = -1;
        hs_status      = 128'd0;
        hs_status[34]  = 1'b1;                    // TRD forced: a fill at all
        host_mount(2'b10, 64'd16384, 1'b0);
        expect_cfg("download_over_fill B", 1'b1, KIND_TRD, 7'd2, 1'b1);
        mon_sdrd1  = 0;
        mon_at_rdy = 999;
        wait_push(2000);                          // well inside the fill
        dl_load(0);
        host_download(16'd1, 1);
        // the download is in the store while B's fill still has sectors left:
        // 16384 bytes is 32 sector reads, so a download that had to wait for
        // the fill to finish would report all 32 reads already done
        if (mon_cfg !== 2 || mon_rdy !== 1) begin
            $display("FAIL download_over_fill: %0d configs, %0d readies",
                     mon_cfg, mon_rdy);
            errors = errors + 1;
        end
        if (mon_at_rdy >= 32) begin
            $display("FAIL download_over_fill: the download waited for %0d of B's 32 sectors",
                     mon_at_rdy);
            errors = errors + 1;
        end
        // (no byte-by-byte check here: the fill of B and the download's data
        // area address the store's window in the same range, so the running
        // byte monitor cannot tell the two streams apart - what the download
        // put in the store is proven by the track below instead)
        ref_load(3);
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("download_over_fill: the downloaded drive is not ready");
        check_bh("download_over_fill dl t0s1");
        // and drive B, whose fill was put aside, fills again and comes up
        hs_status = 128'd0;
        wait_rdy("download_over_fill the fill of B after the download");
        req_track(1'b1, 1'b0, 7'd0, rdy);
        if (!rdy) bad("download_over_fill: drive B never came up after the download");
        case_end("download_over_fill");
        // ---------------- fdi_overlong_block ----------------
        // A block header's sector count is one byte, so nothing in the format
        // stops a file asking for more records than the store's table has
        // slots (32). Counting them would put record 33 where record 1 lives
        // and hand out a track whose first sector is the next block's header.
        // The count is read after the config went out, so the refusal is a
        // drive with a config that never becomes ready.
        host_case_start();
        mon_memchk = -1;
        dl_load(8);                               // dl33.fdi: 33 records
        host_download(16'd1, 2);
        quiet("the 33-record block", 0, 1, 6000);
        if (mon_cfg !== 1)
            bad("fdi_overlong_block: the header never reached the store");
        // what the refusal has to look like on the wire: the config went out
        // with the header, and not one byte of the file's data area may
        // follow it. Counting past the table's slots streams on to the data
        // area and calls the drive ready.
        if (mon_bytes != 0) begin
            $display("FAIL fdi_overlong_block: %0d bytes of a refused file streamed on",
                     mon_bytes);
            errors = errors + 1;
        end
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (rdy) bad("fdi_overlong_block: a refused file left a ready drive");
        case_end("fdi_overlong_block");

        // ---------------- drain_under_download ----------------
        // One host, two customers again: a dirty block of drive A goes back
        // over the same interface that drive B's download owns. The block
        // waits, it does not ask the host the download stopped; both arrive.
        host_case_start();
        mon_memchk = -1;
        host_mount(2'b01, 64'd16384, 1'b0);
        expect_cfg("drain_under_download A", 1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_rdy("drain_under_download A");
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("drain_under_download: track 0/0 is not ready");
        drn0 = mon_drn;
        wr_sector(1'b0, 1'b0, 7'd0, 8'd0, 8'd0, 8'd3, 3'd1, 256, 1, 8'd0);
        k = 0;
        while (mon_drn == drn0 && k < DN_BUDGET) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (mon_drn == drn0) tfail("drain_under_download: no block was presented");
        // the copy out of the store is running when the window opens
        mon_reset();
        dl_load(1);
        host_download(16'd2, 1);
        if (mon_rdy !== 1)
            bad("drain_under_download: the file behind the write-back never arrived");
        if (mon_cfgw !== {2'd0, 1'b1, KIND_FDI, 7'd1, 1'b1, 19'd0})
            bad("drain_under_download: the download is not drive B's own config");
        wait_write_done("drain_under_download");
        if (mon_sdwr < 1)
            bad("drain_under_download: A's dirty block never reached the host");
        e0 = 0;
        for (k = 0; k < 256; k = k + 1)
            if (hps.mem[0][512 + k] !== pat(1, k, 8'd0)) e0 = e0 + 1;
        if (e0 != 0) begin
            $display("FAIL drain_under_download: %0d of A's block's bytes missed the file", e0);
            errors = errors + 1;
        end
        case_end("drain_under_download");

        // ---------------- fdi_same_drive_fill ----------------
        // A download for the drive that is filling at this very moment is the
        // awkward one: the file the OSD picked *is* this drive's image now, so
        // the fill that was reading the disk slot has to stop for good, and
        // not come back afterwards to paint the mounted image over the file's
        // records. A file that is refused before its config asks the opposite:
        // the mounted image is all the drive has, and that fill has to run to
        // its end again.
        host_case_start();
        mon_memchk = -1;
        hs_status      = 128'd0;
        hs_status[34]  = 1'b1;                    // TRD forced: a fill at all
        host_mount(2'b01, 64'd16384, 1'b0);
        expect_cfg("fdi_same_drive_fill A", 1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_push(400);                           // well inside A's fill
        hold_ack = 2'b01;                         // the host stops answering A
        // and the fill comes to rest on that read: the claim then lands on the
        // state whose whole job is to end a fill for good
        k = 0;
        while (!(src.st === 5'd5 && src.rd_gate === 1'b1) && k < FILL_ALL) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (!(src.st === 5'd5 && src.rd_gate === 1'b1))
            tfail("fdi_same_drive_fill: the fill never came to rest on its read");
        mon_reset();                              // the file alone from here
        dl_load(0);
        host_download(16'd1, 1);
        hold_ack = 2'b00;
        wait_rdy_n("fdi_same_drive_fill the file", 1);
        // One config and one ready: the file's. The fill this download
        // displaced sent its config and died with the file's config, and a
        // second config or ready is that fill running again over a drive
        // whose image is a file now.
        if (mon_cfg !== 1 || mon_rdy !== 1) begin
            $display("FAIL fdi_same_drive_fill: %0d configs, %0d readies",
                     mon_cfg, mon_rdy);
            errors = errors + 1;
        end
        // The module's own word for the rule, and the cheapest one: a file
        // that owns its drive leaves no fill of that drive behind. Without the
        // stops the engine is mid-push on this very clock - measured: state
        // E_P_ACK, the store's port busy, 3 kB of the mounted image already
        // written over the file's records - and no amount of waiting for a
        // config would have said so.
        if (src.fl_act !== 1'b0)
            bad("fdi_same_drive_fill: a fill still runs behind the file that owns its drive");
        // 120000, not a few thousand: a fill that came back pays for its whole
        // image at about five clocks a byte (the copy walks four states per
        // byte) plus a host read per sector, and its second ready has to fall
        // inside the window to be seen
        quiet("A after its own file", 1, 1, 120_000);
        if (hs_wprt[0] !== 1'b1)
            bad("fdi_same_drive_fill: the downloaded drive is writable");
        ref_load(3);
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("fdi_same_drive_fill: the file's track is not ready");
        check_bh("fdi_same_drive_fill the file won its own drive");
        // The refused file asks for the mounted image back: the fill the
        // download interrupted runs again, to its end and with its config.
        mon_reset();
        host_mount(2'b01, 64'd16384, 1'b0);
        expect_cfg("fdi_same_drive_fill again", 1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_push(400);
        dl_load(4);                               // a wrong magic: refused
        cf0 = mon_cfg;
        host_download(16'd1, 2);
        k = 0;
        while (mon_cfg <= cf0 && k < MNT_BUDGET) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (mon_cfg <= cf0)
            bad("fdi_same_drive_fill: the refused file left the drive unfilled");
        if (mon_cfgw !== {2'd0, 1'b0, KIND_TRD, 7'd2, 1'b1, 19'd0})
            bad("fdi_same_drive_fill: the drive's image is not the mount's TRD");
        wait_rdy_n("fdi_same_drive_fill after the refused file", 1);
        if (hs_wprt[0] !== 1'b0)
            bad("fdi_same_drive_fill: a refused file left the drive locked");
        ref_load(0);
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy)
            bad("fdi_same_drive_fill: the mounted image is not ready");
        check_bh("fdi_same_drive_fill the mount won back");
        case_end("fdi_same_drive_fill");

        // ---------------- fdi_slot_wprotect ----------------
        // The OSD can hand a drive an FDI while its hps slot still holds a
        // disk image: a download touches no mount. From that clock the
        // drive's image is the downloaded file and the slot holds somebody
        // else's: the drive is locked, and a block of it never reaches that
        // slot. A block can be on its way out in two ways - the store has not
        // presented it yet, and the write-back is already standing in the
        // host's queue - and both end on the same line: the presentation is
        // acknowledged, and the file keeps the bytes the OSD mounted there.
        // (A write to a drive whose image is already a file never becomes
        // dirty at all - fdd_store marks only a TRD's or a CP/M's blocks
        // dirty, which is the same rule from the store's side, and
        // `fdi_write_volatile` is its case.)
        host_case_start();
        mon_memchk = -1;
        host_mount(2'b01, 64'd16384, 1'b0);
        expect_cfg("fdi_slot_wprotect A", 1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_rdy("fdi_slot_wprotect A");
        if (hs_wprt[0] !== 1'b0)
            bad("fdi_slot_wprotect: a mounted writable file is locked");
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("fdi_slot_wprotect: t0s0 is not ready");
        // (the request is also the settle point the store's write port wants:
        // a write toggled while its fill FSM is still eating the ready word is
        // a write nobody queued)

        // A block is dirty and the store is copying it out to the host port
        // when the OSD hands this drive a file. The copy pauses - the download
        // owns the host - the file lands, and the copy comes back to a drive
        // whose image is now that file: it is acknowledged and never asked of
        // the host, so the slot, which still holds the image the OSD mounted,
        // keeps every byte of it.
        drn0 = mon_drn;
        wr_sector(1'b0, 1'b0, 7'd0, 8'd0, 8'd0, 8'd3, 3'd1, 256, 1, 8'd0);
        k = 0;
        while (mon_drn == drn0 && k < DN_BUDGET) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (mon_drn == drn0)
            tfail("fdi_slot_wprotect: the dirty block was never presented");
        // wait until the module really holds the block: that is the state the
        // file has to overtake, and the only one in which the answer can come
        // from the check after the copy rather than from the dispatch
        k = 0;
        while (src.dn_act !== 1'b1 && k < FILL_ALL) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (src.dn_act !== 1'b1)
            tfail("fdi_slot_wprotect: the block was never taken for its copy");
        mon_reset();                      // no request of ours from here on
        dl_load(0);                       // its header: not protected
        host_download(16'd1, 1);          // claimed inside the copy
        wait_rdy_n("fdi_slot_wprotect the FDI", 1);
        if (mon_rdy !== 1)
            bad("fdi_slot_wprotect: the FDI never reached the drive");
        if (hs_wprt[0] !== 1'b1)
            bad("fdi_slot_wprotect: an FDI over a mounted file is writable");
        quiet_writes("fdi_slot_wprotect: an FDI's block", 12000);
        e0 = 0;
        for (k = 0; k < 256; k = k + 1)
            if (hps.mem[0][512 + k] !== himg[512 + k]) e0 = e0 + 1;
        if (e0 != 0) begin
            $display("FAIL fdi_slot_wprotect: %0d bytes of slot a changed", e0);
            errors = errors + 1;
        end
        // The read-only mount is the half of this the store cannot see: its
        // config word carries no read-only bit, so the block IS presented and
        // this module is the one that must not ask the host for it.
        mon_reset();
        host_mount(2'b01, 64'd16384, 1'b1);
        expect_cfg("fdi_slot_wprotect read-only", 1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_rdy("fdi_slot_wprotect read-only");
        if (hs_wprt[0] !== 1'b1)
            bad("fdi_slot_wprotect: a read-only mount left the drive open");
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("fdi_slot_wprotect: the read-only track is not ready");
        drn0 = mon_drn;
        wr_sector(1'b0, 1'b0, 7'd0, 8'd0, 8'd0, 8'd3, 3'd1, 256, 1, 8'd0);
        k = 0;
        while (mon_drn == drn0 && k < DN_BUDGET) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (mon_drn == drn0)
            bad("fdi_slot_wprotect: a read-only drive's block never came");
        quiet_writes("fdi_slot_wprotect: a read-only drive's block", 8000);
        e0 = 0;
        for (k = 0; k < 256; k = k + 1)
            if (hps.mem[0][512 + k] !== himg[512 + k]) e0 = e0 + 1;
        if (e0 != 0) begin
            $display("FAIL fdi_slot_wprotect: %0d bytes of the read-only slot changed", e0);
            errors = errors + 1;
        end
        // A file that dies after its config - 33 records in one block - is
        // still a file, so the drive stays locked: on a writable mount that is
        // the difference between a protected half-built image and a drive
        // handing its blocks to a slot that never held them.
        mon_reset();
        host_mount(2'b01, 64'd16384, 1'b0);
        expect_cfg("fdi_slot_wprotect writable", 1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_rdy("fdi_slot_wprotect writable");
        mon_reset();
        dl_load(8);                               // dl33.fdi: flag clear too
        host_download(16'd1, 2);
        quiet("the 33-record block", 0, 1, 6000);
        if (mon_cfg !== 1)
            bad("fdi_slot_wprotect: the 33-record header never reached the store");
        if (hs_wprt[0] !== 1'b1)
            bad("fdi_slot_wprotect: a refused FDI left the drive writable");
        quiet_writes("fdi_slot_wprotect: after the refused file", 4000);

        // Only a mount ends the image: with a file behind the drive again the
        // lock goes, and a write-back works from that clock on.
        mon_reset();
        host_mount(2'b01, 64'd16384, 1'b0);
        expect_cfg("fdi_slot_wprotect remount", 1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_rdy("fdi_slot_wprotect remount");
        if (hs_wprt[0] !== 1'b0)
            bad("fdi_slot_wprotect: the mount left the drive locked");
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("fdi_slot_wprotect: the remounted track is not ready");
        drn0 = mon_drn;
        wr_sector(1'b0, 1'b0, 7'd0, 8'd0, 8'd0, 8'd3, 3'd1, 256, 1, 8'd0);
        k = 0;
        while (mon_drn == drn0 && k < DN_BUDGET) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (mon_drn == drn0)
            tfail("fdi_slot_wprotect: the remounted block never went back");
        wait_write_done("fdi_slot_wprotect");
        e0 = 0;
        for (k = 0; k < 256; k = k + 1)
            if (hps.mem[0][512 + k] !== pat(1, k, 8'd0)) e0 = e0 + 1;
        if (e0 != 0) begin
            $display("FAIL fdi_slot_wprotect: %0d of the block's bytes missed slot a",
                     e0);
            errors = errors + 1;
        end
        case_end("fdi_slot_wprotect");

        // ---------------- claim_over_sdreq ----------------
        // A download claimed while a sector read of the other drive is
        // standing in the host's queue: the host that has to answer the read
        // is the host that is waiting for the file, so a module that keeps
        // waiting for its read is waiting for itself. The request goes back,
        // the file arrives, and the read is asked again afterwards - a fill
        // word carries its own address, so a withdrawn sector costs bytes and
        // never the image.
        host_case_start();
        mon_memchk = -1;
        hs_status      = 128'd0;
        hs_status[34]  = 1'b1;
        host_mount(2'b10, 64'd16384, 1'b0);
        expect_cfg("claim_over_sdreq B", 1'b1, KIND_TRD, 7'd2, 1'b1);
        wait_push(300);
        hold_ack = 2'b10;                 // the host stops answering B
        // and the engine comes to rest on that read: waiting there is what the
        // fix has to end, so the case waits until it really is waiting
        k = 0;
        while (!(src.st === 5'd5 && src.rd_gate === 1'b1) && k < FILL_ALL) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (!(src.st === 5'd5 && src.rd_gate === 1'b1))
            tfail("claim_over_sdreq: the fill never came to rest on its read");
        mon_reset();
        dl_load(0);
        host_download(16'd1, 1);          // A's file, while A itself is idle
        hold_ack = 2'b00;
        if (mon_rdy !== 1)
            bad("claim_over_sdreq: the file behind a standing request never arrived");
        ref_load(3);
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("claim_over_sdreq: the downloaded track is not ready");
        check_bh("claim_over_sdreq dl t0s1");
        // and B, whose read was withdrawn, reads again and comes up
        wait_rdy_n("claim_over_sdreq B after the window", 2);
        req_track(1'b1, 1'b0, 7'd0, rdy);
        if (!rdy) bad("claim_over_sdreq: drive B never came up");
        case_end("claim_over_sdreq");

        // ---------------- claim_at_fill_ready ----------------
        // The last word a fill sends is its ready, and the store is one push
        // away from a usable drive when a download is claimed on that very
        // clock. Yielding then throws away the end of a fill that is otherwise
        // complete - the drive has to be built a second time - while the file
        // could wait the few clocks the push takes.
        host_case_start();
        mon_memchk = -1;
        hs_status      = 128'd0;
        hs_status[34]  = 1'b1;
        host_mount(2'b10, 64'd16384, 1'b0);
        expect_cfg("claim_at_fill_ready B", 1'b1, KIND_TRD, 7'd2, 1'b1);
        // the clock *before* the push. A claim is three clocks old by the time
        // it reaches `dl_takes`, and the store's ack of the word is weighed
        // four clocks after the push goes out: a hook that waits for the push
        // state is always one decision too late. E_F_OK is the state whose
        // next word is the ready - "the last byte: ready" - so waiting for it
        // is waiting for the push without being in it.
        dl_load(0);                   // its bytes: prepared before the claim
        k = 0;
        while (src.st !== 5'd12 && k < FILL_ALL) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (k >= FILL_ALL)
            tfail("claim_at_fill_ready: the fill never reached its ready push");
        by0 = mon_bytes;              // B's own bytes end at this last word
        // The claim on this very clock. The ready push is open only for the
        // clocks its ack takes, and the ack is what the yield is weighed on,
        // so the window has to be claimed before that - a task call that
        // first waits for an edge is one clock too late, which is how this
        // case let the mutant through.
        #1;
        io_index    = 16'd1;
        io_download = 1'b1;
        // the premise, measured: the window has to be claimed while the engine
        // is still waiting for the store to take that word. A claim that lands
        // after the ack tests nothing at all, and a case that tests nothing
        // keeps passing - which is how this one let the mutant through once.
        k = 0;
        prem_hit = 1'b0;
        while (k < 12 && !prem_hit) begin
            @(posedge bclk);
            #1;
            if (src.dl_takes === 1'b1 && src.st === 5'd2)
                prem_hit = 1'b1;
            k = k + 1;
        end
        if (!prem_hit)
            tfail("claim_at_fill_ready: the claim missed the ready push");
        host_stream(16'd1, 1);
        // Both images are whole: one config and one ready for B, one of each
        // for A's file. A second config for B is the ready that was dropped
        // and the fill that then had to run again.
        wait_rdy_n("claim_at_fill_ready both images", 2);
        if (mon_cfg !== 2 || mon_rdy !== 2) begin
            $display("FAIL claim_at_fill_ready: %0d configs, %0d readies",
                     mon_cfg, mon_rdy);
            errors = errors + 1;
        end
        // and B paid for its image once: its data was all in the store at the
        // claim clock, so a yield at the ready word would walk the whole 16384
        // a second time to say the word the store had already taken
        if (mon_bytes - by0 !== dl_n - {dl_mem[11], dl_mem[10]}) begin
            $display("FAIL claim_at_fill_ready: %0d bytes after the claim, the file is %0d",
                     mon_bytes - by0, dl_n - {dl_mem[11], dl_mem[10]});
            errors = errors + 1;
        end
        quiet("the fill of B", 1, 1, 40_000);
        ref_load(3);
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("claim_at_fill_ready: the downloaded track is not ready");
        check_bh("claim_at_fill_ready dl t0s1");
        req_track(1'b1, 1'b0, 7'd0, rdy);
        if (!rdy) bad("claim_at_fill_ready: drive B is not ready");
        case_end("claim_at_fill_ready");

        // ---------------- download_wins_refill ----------------
        // A download the host has handed its bytes to is a promise: that file
        // is the drive's image, whoever else was waiting for the port. So a
        // pending fill of the same drive - the re-fill this module asked for
        // itself when the download displaced the first one - never takes the
        // port back. A mount is the only thing that outranks a claimed file,
        // and it is the only thing that can end one.
        host_case_start();
        mon_memchk = -1;
        hs_status      = 128'd0;
        hs_status[34]  = 1'b1;
        host_mount(2'b01, 64'd16384, 1'b0);
        expect_cfg("download_wins_refill A", 1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_push(300);
        hold_ack = 2'b01;                 // the host stops answering A
        // the engine comes to rest on that read before the claim lands
        k = 0;
        while (!(src.st === 5'd5 && src.rd_gate === 1'b1) && k < FILL_ALL) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (!(src.st === 5'd5 && src.rd_gate === 1'b1))
            tfail("download_wins_refill: the fill never came to rest on its read");
        mon_reset();
        dl_load(0);
        host_download(16'd1, 1);          // A's own file, claimed now
        hold_ack = 2'b00;
        wait_rdy_n("download_wins_refill the file", 1);
        if (mon_cfg !== 1 || mon_rdy !== 1) begin
            $display("FAIL download_wins_refill: %0d configs, %0d readies",
                     mon_cfg, mon_rdy);
            errors = errors + 1;
        end
        if (mon_cfgw !== {2'd0, 1'b0, KIND_FDI, 7'd1, 1'b1, 19'd0})
            bad("download_wins_refill: the drive's config is not the file's");
        quiet("A after its own file", 1, 1, 120_000);
        ref_load(3);
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("download_wins_refill: the file's track is not ready");
        check_bh("download_wins_refill the file kept its drive");
        case_end("download_wins_refill");

        // ---------------- claim_at_mount_dispatch ----------------
        // A mount's dispatch was the one clock that used to erase a window
        // claimed on it: the dispatcher cleared dl_own/dl_req of the drive it
        // dispatched for, after the claim had set them, and the last write
        // won - the window was gone, ioctl_wait never rose, and the file
        // streamed past into nothing. The dispatch may not touch a download
        // at all: fl_go cannot fire while a window stands, and the E_L_WT
        // drop ends a streaming file when its mount crosses, so the dispatch
        // is never the one to clean anything up.
        host_case_start();
        mon_memchk = -1;
        hs_status = 128'd0;
        host_mount(2'b01, 64'd16384, 1'b0);
        expect_cfg("claim_at_mount_dispatch A", 1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_rdy("claim_at_mount_dispatch A");
        dl_load(0);
        host_download(16'd1, 1);              // the previous download: drive A's
        wait_rdy_n("claim_at_mount_dispatch the first file", 2);
        mon_reset();
        // Remount the same drive and claim a new window on that mount's
        // dispatch clock. The armed condition below is exactly one clock
        // before the dispatch: E_IDLE, the event pending, and nothing
        // running to serialise the dispatch behind.
        host_mount(2'b01, 64'd16384, 1'b0);
        k = 0;
        prem_hit = 1'b0;
        while (k < MNT_BUDGET && !prem_hit) begin
            @(posedge bclk);
            #1;
            if (src.st === 5'd0 && src.chg_pend[0] === 1'b1 &&
                src.fl_act === 1'b0 && src.dl_own === 1'b0)
                prem_hit = 1'b1;
            k = k + 1;
        end
        if (!prem_hit)
            tfail("claim_at_mount_dispatch: the mount never armed the dispatcher");
        io_index    = 16'd1;
        io_download = 1'b1;                   // claimed on the dispatch clock
        @(posedge bclk);
        #1;
        // The premise, measured on the wire: this very clock dispatched the
        // mount - the module is pushing its config - and the window is
        // standing behind it. A claim one clock late would test nothing.
        if (!(src.st === 5'd1 && src.dl_own === 1'b1 && src.dl_req === 1'b1)) begin
            $display("FAIL claim_at_mount_dispatch: the claim did not survive the dispatch clock (st=%0d own=%b req=%b)",
                     src.st, src.dl_own, src.dl_req);
            errors = errors + 1;
        end
        host_stream(16'd1, 1);
        // Both halves of the race land: the mount's config was pushed, the
        // file streamed behind it and became the drive's image, and the fill
        // it displaced stays suppressed behind the file.
        wait_rdy_n("claim_at_mount_dispatch the file", 1);
        if (mon_cfg !== 2 || mon_rdy !== 1) begin
            $display("FAIL claim_at_mount_dispatch: %0d configs, %0d readies",
                     mon_cfg, mon_rdy);
            errors = errors + 1;
        end
        if (mon_cfgw !== {2'd0, 1'b0, KIND_FDI, 7'd1, 1'b1, 19'd0})
            bad("claim_at_mount_dispatch: the drive's config is not the file's");
        quiet("claim_at_mount_dispatch: the suppressed refill", 1, 1, 60_000);
        if (hs_wprt[0] !== 1'b1)
            bad("claim_at_mount_dispatch: the downloaded drive is writable");
        ref_load(3);
        req_track(1'b0, 1'b1, 7'd0, rdy);
        if (!rdy) bad("claim_at_mount_dispatch: the file's track is not ready");
        check_bh("claim_at_mount_dispatch the file won the race");
        case_end("claim_at_mount_dispatch");

        // ---------------- mount_at_header_accept ----------------
        // A mount whose crossing lands on the very clock the FDI header is
        // accepted used to leave the drive's fdi bit behind the new image:
        // the crossing clears the bit and the header state writes it on that
        // same clock, the later write. The remounted TRD then read write-
        // protected until the next mount, and its blocks never went back to
        // the host. The dispatch of that mount is the last word about the
        // drive's image: it is the clock that clears the bit.
        host_case_start();
        mon_memchk = -1;
        hs_status = 128'd0;
        host_mount(2'b01, 64'd16384, 1'b0);   // drive A's, writable
        expect_cfg("mount_at_header_accept A", 1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_rdy("mount_at_header_accept A");
        mon_reset();   // the header and the remount, alone, from here
        dl_load(0);
        // The claim and the header's first thirteen bytes, one at a time:
        // the file has to stop one byte short of the header, so that the
        // fourteenth one completes it on the mount's own crossing clock.
        @(posedge bclk);
        #1;
        io_index    = 16'd1;
        io_download = 1'b1;
        m_w = 0;
        while (m_w < 8 && (io_wait !== 1'b1)) begin
            @(posedge bclk);
            #1;
            m_w = m_w + 1;
        end
        if (io_wait !== 1'b1)
            tfail("mount_at_header_accept: the window was never claimed");
        for (k = 0; k < 13; k = k + 1) begin
            m_w = 0;
            while ((io_wait === 1'b1) && m_w < FILL_BUDGET) begin
                @(posedge bclk);
                #1;
                m_w = m_w + 1;
            end
            if (m_w >= FILL_BUDGET)
                tfail("mount_at_header_accept: the wait never fell");
            io_dout = dl_mem[k];
            io_wr   = 1'b1;
            @(posedge bclk);                  // the strobe is sampled on this
            #1;
            io_wr   = 1'b0;                   // clock, and it carries the byte
            if (io_wait !== 1'b1)
                tfail("mount_at_header_accept: a header byte was never taken");
        end
        // The remount while the file holds its fourteenth byte back: the
        // settle runs under the stall from here on.
        host_mount(2'b01, 64'd16384, 1'b0);
        // The fourteenth byte is strobed on the settle's last clock. A
        // remount of the same size changes nothing about it, so the settle
        // commits on its ev_age branch here: the post-edge ev_age reading
        // MNT_WAIT means the commit is the next posedge, and the crossing is
        // three clocks after it - the very clock the byte completes the
        // header on.
        k = 0;
        prem_hit = 1'b0;
        while (k < 12_288 && !prem_hit) begin
            @(posedge bclk);
            #1;
            if (src.ev_age === 13'd4095) prem_hit = 1'b1;
            k = k + 1;
        end
        if (!prem_hit) tfail("mount_at_header_accept: the settle clock was missed");
        if (io_wait === 1'b1)
            tfail("mount_at_header_accept: the engine did not wait for the byte");
        io_dout = dl_mem[13];
        io_wr   = 1'b1;
        @(posedge bclk);                      // C: the commit edge takes the byte
        #1;
        io_wr   = 1'b0;
        if (io_wait !== 1'b1)
            tfail("mount_at_header_accept: byte 14 was never taken");
        // The premise, measured: E_L_HDR, and the crossing not yet consumed
        // - they meet on the next posedge.
        k = 0;
        prem_hit = 1'b0;
        while (k < 6 && !prem_hit) begin
            @(posedge bclk);
            #1;
            if (src.st === 5'd24 && (src.cg_s2 !== src.cg_seen)) prem_hit = 1'b1;
            k = k + 1;
        end
        if (!prem_hit)
            tfail("mount_at_header_accept: the crossing missed the header clock");
        @(posedge bclk);
        #1;
        // The header won its own clock: the bit is up over the crossing's
        // clear. Both the fixed and the unfixed module do this here - what
        // parts them is what the mount's dispatch does a few clocks later.
        if (!(src.fdi[0] === 1'b1 && src.chg_pend[0] === 1'b1))
            tfail("mount_at_header_accept: the header and the mount did not overlap");
        // The download lets go of the mount it finds pending, and the mount
        // comes in over the header's config.
        expect_cfg("mount_at_header_accept the header's config",
                   1'b0, KIND_FDI, 7'd1, 1'b1);
        expect_cfg("mount_at_header_accept the mount's config",
                   1'b0, KIND_TRD, 7'd2, 1'b1);
        wait_rdy("mount_at_header_accept the remounted image");
        if (mon_rdy !== 1)
            bad("mount_at_header_accept: the dropped download sent a ready");
        io_download = 1'b0;                   // the window died with the drop
        if (hs_wprt[0] !== 1'b0)
            bad("mount_at_header_accept: the header left the remounted image write-protected");
        // The fix is about the drive, not the bit: a block of the remounted
        // TRD has to reach the host again.
        req_track(1'b0, 1'b0, 7'd0, rdy);
        if (!rdy) bad("mount_at_header_accept: the remounted track is not ready");
        sdw0 = mon_sdwr;
        wr_sector(1'b0, 1'b0, 7'd0, 8'd0, 8'd0, 8'd3, 3'd1, 256, 1, 8'd0);
        k = 0;
        while (mon_sdwr === sdw0 && k < 60_000) begin
            @(posedge bclk);
            k = k + 1;
        end
        if (mon_sdwr === sdw0)
            bad("mount_at_header_accept: the remounted image never wrote a block back");
        quiet("mount_at_header_accept: the dropped download", 0, 1, 20_000);
        case_end("mount_at_header_accept");

        // ---------------- fdi_block_past_window ----------------
        // The record check against the store's 2 MiB window read the block's
        // DataOffset through a 23-bit saturation: an offset at or past the
        // window's end came back as the largest base inside it, and the sum
        // wrapped under the comparison. The one offset that is certainly
        // outside the window passed the check, and such a file got its
        // ready - a drive whose records point at bytes nobody streamed.
        host_case_start();
        mon_memchk = -1;
        dl_load(0);
        dl_mem[16'h0E] = 8'h00;               // the first block's DataOffset:
        dl_mem[16'h0F] = 8'h00;               // 0x200000, the first byte past
        dl_mem[16'h10] = 8'h20;               // the store's window
        dl_mem[16'h11] = 8'h00;
        host_download(16'd1, 1);
        // The config's clock is the header's, inside the stream, so the
        // check is a level: one config, the file's, and the module's own
        // flag that the record check did fire (the old module never set it
        // for exactly this file).
        if (mon_cfg !== 1 ||
            mon_cfgw !== {2'd0, 1'b0, KIND_FDI, 7'd1, 1'b1, 19'd0})
            bad("fdi_block_past_window: the file's config did not arrive");
        if (src.max_bad !== 1'b1)
            bad("fdi_block_past_window: a block based at 2 MiB passed the window check");
        quiet("fdi_block_past_window: the refused file", 0, 1, 40_000);
        if (mon_cfg !== 1 || mon_rdy !== 0) begin
            $display("FAIL fdi_block_past_window: %0d configs, %0d readies",
                     mon_cfg, mon_rdy);
            errors = errors + 1;
        end
        if (hs_wprt[0] !== 1'b1)
            bad("fdi_block_past_window: the refused file left the drive writable");
        case_end("fdi_block_past_window");

        // ---------------- fdi_tpos_wrap ----------------
        // The byte cursor is 24 bits, and a file whose data area ran past
        // 16 MiB wrapped it back to zero: dat_pos re-entered the store's
        // window and the end of the file rewrote the start of the drive.
        // Streaming 16 MiB is not a simulation worth running, so the case
        // pokes the cursor to the very end of its count and hands it the
        // rest of the file instead.
        host_case_start();
        mon_memchk = -1;
        dl_load(0);
        @(posedge bclk);
        #1;
        io_index    = 16'd1;
        io_download = 1'b1;
        m_w = 0;
        while (m_w < 8 && (io_wait !== 1'b1)) begin
            @(posedge bclk);
            #1;
            m_w = m_w + 1;
        end
        if (io_wait !== 1'b1) tfail("fdi_tpos_wrap: the window was never claimed");
        // stream the header and the table until the data area begins
        k = 0;
        while (k < dl_n && !(src.dl_phase === 2'd2 && src.st === 5'd22)) begin
            m_w = 0;
            while ((io_wait === 1'b1) && m_w < FILL_BUDGET) begin
                @(posedge bclk);
                #1;
                m_w = m_w + 1;
            end
            if (m_w >= FILL_BUDGET) tfail("fdi_tpos_wrap: the wait never fell");
            io_dout = dl_mem[k];
            io_wr   = 1'b1;
            @(posedge bclk);
            #1;
            io_wr   = 1'b0;
            if (io_wait !== 1'b1) tfail("fdi_tpos_wrap: a byte was never taken");
            k = k + 1;
        end
        if (k >= dl_n) tfail("fdi_tpos_wrap: the data area never began");
        // the poke: one clock left on the cursor, and the small offset
        // the wrapped dat_pos would land on
        src.off_data = 16'd14;
        src.t_pos    = 24'hFF_FFFF;
        m2_b0        = mon_bytes;
        while (k < dl_n) begin
            m_w = 0;
            while ((io_wait === 1'b1) && m_w < FILL_BUDGET) begin
                @(posedge bclk);
                #1;
                m_w = m_w + 1;
            end
            if (m_w >= FILL_BUDGET) tfail("fdi_tpos_wrap: the wait never fell");
            io_dout = dl_mem[k];
            io_wr   = 1'b1;
            @(posedge bclk);
            #1;
            io_wr   = 1'b0;
            if (io_wait !== 1'b1) tfail("fdi_tpos_wrap: a byte was never taken");
            k = k + 1;
        end
        io_download = 1'b0;                   // the file is over: the window
        m_w = 0;                              // ends with its ready
        while ((io_wait === 1'b1) && m_w < 400) begin
            @(posedge bclk);
            #1;
            m_w = m_w + 1;
        end
        wait_rdy_n("fdi_tpos_wrap: the file that ended past the wrap", 1);
        if (mon_bytes !== m2_b0) begin
            $display("FAIL fdi_tpos_wrap: %0d fill bytes landed after the wrapped cursor",
                     mon_bytes - m2_b0);
            errors = errors + 1;
        end
        if (src.t_pos !== 24'hFF_FFFF)
            bad("fdi_tpos_wrap: the cursor wrapped instead of saturating");
        if (mon_cfg !== 1)
            bad("fdi_tpos_wrap: the wrapped file sent more than its config");
        case_end("fdi_tpos_wrap");

        // ---------------- verdict ----------------
        $display("tb_fdd_img: %0d errors", errors);
        if (errors == 0) $display("tb_fdd_img: PASS");
        else             $display("tb_fdd_img: FAIL %0d checks failed", errors);
        $finish;
    end : test

endmodule

`default_nettype wire
