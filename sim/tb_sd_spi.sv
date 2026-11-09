// Testbench for the SD card SPI path: sys/sd_card.sv, compiled unmodified,
// with sim/models/hps_disk_model.sv as hps_io's disk byte transport and
// sim/models/altsyncram_model.sv for the card's sector buffer. Profi's SD
// pins go to the Z-Controller: SD_CS_N (select, active low), SD_CLK (idles
// high) and SD_DI/SD_DO. The card here has clk_spi = clk_sys, as the top
// wires it, and the bench bit-bangs the SPI bus at clk_sys edges (sck edges
// 3 ns after an edge, so the card samples them on the next one; sck idles
// high; mode-0 sampling: the host changes MOSI while sck is low and samples
// MISO while it is high).
//
// The case `polarity` pins the chip select: the card treats ss = 1 as
// deselected (sys/sd_card.sv clears bit_cnt and drives miso = 1 then; the
// reference cores drive .ss(selected ? 0 : 1)), and Profi's SD_CS_N is that
// same active-low select, so the top connects .ss(sd_ss_n) directly, not
// inverted. A frame sent while ss = 1 gets no R1; the same frame with ss = 0
// does.
//
// Cases (each prints `PASS <case>` or `FAIL <case> <reason>`):
//   polarity         ss = 1: no R1; ss = 0: CMD0 answers 0x01;
//   init_and_read    CMD0 0x01; CMD8 0x01 + 0x1AA; CMD55 0x01, ACMD41 0x00;
//                    CMD58 0x00 + OCR bit 30 (SDHC); CMD17 lba 1 0x00,
//                    token 0xFE, 512 bytes of the model's sector 1;
//   write_block      CMD24 lba 2 0x00, token, 512x 0xA5, response 0xE5,
//                    busy ends, the model's sector 2 is 0xA5 and sd_wr was
//                    seen before sd_ack;
//   eject_mid_command a mount with img_size = 0 in CMD17's wait for the
//                    sector: the host's bounded read gives 0xFF only, then
//                    (with the HPS not answering, as with no file) CMD12
//                    aborts and CMD0 answers again.
//
// The last line printed is `tb_sd_spi: PASS` or `tb_sd_spi: FAIL <reason>`;
// run via sim/run_tb_sd_spi.sh (iverilog -g2012).
`timescale 1ns / 1ps
`default_nettype none

