// tb_fdd_dlwin.sv - an FDI whose data area is longer than the store's window.
//
// fdd_src's download path drops an FDI byte that has nowhere to go: the store
// addresses a drive with 21 bits, so a byte at or past DL_MAX is neither
// wrapped onto the start of the drive nor allowed to hang the machine. Dropping
// it must be a *skip* and not an end: the byte after it belongs to the same
// data area, and the download still finishes with its ready word the way a file
// that is simply shorter than its header promised does.
//
// Two megabytes of stream is not something a simulation wants to push to reach
// that branch, so the window is made small by the compile-time switch
// `FDD_DL_SMALL` (sim/run_tb_fdd_dlwin.sh; the synthesis build never defines it
// and keeps the store's real 2 MiB window). With the small window the case
// streams 4 KiB + 320 bytes of data area and checks that exactly the first
// 4 KiB reach the store, in order, and that the download reports itself
// finished.
//
// The store itself is not here: the fill port is answered by a toggle-ack
// responder, and the only other piece of the picture is hps_io's byte source,
// which hands the file over one byte per clock of the core's choosing. Nothing
// is mounted, so the download is the only thing the engine can do.
//
// The verdict is the last line: `tb_fdd_dlwin: PASS` or
// `tb_fdd_dlwin: FAIL <reason>`.
//
// Timeouts are counted in clock edges, never by comparing $time: deep Icarus
// runs evaluate 64-bit time differences falsely (docs/dev/stage4-results).
`timescale 1ns/1ps

module tb_fdd_dlwin;

    reg bclk = 1'b0;
    always #10 bclk = ~bclk;          // 50 MHz, this DUT's clk_sys

    reg rst = 1'b1;

    // ---- the DUT's world: nothing is mounted, nothing writes --------------
    reg         io_dl    = 1'b0;
    reg  [15:0] io_index = 16'd0;
    reg         io_wr    = 1'b0;
    reg  [7:0]  io_dout  = 8'd0;
    wire        io_wait;

    wire        fill_tgl;
    wire [31:0] fill_word;
    reg         fill_ack = 1'b0;

    reg  [1:0]  sd_rd, sd_wr;
    reg  [31:0] sd_lba;
    wire [7:0]  sd_din;
    wire [1:0]  wprt;

    fdd_src u_fdd (
        .clk_sys        (bclk),
        .reset_sys      (rst),
        .img_mounted    (2'b00),
        .img_size       (64'd0),
        .img_readonly   (1'b0),
        .sd_rd          (sd_rd),
        .sd_wr          (sd_wr),
        .sd_lba         (sd_lba),
        .sd_ack         (2'b00),
        .sd_buff_addr   (9'd0),
        .sd_buff_dout   (8'd0),
        .sd_buff_din    (sd_din),
        .sd_buff_wr     (1'b0),
        .status         (128'd0),
        .ioctl_download (io_dl),
        .ioctl_index    (io_index),
        .ioctl_wr       (io_wr),
        .ioctl_addr     (27'd0),
        .ioctl_dout     (io_dout),
        .ioctl_wait     (io_wait),
        .wprt           (wprt),
        .fill_tgl       (fill_tgl),
        .fill_word      (fill_word),
        .fill_ack_tgl   (fill_ack),
        .drn_addr_b     (),
        .drn_q_b        (8'd0),
        .drn_tgl        (1'b0),
        .drn_info       (12'd0),
        .drn_ack_tgl    ()
    );

    // The store takes a word and answers a few clocks later: the toggle, not a
    // pulse, is the handshake (fdd_src watches it for any change).
    always @(fill_tgl) begin
        repeat (3) @(posedge bclk);
        fill_ack <= ~fill_ack;
    end

    // ---- what arrives at the fill port ------------------------------------
    localparam [22:0] WIN = 23'h01000;        // must match FDD_DL_SMALL

    integer n_push = 0, n_cfg = 0, n_rdy = 0, n_img = 0;
    integer n_seqbad = 0, n_x = 0, n_oob = 0, n_lost = 0;
    integer last_addr = -1;
    reg [31:0] last_word = 32'd0;

    always @(fill_tgl) begin
        #1;
        if (rst) begin
            last_word = fill_word;   // the word that came with reset
        end
        else begin
        n_push = n_push + 1;
        last_word = fill_word;
        if (^fill_word === 1'bx)               // a word with an X or Z in it
            n_x = n_x + 1;
        if (fill_word[31:30] == 2'd0) begin
            n_cfg = n_cfg + 1;
        end
        else if (fill_word[31:30] == 2'd2) n_rdy = n_rdy + 1;
        else if (!fill_word[29]) begin         // an image byte
            n_img = n_img + 1;
            if (fill_word[29:8] !== last_addr + 22'd1)
                n_seqbad = n_seqbad + 1;
            last_addr = fill_word[29:8];
            if (fill_word[29:8] >= WIN)
                n_oob = n_oob + 1;
        end
        end
    end

    integer errors = 0;

    task automatic fail(input [8*72-1:0] why);
        begin
            if (errors < 8)
                $display("FAIL %0s", why);
            errors = errors + 1;
        end
    endtask

    // ---- the forged file ---------------------------------------------------
    // 14-byte header: "FDI", the write-protect flag cleared, one cylinder, one
    // side, off_data straight behind the single block's one record. The record
    // sits at offset 0 of the data area and is one 128-byte sector, so every
    // record check the download makes passes whatever the window is: this case
    // is about the *stream* running past the window, not about a record asking
    // for bytes that are not there.
    localparam integer NDAT = 4352;            // 4 KiB + 320 bytes of data

    // hps_io's source side. ioctl_wr is a one-clock strobe that carries the
    // byte and hps_io itself never consults the wait, so the source may strobe
    // only when the core has said it is ready: between bytes it stops on the
    // wait, and a core that took a byte holds the wait up on the strobe clock,
    // which is what `taken` reads back. Nothing is strobed before the claim:
    // the first byte of a file is taken on the clock its window opens.
    task automatic send_byte(input [7:0] b);
        integer w;
        begin
            w = 0;
            while (io_wait === 1'b1 && w < 200_000) begin
                @(posedge bclk);
                #1;
                w = w + 1;
            end
            if (w >= 200_000)
                fail("the ioctl wait never fell");
            else begin
                io_dout = b;
                io_wr   = 1'b1;
                @(posedge bclk);               // the strobe is sampled on this
                #1;                            // clock, and it carries the byte
                if (io_wait !== 1'b1)
                    n_lost = n_lost + 1;
                io_wr = 1'b0;
            end
        end
    endtask

    integer k, kk, claimed;
    initial begin
        repeat (20) @(posedge bclk);
        rst <= 1'b0;
        repeat (20) @(posedge bclk);

        // the window opens: index 1 is drive A's FDI
        io_index = 16'd1;
        io_dl    = 1'b1;

        // the claim, before a single byte is strobed
        k = 0;
        while (io_wait !== 1'b1 && k < 8) begin
            @(posedge bclk);
            #1;
            k = k + 1;
        end
        if (io_wait !== 1'b1)
            fail("the download window was never claimed");

        // 14 header bytes: "FDI", wp flag 0, 1 cylinder, 1 side,
        // off_text = off_data = 28, size_ext 0
        send_byte(8'h46);  // 'F'
        send_byte(8'h44);  // 'D'
        send_byte(8'h49);  // 'I'
        send_byte(8'h00);
        send_byte(8'h01);  // cylinders, u16 low
        send_byte(8'h00);
        send_byte(8'h01);  // sides, u16 low
        send_byte(8'h00);
        send_byte(8'h1C);  // off_text, u16 low
        send_byte(8'h00);
        send_byte(8'h1C);  // off_data,  u16 low
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h00);

        // the block header: DataOffset u32, reserved u16, count
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h01);  // one record
        // the record: C, H, R, N, flags, offset u16
        send_byte(8'h00);
        send_byte(8'h00);
        send_byte(8'h01);
        send_byte(8'h00);  // N = 0: one 128-byte piece
        send_byte(8'h00);
        send_byte(8'h00);  // offset 0
        send_byte(8'h00);

        // the data area, past the window
        for (kk = 0; kk < NDAT; kk = kk + 1)
            send_byte(kk[7:0] ^ 8'hA5);
        claimed = io_wait;
        if (claimed !== 1)
            fail("ioctl_wait fell while the download still owned the window");

        // the window closes; the download must now push its ready
        io_dl = 1'b0;
        k = 0;
        while (n_rdy == 0 && k < 40_000) begin
            @(posedge bclk);
            k = k + 1;
        end
        repeat (40) @(posedge bclk);

        // ---------------- verdict ----------------
        if (n_lost != 0) begin
            $display("FAIL %0d bytes were strobed while the core was not ready (it lost them)", n_lost);
            errors = errors + 1;
        end
        if (n_x != 0) begin
            $display("FAIL a fill word carried X or Z (last word %h)", last_word);
            errors = errors + 1;
        end
        if (n_cfg != 1) begin
            $display("FAIL %0d fill configs, want the FDI's one", n_cfg);
            errors = errors + 1;
        end
        if (n_rdy != 1) begin
            $display("FAIL the download past the window never sent ready (%0d readies): the skip left the machine stuck", n_rdy);
            errors = errors + 1;
        end
        if (n_img !== WIN) begin
            $display("FAIL %0d image bytes, want exactly %0d (one per window address)", n_img, WIN);
            errors = errors + 1;
        end
        if (n_oob != 0) begin
            $display("FAIL %0d image bytes at or past the window address", n_oob);
            errors = errors + 1;
        end
        if (n_seqbad != 0) begin
            $display("FAIL %0d image bytes out of order (last address %0d)", n_seqbad, last_addr);
            errors = errors + 1;
        end
        if (last_addr !== WIN - 1) begin
            $display("FAIL the last image byte is at %0d, want %0d", last_addr, WIN - 1);
            errors = errors + 1;
        end
        if (sd_rd !== 2'b00 || sd_wr !== 2'b00)
            fail("a download asked the host for a sector it was never given");

        if (errors == 0)
            $display("tb_fdd_dlwin: PASS");
        else
            $display("tb_fdd_dlwin: FAIL %0d checks failed", errors);
        $finish;
    end

    // A run that hangs is a bug too: this watchdog prints the verdict instead
    // of letting the harness time out (edge-counted, as everything here).
    initial begin
        k = 0;
        while (k < 8_000_000) begin
            @(posedge bclk);
            k = k + 1;
        end
        $display("tb_fdd_dlwin: FAIL the run watched its watchdog (%0d pushes, cfg=%0d rdy=%0d)",
                 n_push, n_cfg, n_rdy);
        $finish;
    end

endmodule
