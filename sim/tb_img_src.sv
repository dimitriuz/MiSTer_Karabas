// Testbench for rtl/disk/img_src.sv, the sector engine behind the two IDE
// images: hps_io disk slots 4 and 5 on clk_sys, the sdc_* sector interface
// (img_sdc's, as hdf_ata drives it) on clk.
//
// The DUTs: img_src, and the upstream hdf_ata (no rewrites) as its customer
// on the IDE bus; sim/models/hps_disk_model.sv stands in for hps_io's SD
// block transport. The bench talks to the machine on hdf_ata's bus: register
// writes and reads through the task file, and 16-bit data words for a sector,
// at clk. The image is built in SV in the model's memory: 1024 sectors,
// sector 0 the RDSK geometry (cyl 1, spt 63, heads 16), sector 1
// "KARABAS HDF\n" + (i*7+3) & 0xFF, the rest a per-sector pattern.
//
// Cases (each prints `PASS <case>` or `FAIL <case> <reason>`):
//   ident                IDENTIFY DEVICE on device 0: words 0, 1, 3, 6, 47,
//                        60, 61; sdc_img_mounted is a strobe (8 clk) that
//                        names the slot and sdc_img_size its size;
//   read_sector          READ SECTORS LBA 1: all 512 bytes;
//   write_sector         WRITE SECTORS LBA 1 with 0x3C: the HPS memory has
//                        it, and a second READ through the engine returns it
//                        (the sector is restored afterwards);
//   dev1                 mount slot b only: IDENTIFY on device 1 works,
//                        dev1_here is high;
//   no_image             ejected: the status register reads 0, a command
//                        leaves it 0, the bench does not time out;
//   dev1_absent          device 1 with no image reads 0 while device 0
//                        still answers;
//   short_image          (raw requester) img_size 612: LBA 1 gives 100 bytes
//                        then zeros and no past_end, LBA 2 gives zeros and
//                        past_end;
//   remount_mid_transfer (raw) the mount of a different image while a READ
//                        streams: the command ends with the old bytes, the
//                        next READ returns the new image's sector;
//   eject_mid_transfer   (raw) an eject during a transfer: the command ends
//                        (with or without error), the next one errors;
//   slow_hps             (raw) LAT_CLKS = 50000: the read still passes.
//
// The raw cases hold hdf_ata in reset and drive the sdc bus from the bench,
// so mount events can be placed inside a transfer without hdf_ata's own
// mount examination taking the bus.
//
// The last line printed is `tb_img_src: PASS` or
// `tb_img_src: FAIL <reason>`; run via sim/run_tb_img_src.sh (iverilog
// -g2012).
`timescale 1ns / 1ps
`default_nettype none