module tb_sd_spi;

    // ---------------- clocks ----------------
    reg clk_sys = 1'b0;                     // 50 MHz, the card's clk_sys and clk_spi
    always #10 clk_sys = ~clk_sys;

    localparam integer SECTORS = 64;
    localparam [63:0] FULL = 64'd32768;     // SECTORS * 512
    localparam integer BIT_CLKS = 6;        // clk_sys clocks per sck phase

    // ---------------- the card and its buffer ----------------
    reg         reset = 1'b1;
    reg         sdhc = 1'b1;
    reg         img_mounted = 1'b0;
    reg  [63:0] img_size = 64'd0;
    wire [31:0] sd_lba;
    wire        sd_rd, sd_wr;
    wire        hps_ack_bit;
    reg         hps_hold = 1'b0;            // the bench's "the HPS stops answering"
    wire        sd_ack = hps_hold ? 1'b0 : hps_ack_bit;
    wire  [8:0] sd_buff_addr;
    wire  [7:0] sd_buff_dout, sd_buff_din;
    wire        sd_buff_wr;

    reg         ss = 1'b1;                  // deselect (active low)
    reg         sck = 1'b1;                 // idles high
    reg         mosi = 1'b1;
    wire        miso;

    sd_card u_sd (
        .clk_sys(clk_sys),
        .reset(reset),
        .sdhc(sdhc),
        .img_mounted(img_mounted),
        .img_size(img_size),
        .sd_lba(sd_lba),
        .sd_rd(sd_rd),
        .sd_wr(sd_wr),
        .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr),
        .sd_buff_dout(sd_buff_dout),
        .sd_buff_din(sd_buff_din),
        .sd_buff_wr(sd_buff_wr),
        .clk_spi(clk_sys),
        .ss(ss),
        .sck(sck),
        .mosi(mosi),
        .miso(miso)
    );

    wire [1:0] hps_ack;
    hps_disk_model hps (
        .clk(clk_sys),
        .img_size(img_size),
        .rd({1'b0, sd_rd}),
        .wr({1'b0, sd_wr}),
        .lba_a(sd_lba),
        .lba_b(32'd0),
        .ack(hps_ack),
        .buff_addr(sd_buff_addr),
        .buff_dout(sd_buff_dout),
        .buff_wr(sd_buff_wr),
        .buff_din(sd_buff_din),
        .past_end()
    );

    assign hps_ack_bit = hps_ack[0];

    // ---------------- checks ----------------
    integer errors = 0, case_errors = 0, shown = 0;
    integer n, i, sec, off, ok;
    reg  [7:0] tmp, r1, d;
    reg  [7:0] cap [0:511];

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

    // ---------------- the image ----------------
    function [7:0] img_byte;
        input integer s;
        input integer o;
        begin
            img_byte = (s * 13 + o * 5 + 1) & 8'hFF;
        end
    endfunction

    task build_image;
        begin
            for (sec = 0; sec < SECTORS; sec = sec + 1)
                for (off = 0; off < 512; off = off + 1)
                    hps.mem[0][sec * 512 + off] = img_byte(sec, off);
        end
    endtask

    // ---------------- the SPI host ----------------
    task card_select(input sel);
        begin
            ss = sel ? 1'b0 : 1'b1;         // ss is active low
        end
    endtask

    task spi_bit(input m, output r);
        begin
            @(posedge clk_sys); #3; sck = 1'b0; mosi = m;    // the card shifts out
            repeat (BIT_CLKS - 1) @(posedge clk_sys); #3;
            sck = 1'b1;                                      // the card samples MOSI
            repeat (BIT_CLKS - 1) @(posedge clk_sys); #3;
            r = miso;
        end
    endtask

    task spi_byte(input [7:0] m, output [7:0] r);
        integer k;
        reg b;
        begin
            r = 8'h00;
            for (k = 7; k >= 0; k = k - 1) begin
                spi_bit(m[k], b);
                r = {r[6:0], b};
            end
        end
    endtask

    task read_r1(output [7:0] r, output integer got);
        begin
            got = 0; r = 8'hFF;
            for (n = 0; n < 32 && !got; n = n + 1) begin
                spi_byte(8'hFF, r);
                if (r != 8'hFF) got = 1;
            end
        end
    endtask

    // a command frame with the chip select as given; read_r1 follows
    task sd_frame(input sel, input [5:0] idx, input [31:0] arg,
                  input [7:0] crc, output [7:0] r, output integer got);
        begin
            card_select(sel);
            spi_byte(8'hFF, tmp);
            spi_byte({2'b01, idx}, tmp);
            spi_byte(arg[31:24], tmp);
            spi_byte(arg[23:16], tmp);
            spi_byte(arg[15:8], tmp);
            spi_byte(arg[7:0], tmp);
            spi_byte(crc, tmp);
            read_r1(r, got);
        end
    endtask

    task read_token(output integer got);
        begin
            got = 0;
            for (n = 0; n < 64 && !got; n = n + 1) begin
                spi_byte(8'hFF, tmp);
                if (tmp == 8'hFE) got = 1;
            end
        end
    endtask

    task read_data(output integer got);
        begin
            got = 1;
            for (i = 0; i < 512; i = i + 1) begin
                spi_byte(8'hFF, d);
                cap[i] = d;
            end
            spi_byte(8'hFF, d);             // CRC, ignored
            spi_byte(8'hFF, d);
        end
    endtask

    // ---------------- monitors ----------------
    reg wr_seen = 1'b0, wr_then_ack = 1'b0;
    always @(posedge clk_sys) begin
        if (sd_wr) wr_seen <= 1'b1;
        if (sd_ack && wr_seen) wr_then_ack <= 1'b1;
    end

    task mount(input [63:0] size);
        begin
            img_size = size;
            @(posedge clk_sys); #1;
            img_mounted = 1'b1;
            repeat (4) @(posedge clk_sys); #1;
            img_mounted = 1'b0;
            @(posedge clk_sys); #1;
        end
    endtask

    // ---------------- the run ----------------
    initial begin
        $display("tb_sd_spi: start");

        build_image;
        mount(FULL);
        repeat (10) @(posedge clk_sys);
        reset = 1'b0;
        repeat (10) @(posedge clk_sys);
        card_select(1'b0);

        // ---- polarity ----
        case_begin;
        sd_frame(1'b0, 6'd0, 32'd0, 8'h95, r1, ok);
        fail_int("polarity", "deselected answers", ok, 0);
        fail_int("polarity", "deselected r1", r1, 8'hFF);
        sd_frame(1'b1, 6'd0, 32'd0, 8'h95, r1, ok);
        fail_int("polarity", "selected answers", ok, 1);
        fail_int("polarity", "CMD0 r1", r1, 8'h01);
        case_end("polarity");

        // ---- init_and_read ----
        case_begin;
        sd_frame(1'b1, 6'd8, 32'h1AA, 8'h87, r1, ok);
        fail_int("init_and_read", "CMD8 r1", r1, 8'h01);
        spi_byte(8'hFF, d); fail_int("init_and_read", "CMD8 v0", d, 8'h00);
        spi_byte(8'hFF, d); fail_int("init_and_read", "CMD8 v1", d, 8'h00);
        spi_byte(8'hFF, d); fail_int("init_and_read", "CMD8 v2", d, 8'h01);
        spi_byte(8'hFF, d); fail_int("init_and_read", "CMD8 v3", d, 8'hAA);

        sd_frame(1'b1, 6'd55, 32'd0, 8'h65, r1, ok);
        fail_int("init_and_read", "CMD55 r1", r1, 8'h01);
        sd_frame(1'b1, 6'd41, 32'h40000000, 8'h77, r1, ok);
        fail_int("init_and_read", "ACMD41 r1", r1, 8'h00);

        sd_frame(1'b1, 6'd58, 32'd0, 8'hFD, r1, ok);
        fail_int("init_and_read", "CMD58 r1", r1, 8'h00);
        spi_byte(8'hFF, d);
        fail_int("init_and_read", "OCR sdhc", d & 8'h40, 8'h40);
        spi_byte(8'hFF, d); fail_int("init_and_read", "OCR byte2", d, 8'h00);
        spi_byte(8'hFF, d); fail_int("init_and_read", "OCR byte3", d, 8'h00);
        spi_byte(8'hFF, d); fail_int("init_and_read", "OCR byte4", d, 8'h00);

        sd_frame(1'b1, 6'd17, 32'd1, 8'h55, r1, ok);
        fail_int("init_and_read", "CMD17 r1", r1, 8'h00);
        read_token(ok);
        fail_int("init_and_read", "token", ok, 1);
        read_data(ok);
        for (i = 0; i < 512; i = i + 1)
            fail_int("init_and_read", "data", cap[i], img_byte(1, i));
        card_select(1'b0);
        case_end("init_and_read");

        // ---- write_block ----
        case_begin;
        wr_seen = 1'b0; wr_then_ack = 1'b0;
        sd_frame(1'b1, 6'd24, 32'd2, 8'h55, r1, ok);
        fail_int("write_block", "CMD24 r1", r1, 8'h00);
        spi_byte(8'hFF, tmp);                   // one pad byte
        spi_byte(8'hFE, tmp);                   // the data token
        for (i = 0; i < 512; i = i + 1) spi_byte(8'hA5, tmp);
        spi_byte(8'hFF, tmp);                   // CRC
        spi_byte(8'hFF, tmp);
        spi_byte(8'hFF, d);
        fail_int("write_block", "data response", d, 8'hE5);
        // miso is 0 while the card waits for the HPS to take the sector
        spi_byte(8'hFF, d);
        fail_int("write_block", "busy", d, 8'h00);
        tmp = 8'h00;
        for (n = 0; n < 256 && tmp != 8'hFF; n = n + 1) spi_byte(8'hFF, tmp);
        fail_int("write_block", "busy ends", tmp, 8'hFF);
        fail_int("write_block", "sd_wr before ack", wr_then_ack, 1);
        // the card's busy covers its own side; the HPS burst ends a little
        // later, so wait for the model to be idle before reading its memory
        for (n = 0; n < 4000 && hps.state != 3'd0; n = n + 1)
            @(posedge clk_sys);
        for (i = 0; i < 512; i = i + 1)
            fail_int("write_block", "hps memory", hps.mem[0][2 * 512 + i], 8'hA5);
        shown = 0;
        card_select(1'b0);
        case_end("write_block");

        // ---- read_multiple ----
        // CMD18 streams: the card takes sd_rd per sector, sends the 512 bytes,
        // then the wait_m gap (all 1s) before the next sector's token. The
        // sectors are 4 and 5: 2 holds the write_block data by now.
        case_begin;
        sd_frame(1'b1, 6'd18, 32'd4, 8'h55, r1, ok);
        fail_int("read_multiple", "CMD18 r1", r1, 8'h00);
        read_token(ok);
        fail_int("read_multiple", "token 0", ok, 1);
        read_data(ok);
        for (i = 0; i < 512; i = i + 1)
            fail_int("read_multiple", "sector 4", cap[i], img_byte(4, i));
        ok = 0; tmp = 8'hFF;
        for (n = 0; n < 300 && ok != 1; n = n + 1) begin
            spi_byte(8'hFF, tmp);
            if (tmp == 8'hFE) ok = 1;
        end
        fail_int("read_multiple", "token 1", ok, 1);
        read_data(ok);
        for (i = 0; i < 512; i = i + 1)
            fail_int("read_multiple", "sector 5", cap[i], img_byte(5, i));
        sd_frame(1'b1, 6'd12, 32'd0, 8'h61, r1, ok);
        fail_int("read_multiple", "CMD12 r1", r1, 8'h00);
        card_select(1'b0);
        repeat (50) @(posedge clk_sys);
        sd_frame(1'b1, 6'd17, 32'd6, 8'h55, r1, ok);
        fail_int("read_multiple", "CMD17 after stop", r1, 8'h00);
        read_token(ok);
        fail_int("read_multiple", "token after stop", ok, 1);
        read_data(ok);
        for (i = 0; i < 512; i = i + 1)
            fail_int("read_multiple", "sector 6", cap[i], img_byte(6, i));
        card_select(1'b0);
        case_end("read_multiple");

        // ---- eject_mid_command ----
        case_begin;
        hps_hold = 1'b1;                    // the HPS has gone quiet
        sd_frame(1'b1, 6'd17, 32'd1, 8'h55, r1, ok);
        fail_int("eject", "CMD17 r1", r1, 8'h00);
        // the file goes away while the card waits for its sector
        mount(64'd0);
        n = 0; tmp = 8'hFF;
        for (i = 0; i < 64; i = i + 1) begin
            spi_byte(8'hFF, d);
            if (d != 8'hFF) n = n + 1;
        end
        fail_int("eject", "no data after the eject", n, 0);
        // the card has no timeout: the host aborts with CMD12
        sd_frame(1'b1, 6'd12, 32'd0, 8'h61, r1, ok);
        fail_int("eject", "CMD12 r1", r1, 8'h00);
        card_select(1'b0);
        hps_hold = 1'b0;
        repeat (100) @(posedge clk_sys);
        sd_frame(1'b1, 6'd0, 32'd0, 8'h95, r1, ok);
        fail_int("eject", "CMD0 after", ok, 1);
        fail_int("eject", "CMD0 r1", r1, 8'h01);
        card_select(1'b0);
        case_end("eject_mid_command");

        if (errors == 0) $display("tb_sd_spi: PASS");
        else $display("tb_sd_spi: FAIL %0d checks failed", errors);
        $finish;
    end

endmodule

`default_nettype wire