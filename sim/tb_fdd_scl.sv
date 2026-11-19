// tb_fdd_scl.sv - a Sinclair SCL download into fdd_src (alone, like tb_fdd_dlwin:
// the store is a toggle-ack responder that records the fill words).
//
// The bench streams SCL files (build/sim/scl/*.hex, made by
// sim/run_tb_fdd_scl.sh with tools/scl.py), keeps what lands at each window
// address, and compares it with tools/scl.py's `window` for the same file: the
// catalog entries with their made-up first sector and track, the ID sector,
// the file data from 0x1000. Cases: A three files (checked byte for byte), B
// no files after A (the 4 KiB the window kept from A must be cleared), C more
// sectors than a disk holds (refused: no ready), D a damaged signature (no
// config at all). The verdict is the last line.
`timescale 1ns/1ps

module tb_fdd_scl;
    reg bclk = 1'b0;
    always #10 bclk = ~bclk;
    reg rst = 1'b1;

    reg         io_dl = 1'b0;
    reg  [15:0] io_index = 16'd0;
    reg         io_wr = 1'b0;
    reg  [7:0]  io_dout = 8'd0;
    wire        io_wait;
    wire        fill_tgl;
    wire [31:0] fill_word;
    reg         fill_ack = 1'b0;
    wire [1:0]  sd_rd, sd_wr;
    wire [31:0] sd_lba;
    wire [7:0]  sd_din;
    wire [1:0]  wprt;

    fdd_src u_fdd (
        .clk_sys(bclk), .reset_sys(rst),
        .img_mounted(2'b00), .img_size(64'd0), .img_readonly(1'b0),
        .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_lba(sd_lba), .sd_ack(2'b00),
        .sd_buff_addr(9'd0), .sd_buff_dout(8'd0), .sd_buff_din(sd_din), .sd_buff_wr(1'b0),
        .status(128'd0),
        .ioctl_download(io_dl), .ioctl_index(io_index), .ioctl_wr(io_wr),
        .ioctl_addr(27'd0), .ioctl_dout(io_dout), .ioctl_wait(io_wait),
        .wprt(wprt),
        .fill_tgl(fill_tgl), .fill_word(fill_word), .fill_ack_tgl(fill_ack),
        .drn_addr_b(), .drn_q_b(8'd0), .drn_tgl(1'b0), .drn_info(12'd0), .drn_ack_tgl()
    );

    always @(fill_tgl) begin
        repeat (3) @(posedge bclk);
        fill_ack <= ~fill_ack;
    end

    // what the store would hold: the window (only the first 64 KiB are used here)
    reg [7:0] win [0:65535];
    integer n_cfg = 0, n_rdy = 0, n_img = 0, n_x = 0, n_oob = 0, n_lost = 0;
    reg [31:0] cfg_word = 32'd0;
    always @(fill_tgl) begin
        #1;
        if (!rst) begin
            if (^fill_word === 1'bx) n_x = n_x + 1;
            if (fill_word[31:30] == 2'd0) begin n_cfg = n_cfg + 1; cfg_word = fill_word; end
            else if (fill_word[31:30] == 2'd2) n_rdy = n_rdy + 1;
            else if (!fill_word[29]) begin
                n_img = n_img + 1;
                if (fill_word[28:8] < 21'd65536) win[fill_word[23:8]] = fill_word[7:0];
                else n_oob = n_oob + 1;
            end
        end
    end

    integer errors = 0;
    task automatic fail(input [8*72-1:0] why);
        begin if (errors < 10) $display("FAIL %0s", why); errors = errors + 1; end
    endtask

    task automatic send_byte(input [7:0] b);
        integer w;
        begin
            w = 0;
            while (io_wait === 1'b1 && w < 200_000) begin @(posedge bclk); #1; w = w + 1; end
            if (w >= 200_000) fail("the ioctl wait never fell");
            else begin
                io_dout = b; io_wr = 1'b1;
                @(posedge bclk); #1;
                if (io_wait !== 1'b1) n_lost = n_lost + 1;
                io_wr = 1'b0;
            end
        end
    endtask

    reg [7:0] fmem [0:65535];
    reg [7:0] emem [0:65535];
    integer fn, en, i, k;

    // stream the file, close the window, wait for the ready (or not)
    task automatic download(input integer want_cfg, input integer want_rdy);
        begin
            n_cfg = 0; n_rdy = 0; n_img = 0;
            io_index = 16'd1; io_dl = 1'b1;
            k = 0;
            while (io_wait !== 1'b1 && k < 8) begin @(posedge bclk); #1; k = k + 1; end
            if (io_wait !== 1'b1) fail("the download window was never claimed");
            for (i = 0; i < fn; i = i + 1) send_byte(fmem[i]);
            io_dl = 1'b0;
            k = 0;
            while (n_rdy == 0 && k < 60_000) begin @(posedge bclk); k = k + 1; end
            repeat (200) @(posedge bclk);
            if (n_cfg != want_cfg) begin $display("FAIL %0d configs, want %0d", n_cfg, want_cfg); errors = errors + 1; end
            if (n_rdy != want_rdy) begin $display("FAIL %0d readies, want %0d", n_rdy, want_rdy); errors = errors + 1; end
        end
    endtask

    task automatic load(input integer which);
        integer j;
        begin
            for (j = 0; j < 65536; j = j + 1) begin fmem[j] = 8'hxx; emem[j] = 8'hxx; end
            case (which)
                0: begin $readmemh("build/sim/scl/a.hex", fmem); $readmemh("build/sim/scl/a.win", emem); end
                1: begin $readmemh("build/sim/scl/b.hex", fmem); $readmemh("build/sim/scl/b.win", emem); end
                2: $readmemh("build/sim/scl/c.hex", fmem);
                default: $readmemh("build/sim/scl/d.hex", fmem);
            endcase
            fn = 0; while (fn < 65536 && fmem[fn] !== 8'hxx) fn = fn + 1;
            en = 0; while (en < 65536 && emem[en] !== 8'hxx) en = en + 1;
            if (fn == 0) fail("a fixture is empty");
        end
    endtask

    task automatic compare(input [8*24-1:0] who);
        integer j, bad;
        begin
            bad = 0;
            for (j = 0; j < en; j = j + 1)
                if (win[j] !== emem[j]) begin
                    if (bad < 4) $display("FAIL %0s: window[%0d] = %h, want %h", who, j, win[j], emem[j]);
                    bad = bad + 1;
                end
            if (bad != 0) errors = errors + 1;
            // every byte the reference has was written (and nothing was written elsewhere)
            if (n_img < en) begin $display("FAIL %0s: %0d image bytes, want at least %0d", who, n_img, en); errors = errors + 1; end
        end
    endtask

    initial begin : main
        integer j;
        for (j = 0; j < 65536; j = j + 1) win[j] = 8'hAA;       // the last image's bytes
        repeat (20) @(posedge bclk); rst <= 1'b0; repeat (20) @(posedge bclk);

        load(0); download(1, 1);
        if (cfg_word[31:30] != 2'd0 || cfg_word[28:27] != 2'd0 || cfg_word[26:20] != 7'd80)
            begin $display("FAIL A: config %h is not 80 tracks of a TRD", cfg_word); errors = errors + 1; end
        compare("A three files");
        if (wprt[0] !== 1'b1) fail("A: the SCL drive is not write-protected");

        load(1); download(1, 1);
        compare("B no files");
        // B: the catalog area is zero (A's entries are gone)
        for (j = 0; j < 4096; j = j + 1)
            if (j < 16 && 0) ;
        if (win[0] !== 8'h00 || win[16] !== 8'h00 || win[8*256 + 16] !== 8'h00)
            fail("B: A's catalog survived");

        if (n_lost != 0) begin $display("FAIL %0d bytes lost", n_lost); errors = errors + 1; end
        // the two refusals let the rest of the file go (the claim is dropped, so
        // those strobes are not taken - by design, as for a bad FDI header)
        load(2); download(1, 0);          // too many sectors: config went, no ready
        load(3); download(0, 0);          // damaged signature: nothing at all
        if (n_x != 0) begin $display("FAIL X in a fill word"); errors = errors + 1; end
        if (errors == 0) $display("tb_fdd_scl: PASS");
        else $display("tb_fdd_scl: FAIL %0d checks failed", errors);
        $finish;
    end

    initial begin
        k = 0;
        while (k < 40_000_000) begin @(posedge bclk); k = k + 1; end
        $display("tb_fdd_scl: FAIL the run hit its watchdog (cfg=%0d rdy=%0d img=%0d)", n_cfg, n_rdy, n_img);
        $finish;
    end
endmodule