module tb_img_src;

    // ---------------- clocks ----------------
    reg clk_sys = 1'b0;                     // hps_io side, 50 MHz
    always #10 clk_sys = ~clk_sys;

    reg clk = 1'b0;                         // CLK_BUS, 28.125 MHz
    always #17.7778 clk = ~clk;

    localparam integer SECTORS = 1024;
    localparam [63:0] FULL = 64'd524288;     // SECTORS * 512

    // ---------------- mount and hps_io side ----------------
    reg  [1:0]  img_mounted = 2'b00;
    reg  [63:0] img_size = 64'd0;

    wire [31:0] lba_a, lba_b;
    wire        rd_a, rd_b, wr_a, wr_b;
    wire        ack_a, ack_b;
    wire  [8:0] sd_buff_addr;
    wire  [7:0] sd_buff_dout;
    wire        sd_buff_wr;
    wire  [7:0] sd_buff_din_a, sd_buff_din_b;
    wire  [1:0] hps_past;

    // ---------------- the sdc bus (hdf_ata or the raw requester) ----------
    reg  raw_mode = 1'b0;
    reg  [7:0] raw_rd = 8'h00;
    reg  [7:0] raw_wr = 8'h00;
    reg [31:0] raw_sector = 32'd0;

    wire  [1:0]  hdf_rd, hdf_wr;            // hdf_ata's two indices: 0 dev0, 1 dev1
    wire [31:0]  hdf_sector;
    wire  [7:0]  hdf_out;
    wire  [7:0]  sdc_rd = raw_mode ? raw_rd : {2'b00, hdf_rd, 4'b0000};
    wire  [7:0]  sdc_wr = raw_mode ? raw_wr : {2'b00, hdf_wr, 4'b0000};
    wire [31:0]  sdc_sector = raw_mode ? raw_sector : hdf_sector;
    wire  [7:0]  sdc_byte_out_data = hdf_out;
    wire         sdc_busy, sdc_done, sdc_error;
    wire  [2:0]  sdc_slot;
    wire         sdc_byte_in_strobe;
    wire  [8:0]  sdc_byte_addr;
    wire  [7:0]  sdc_byte_in_data;
    wire  [7:0]  sdc_img_mounted;
    wire [63:0]  sdc_img_size;

    // ---------------- the machine's view: hdf_ata's IDE bus ----------------
    reg  [2:0]  ata_a = 3'd0;
    reg  [1:0]  ata_cs_n = 2'b11;
    reg         ata_rd_n = 1'b1, ata_wr_n = 1'b1;
    reg  [15:0] ata_din = 16'd0;
    wire [15:0] ata_dout;
    wire        ata_dev, dev1_here, ata_led;
    reg         hdf_reset = 1'b1;

    img_src dut (
        .clk_sys(clk_sys),
        .reset_sys(1'b0),
        .img_mounted(img_mounted),
        .img_size(img_size),
        .lba_a(lba_a),
        .rd_a(rd_a),
        .wr_a(wr_a),
        .ack_a(ack_a),
        .lba_b(lba_b),
        .rd_b(rd_b),
        .wr_b(wr_b),
        .ack_b(ack_b),
        .sd_buff_addr(sd_buff_addr),
        .sd_buff_dout(sd_buff_dout),
        .sd_buff_din_a(sd_buff_din_a),
        .sd_buff_din_b(sd_buff_din_b),
        .sd_buff_wr(sd_buff_wr),
        .clk(clk),
        .reset(1'b0),
        .sdc_rd(sdc_rd),
        .sdc_wr(sdc_wr),
        .sdc_sector(sdc_sector),
        .sdc_busy(sdc_busy),
        .sdc_done(sdc_done),
        .sdc_error(sdc_error),
        .sdc_slot(sdc_slot),
        .sdc_byte_in_strobe(sdc_byte_in_strobe),
        .sdc_byte_addr(sdc_byte_addr),
        .sdc_byte_in_data(sdc_byte_in_data),
        .sdc_byte_out_data(sdc_byte_out_data),
        .sdc_img_mounted(sdc_img_mounted),
        .sdc_img_size(sdc_img_size)
    );

    hdf_ata u_ata (
        .clk(clk),
        .reset(hdf_reset),
        .ata_reset(1'b0),
        .dev0_en(1'b1),
        .dev(ata_dev),
        .dev1_here(dev1_here),
        .a(ata_a),
        .cs_n(ata_cs_n),
        .rd_n(ata_rd_n),
        .wr_n(ata_wr_n),
        .din(ata_din),
        .dout(ata_dout),
        // exactly the top's wiring: the drive sees the engine's strobe and
        // the size it carries, not the HPS's own one-clk_sys pulse
        .img_mounted(sdc_img_mounted[5:4]),
        .img_size(sdc_img_size),
        .sdc_rd(hdf_rd),
        .sdc_wr(hdf_wr),
        .sdc_sector(hdf_sector),
        .sdc_busy(sdc_busy),
        .sdc_done(sdc_done),
        .sdc_error(sdc_error),
        .sdc_byte_in_strobe(sdc_byte_in_strobe),
        .sdc_byte_addr(sdc_byte_addr),
        .sdc_byte_in_data(sdc_byte_in_data),
        .sdc_byte_out_data(hdf_out),
        .led(ata_led)
    );

    hps_disk_model hps (
        .clk(clk_sys),
        .img_size(img_size),
        .rd({rd_b, rd_a}),
        .wr({wr_b, wr_a}),
        .lba_a(lba_a),
        .lba_b(lba_b),
        .ack({ack_b, ack_a}),
        .buff_addr(sd_buff_addr),
        .buff_dout(sd_buff_dout),
        .buff_wr(sd_buff_wr),
        .buff_din(sd_buff_din_a),
        .past_end(hps_past)
    );

    // the raw requester's copy of the sector the engine streamed
    reg [7:0] cap [0:511];
    always @(posedge clk)
        if (sdc_byte_in_strobe)
            cap[sdc_byte_addr] <= sdc_byte_in_data;

    // ---------------- the image ----------------
    localparam [95:0] HDF_SIG = "KARABAS HDF\n";

    function [7:0] img_byte;
        input integer sec;
        input integer off;
        begin
            if (sec == 0) begin
                if (off == 0)       img_byte = 8'h52;   // RDSK
                else if (off == 1)  img_byte = 8'h44;
                else if (off == 2)  img_byte = 8'h53;
                else if (off == 3)  img_byte = 8'h4B;
                else if (off == 7)  img_byte = 8'h00;   // size, big endian 512
                else if (off == 67) img_byte = 8'h01;   // cylinders
                else if (off == 71) img_byte = 8'h3F;   // sectors per track
                else if (off == 75) img_byte = 8'h10;   // heads
                else                img_byte = 8'h00;
            end else if (sec == 1) begin
                if (off < 12) img_byte = HDF_SIG[8 * (11 - off) +: 8];
                else          img_byte = (off * 7 + 3) & 8'hFF;
            end else
                img_byte = (sec * 13 + off * 5 + 1) & 8'hFF;
        end
    endfunction

    function [7:0] img_byte_b;                  // the "other" image of remount
        input integer off;
        begin
            img_byte_b = (off * 11 + 200) & 8'hFF;
        end
    endfunction

    // ---------------- checks ----------------
    integer errors = 0, case_errors = 0, shown = 0;
    integer n, i, off, ok, rok, rerr, low_cycles;
    reg  [7:0]  st;
    reg [15:0]  blk [0:255];
    reg [15:0]  w;

    // sdc_img_mounted is a strobe (hdf_ata re-examines the image for every
    // clock its bit is up), so the checks latch the last one and prove it
    // ends again; its width is the engine's 8 clk.
    reg  [7:0]  mount_last = 8'h00;

    always @(posedge clk)
        if (sdc_img_mounted !== 8'h00) mount_last <= sdc_img_mounted;

    task fail_int(input [8*20-1:0] cs, input [8*28-1:0] what,
                  input [63:0] got, input [63:0] want);
        begin
            if (got !== want) begin
                if (shown < 8)
                    $display("FAIL %0s %0s got %0d want %0d", cs, what, got, want);
                shown = shown + 1;
                errors = errors + 1;
            end
        end
    endtask

    task case_begin;
        begin case_errors = errors; shown = 0; end
    endtask

    task case_end(input [8*20-1:0] cs);
        begin
            if (errors == case_errors) $display("PASS %0s", cs);
            else $display("FAIL %0s (%0d checks failed)", cs, errors - case_errors);
        end
    endtask

    // ---------------- the host bus of hdf_ata ----------------
    task ata_wr(input [2:0] ad, input [15:0] d);
        begin
            ata_a = ad; ata_cs_n = 2'b10; ata_din = d; ata_wr_n = 1'b0;
            @(posedge clk); #1;
            @(posedge clk); #1;
            ata_wr_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    task ata_rd(input [2:0] ad, output [15:0] d);
        begin
            ata_a = ad; ata_cs_n = 2'b10; ata_rd_n = 1'b0;
            @(posedge clk); #1;
            @(posedge clk); #1;
            d = ata_dout;
            ata_rd_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    task ata_status(output [7:0] s);
        reg [15:0] v;
        begin
            ata_rd(3'd7, v);
            s = v[7:0];
        end
    endtask

    // wait for BSY to clear, bounded: ok = 0 is the bench's timeout
    task ata_wait(output [7:0] s, output integer done_ok);
        begin
            done_ok = 0; s = 8'hFF;
            for (n = 0; n < 6000 && !done_ok; n = n + 1) begin
                ata_status(s);
                if (!(s & 8'h80)) done_ok = 1;
            end
        end
    endtask

    task ata_read_block;
        begin
            for (i = 0; i < 256; i = i + 1) ata_rd(3'd0, blk[i]);
        end
    endtask

    task ata_write_block(input [15:0] v);
        begin
            for (i = 0; i < 256; i = i + 1) ata_wr(3'd0, v);
        end
    endtask

    // ---------------- mount, waits, raw requester ----------------
    task mount(input [1:0] bits, input [63:0] size);
        begin
            // Main's order as the board shows it: `0x1c` (the mount pulse,
            // one clk_sys, cleared inside the command) comes first and the
            // `0x1d` size words follow it in the same ioctl burst. A size
            // sampled on the pulse is the previous one - 0 at the first
            // mount - and the drive then never examines the image.
            img_mounted = bits;
            @(posedge clk_sys); #1;
            img_mounted = 2'b00;
            repeat (3) @(posedge clk_sys); #1;
            img_size = size;
            repeat (3) @(posedge clk_sys); #1;
        end
    endtask

    task wait_mounted(input [7:0] v, output integer done_ok);
        begin
            done_ok = 0;
            mount_last = 8'hFF;
            for (n = 0; n < 20000 && !done_ok; n = n + 1) begin
                @(posedge clk); #1;
                if (mount_last === v) done_ok = 1;
            end
        end
    endtask

    task wait_idle(output integer done_ok);
        begin
            done_ok = 0;
            for (n = 0; n < 20000 && !done_ok; n = n + 1) begin
                @(posedge clk_sys); #1;
                if (!sdc_busy && !rd_a && !rd_b && !wr_a && !wr_b &&
                    hps.ack == 2'b00 && !hps.buff_wr) done_ok = 1;
            end
        end
    endtask

    // one raw READ (no hdf_ata); the bytes land in cap
    task raw_read(input [2:0] idx, input [31:0] lba,
                  output integer got_done, output integer got_err);
        begin
            raw_rd = 8'h01 << idx;
            raw_sector = lba;
            @(posedge clk); #1;
            for (n = 0; n < 64 && !sdc_busy; n = n + 1) begin
                @(posedge clk); #1;
            end
            raw_rd = 8'h00;
            got_done = 0; got_err = 0;
            if (sdc_busy) begin
                for (n = 0; n < 40000 && !sdc_done; n = n + 1) begin
                    @(posedge clk); #1;
                end
                got_done = sdc_done;
                got_err = sdc_error;
            end
            @(posedge clk); #1;
        end
    endtask

    // start a raw READ and return while it runs
    task raw_start(input [2:0] idx, input [31:0] lba);
        begin
            raw_rd = 8'h01 << idx;
            raw_sector = lba;
            @(posedge clk); #1;
            for (n = 0; n < 64 && !sdc_busy; n = n + 1) begin
                @(posedge clk); #1;
            end
            raw_rd = 8'h00;
        end
    endtask

    // wait until the model has finished its burst (the buffer is full)
    task wait_hps_burst;
        begin
            for (n = 0; n < 400 && !hps.ack[0]; n = n + 1)
                @(posedge clk_sys); #1;
            for (n = 0; n < 4000 && hps.ack[0]; n = n + 1)
                @(posedge clk_sys); #1;
        end
    endtask

    task wait_engine_done(output integer got_done);
        begin
            got_done = 0;
            for (n = 0; n < 40000 && !got_done; n = n + 1) begin
                @(posedge clk); #1;
                if (sdc_done) got_done = 1;
            end
            @(posedge clk); #1;
        end
    endtask

    task build_image(input integer slot);
        begin
            for (i = 0; i < SECTORS; i = i + 1)
                for (off = 0; off < 512; off = off + 1)
                    hps.mem[slot][i * 512 + off] = img_byte(i, off);
        end
    endtask

    // one READ SECTORS command on the ATA bus, from the task file
    task ata_read_lba(input [31:0] lba, output integer done_ok);
        begin
            ata_wr(3'd2, 16'h0001);
            ata_wr(3'd3, {8'h00, lba[7:0]});
            ata_wr(3'd4, {8'h00, lba[15:8]});
            ata_wr(3'd5, {8'h00, lba[23:16]});
            ata_wr(3'd6, 16'h0040);                  // LBA, device 0
            ata_wr(3'd7, 16'h0020);                  // READ SECTORS
            ata_wait(st, done_ok);
            if (done_ok && !(st & 8'h08)) done_ok = 0;   // DRQ expected
            if (done_ok) ata_read_block;
        end
    endtask

    task ata_write_lba(input [31:0] lba, input [15:0] v, output integer done_ok);
        begin
            ata_wr(3'd2, 16'h0001);
            ata_wr(3'd3, {8'h00, lba[7:0]});
            ata_wr(3'd4, {8'h00, lba[15:8]});
            ata_wr(3'd5, {8'h00, lba[23:16]});
            ata_wr(3'd6, 16'h0040);                  // LBA, device 0
            ata_wr(3'd7, 16'h0030);                  // WRITE SECTORS
            ata_wait(st, done_ok);
            if (done_ok && !(st & 8'h08)) done_ok = 0;   // DRQ expected
            if (done_ok) begin
                ata_write_block(v);
                ata_wait(st, done_ok);
                if (done_ok && (st & 8'h01)) done_ok = 0;  // ERR
            end
        end
    endtask

    // ---------------- the run ----------------
    initial begin
        $display("tb_img_src: start");

        build_image(0);
        build_image(1);
        repeat (20) @(posedge clk);
        hdf_reset = 1'b0;
        repeat (10) @(posedge clk);

        // ---- ident ----
        case_begin;
        mount(2'b01, FULL);
        wait_mounted(8'h10, ok);
        fail_int("ident", "mounted", mount_last, 8'h10);
        fail_int("ident", "size", sdc_img_size, FULL);
        repeat (16) @(posedge clk);
        fail_int("ident", "strobe ended", sdc_img_mounted, 8'h00);
        wait_idle(ok);
        ata_wr(3'd6, 16'h0000);                  // device 0, CHS
        ata_wait(st, ok);
        fail_int("ident", "not busy", ok, 1);
        if (ok) begin
            ata_wr(3'd7, 16'h00EC);              // IDENTIFY DEVICE
            ata_wait(st, ok);
            fail_int("ident", "DRQ", st & 8'h08, 8'h08);
            if (ok) begin
                ata_read_block;
                fail_int("ident", "word0", blk[0], 16'h0040);
                fail_int("ident", "word1 cyl", blk[1], 16'd1);
                fail_int("ident", "word3 heads", blk[3], 16'd16);
                fail_int("ident", "word6 spt", blk[6], 16'd63);
                fail_int("ident", "word47", blk[47], 16'h8001);
                fail_int("ident", "word60", blk[60], 16'h0400);
                fail_int("ident", "word61", blk[61], 16'd0);
            end
        end
        case_end("ident");

        // ---- read_sector ----
        case_begin;
        ata_read_lba(32'd1, ok);
        fail_int("read_sector", "done", ok, 1);
        if (ok)
            for (i = 0; i < 256; i = i + 1) begin
                fail_int("read_sector", "low", blk[i][7:0], img_byte(1, i * 2));
                fail_int("read_sector", "high", blk[i][15:8], img_byte(1, i * 2 + 1));
            end
        case_end("read_sector");

        // ---- write_sector ----
        case_begin;
        ata_write_lba(32'd1, 16'h3C3C, ok);
        fail_int("write_sector", "done", ok, 1);
        wait_idle(ok);
        for (i = 0; i < 512; i = i + 1)
            fail_int("write_sector", "hps memory", hps.mem[0][512 + i], 8'h3C);
        ata_read_lba(32'd1, ok);
        fail_int("write_sector", "read back", ok, 1);
        if (ok)
            for (i = 0; i < 256; i = i + 1) begin
                fail_int("write_sector", "back low", blk[i][7:0], 8'h3C);
                fail_int("write_sector", "back high", blk[i][15:8], 8'h3C);
            end
        // put the sector back for the later cases
        ata_wr(3'd2, 16'h0001);
        ata_wr(3'd3, 16'h0001);
        ata_wr(3'd4, 16'h0000);
        ata_wr(3'd5, 16'h0000);
        ata_wr(3'd6, 16'h0040);
        ata_wr(3'd7, 16'h0030);
        ata_wait(st, ok);
        if (ok) begin
            for (i = 0; i < 256; i = i + 1)
                ata_wr(3'd0, {img_byte(1, i * 2 + 1), img_byte(1, i * 2)});
            ata_wait(st, ok);
        end
        wait_idle(ok);
        // the pattern bytes differ next to each other: reading the sector
        // back proves the write path kept every byte in its place
        ata_read_lba(32'd1, ok);
        fail_int("write_sector", "restored", ok, 1);
        if (ok)
            for (i = 0; i < 256; i = i + 1) begin
                fail_int("write_sector", "placed low", blk[i][7:0], img_byte(1, i * 2));
                fail_int("write_sector", "placed high", blk[i][15:8], img_byte(1, i * 2 + 1));
            end
        case_end("write_sector");

        // ---- dev1 ----
        case_begin;
        mount(2'b10, FULL);
        wait_mounted(8'h20, ok);
        fail_int("dev1", "mounted", mount_last, 8'h20);
        fail_int("dev1", "size", sdc_img_size, FULL);
        repeat (16) @(posedge clk);
        fail_int("dev1", "strobe ended", sdc_img_mounted, 8'h00);
        ata_wr(3'd6, 16'h0010);                  // DEV = 1
        ata_wait(st, ok);
        fail_int("dev1", "not busy", ok, 1);
        fail_int("dev1", "dev1_here", dev1_here, 1);
        fail_int("dev1", "dev", ata_dev, 1);
        if (ok) begin
            ata_wr(3'd7, 16'h00EC);              // IDENTIFY DEVICE
            ata_wait(st, ok);
            if (ok) begin
                ata_read_block;
                fail_int("dev1", "word0", blk[0], 16'h0040);
                fail_int("dev1", "word1 cyl", blk[1], 16'd1);
            end
        end
        ata_wr(3'd6, 16'h0000);                  // back to device 0
        case_end("dev1");

        // ---- no_image ----
        case_begin;
        // one mount per crossing: Main's commands are microseconds apart, far
        // more than the crossing takes, so each is waited out here too
        mount(2'b01, 64'd0);
        wait_mounted(8'h10, ok);
        fail_int("no_image", "mounted 0", mount_last, 8'h10);
        mount(2'b10, 64'd0);
        wait_mounted(8'h20, ok);
        fail_int("no_image", "mounted", mount_last, 8'h20);
        fail_int("no_image", "size", sdc_img_size, 64'd0);
        repeat (8) @(posedge clk);
        ata_rd(3'd7, w);
        fail_int("no_image", "status", w[7:0], 8'h00);
        ata_wr(3'd7, 16'h00EC);                  // a command with no device
        ata_rd(3'd7, w);
        fail_int("no_image", "status after", w[7:0], 8'h00);
        case_end("no_image");

        // ---- dev1_absent ----
        case_begin;
        mount(2'b01, FULL);
        wait_mounted(8'h10, ok);
        ata_wr(3'd6, 16'h0010);                  // device 1, no image
        ata_rd(3'd7, w);
        fail_int("dev1_absent", "status", w[7:0], 8'h00);
        ata_rd(3'd1, w);
        fail_int("dev1_absent", "error", w[7:0], 8'h00);
        ata_rd(3'd3, w);
        fail_int("dev1_absent", "sector", w[7:0], 8'h00);
        ata_wr(3'd6, 16'h0000);                  // device 0 still answers
        ata_wait(st, ok);
        fail_int("dev1_absent", "dev0 busy", ok, 1);
        fail_int("dev1_absent", "dev0 status", st & 8'h40, 8'h40);  // DRDY
        case_end("dev1_absent");

        // ---- the raw cases: hdf_ata off the bus ----
        hdf_reset = 1'b1;
        raw_mode = 1'b1;
        repeat (20) @(posedge clk);
        wait_idle(ok);

        // ---- short_image ----
        case_begin;
        hps.past_end = 2'b00;
        mount(2'b01, 64'd612);
        wait_mounted(8'h10, ok);
        raw_read(3'd4, 32'd1, rok, rerr);
        fail_int("short_image", "done", rok, 1);
        fail_int("short_image", "error", rerr, 0);
        fail_int("short_image", "past_end", hps_past[0], 0);
        for (i = 0; i < 100; i = i + 1)
            fail_int("short_image", "byte", cap[i], img_byte(1, i));
        for (i = 100; i < 512; i = i + 1)
            fail_int("short_image", "zero", cap[i], 8'h00);
        raw_read(3'd4, 32'd2, rok, rerr);
        fail_int("short_image", "lba2 done", rok, 1);
        fail_int("short_image", "lba2 past_end", hps_past[0], 1);
        for (i = 0; i < 512; i = i + 1)
            fail_int("short_image", "lba2 zero", cap[i], 8'h00);
        case_end("short_image");

        // ---- remount_mid_transfer ----
        case_begin;
        mount(2'b01, FULL);
        wait_mounted(8'h10, ok);
        raw_start(3'd4, 32'd1);
        wait_hps_burst;                          // the buffer holds the old sector
        for (i = 0; i < 512; i = i + 1)
            hps.mem[0][512 + i] = img_byte_b(i); // the next image's sector 1
        mount(2'b01, FULL);
        wait_engine_done(ok);
        fail_int("remount", "done", ok, 1);
        fail_int("remount", "error", sdc_error, 0);
        for (i = 0; i < 512; i = i + 1)
            fail_int("remount", "old byte", cap[i], img_byte(1, i));
        raw_read(3'd4, 32'd1, rok, rerr);
        fail_int("remount", "next done", rok, 1);
        for (i = 0; i < 512; i = i + 1)
            fail_int("remount", "new byte", cap[i], img_byte_b(i));
        case_end("remount_mid_transfer");

        // ---- eject_mid_transfer ----
        case_begin;
        build_image(0);
        mount(2'b01, FULL);
        wait_mounted(8'h10, ok);
        raw_start(3'd4, 32'd1);
        wait_hps_burst;
        mount_last = 8'hFF;                      // the eject's strobe, not the mount's
        mount(2'b01, 64'd0);
        wait_engine_done(ok);
        fail_int("eject", "done", ok, 1);        // completes or errors, no hang
        fail_int("eject", "mounted", mount_last, 8'h10);
        fail_int("eject", "size", sdc_img_size, 64'd0);
        repeat (8) @(posedge clk);
        raw_read(3'd4, 32'd1, rok, rerr);
        fail_int("eject", "next done", rok, 1);
        fail_int("eject", "next error", rerr, 1);
        case_end("eject_mid_transfer");

        // ---- slow_hps ----
        case_begin;
        hps.lat = 32'd50000;                     // 1 ms at 50 MHz
        mount(2'b01, FULL);
        wait_mounted(8'h10, ok);
        raw_read(3'd4, 32'd1, rok, rerr);
        fail_int("slow_hps", "done", rok, 1);
        fail_int("slow_hps", "error", rerr, 0);
        for (i = 0; i < 512; i = i + 1)
            fail_int("slow_hps", "byte", cap[i], img_byte(1, i));
        hps.lat = 32'd10;
        case_end("slow_hps");

        if (errors == 0) $display("tb_img_src: PASS");
        else $display("tb_img_src: FAIL %0d checks failed", errors);
        $finish;
    end

endmodule

`default_nettype wire