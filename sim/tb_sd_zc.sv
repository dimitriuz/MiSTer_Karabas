// The Z-Controller's SPI host against the SD card model, the way the top wires
// them (board, 2026-11-18). The host is the upstream zc_spi, unmodified, on
// clk_bus (28.125 MHz); the card's SPI side (clk_spi) is on that same
// clk_bus, as Karabas_Profi.sv wires it. The card used to sit on clk_sys
// (50 MHz) and sampled the machine's 14 MHz sck asynchronously: on the board
// CMD8's R7 came back as 1 0 0 0 58 175 instead of 1 0 0 1 170 255 and the
// ROM's SD probe never finished. This bench cannot show that fault (with
// ideal clocks and any wire delay both clockings read intact; the board's
// sampling of an unsynchronised sck is not in a simulator), so it pins what
// the fix has to keep working: the byte stream of an init, the R7 and OCR
// tails, and a CMD17 sector with its token, read byte by byte through zc_spi.
//
// zc_spi reads return the byte received during the previous transfer, so each
// frame's replies are read with rx pulses after the CRC, as the ROM does.
// Cases: init (CMD0 1, CMD8 1+00 00 01 AA, CMD55 1, ACMD41 0, CMD58 0+C0 00 00
// 00), cs_toggle (the same CMD8 after a deselect and select, sck idling high
// while deselected as profi.vhd drives it), read_sector (CMD17 lba 1: R1 0,
// token FE, 512 bytes).
// The last line printed is `tb_sd_zc: PASS` or `tb_sd_zc: FAIL <reason>`.
`timescale 1ns / 1ps
`default_nettype none

module tb_sd_zc;
    reg clk_sys = 1'b0; always #10 clk_sys = ~clk_sys;          // 50 MHz
    reg clk_bus = 1'b0; always #17.7778 clk_bus = ~clk_bus;     // 28.125 MHz

    reg reset = 1'b1;
    reg [63:0] img_size = 64'd0; reg img_mounted = 1'b0;
    wire [31:0] sd_lba; wire sd_rd, sd_wr; wire [1:0] hps_ack;
    wire [8:0] sd_buff_addr; wire [7:0] sd_buff_dout, sd_buff_din; wire sd_buff_wr;

    // profi.vhd: sck and mosi are forced high while the card is deselected
    reg  cs_n = 1'b1;
    wire sclk, mosi_h, miso;
    wire sck_c  = cs_n ? 1'b1 : sclk;
    wire mosi_c = cs_n ? 1'b1 : mosi_h;

    // sd_rd/sd_wr cross to clk_sys through two flops, as in the top
    reg [1:0] rd_s = 2'b00, wr_s = 2'b00;
    always @(posedge clk_sys) begin rd_s <= {rd_s[0], sd_rd}; wr_s <= {wr_s[0], sd_wr}; end

    sd_card u_sd (.clk_sys(clk_sys), .reset(reset), .sdhc(1'b1),
        .img_mounted(img_mounted), .img_size(img_size), .sd_lba(sd_lba),
        .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(hps_ack[0]),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
        .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
        .clk_spi(clk_bus), .ss(cs_n), .sck(sck_c), .mosi(mosi_c), .miso(miso));
    hps_disk_model hps (.clk(clk_sys), .img_size(img_size), .rd({1'b0, rd_s[1]}),
        .wr({1'b0, wr_s[1]}), .lba_a(sd_lba), .lba_b(32'd0), .ack(hps_ack),
        .buff_addr(sd_buff_addr), .buff_dout(sd_buff_dout), .buff_wr(sd_buff_wr),
        .buff_din(sd_buff_din), .past_end());

    reg tx = 0, rx = 0; reg [7:0] din = 8'hFF; wire [7:0] dout; wire spi_wait;
    zc_spi zc (.clk_sys(clk_bus), .ena(1'b1), .tx(tx), .rx(rx), .din(din),
               .dout(dout), .spi_clk(sclk), .spi_di(miso), .spi_do(mosi_h),
               .spi_wait(spi_wait));

    integer errors = 0, shown = 0;
    task check(input [8*24-1:0] what, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                if (shown < 12) $display("FAIL %0s got %0d want %0d", what, got, want);
                shown = shown + 1; errors = errors + 1;
            end
        end
    endtask

    task zc_out(input [7:0] b);
        begin
            @(posedge clk_bus); din = b; tx = 1; @(posedge clk_bus); tx = 0;
            repeat (40) @(posedge clk_bus);
        end
    endtask
    reg [7:0] rd;
    task zc_in;
        begin
            @(posedge clk_bus); rx = 1; @(posedge clk_bus); rx = 0;
            repeat (3) @(posedge clk_bus);
            rd = dout;
            repeat (40) @(posedge clk_bus);
        end
    endtask

    task frame(input [5:0] c, input [31:0] a, input [7:0] k);
        begin
            zc_out(8'h40 | c); zc_out(a[31:24]); zc_out(a[23:16]);
            zc_out(a[15:8]); zc_out(a[7:0]); zc_out(k);
        end
    endtask

    reg [7:0] r [0:11];
    task cmd(input [5:0] c, input [31:0] a, input [7:0] k);
        integer j;
        begin
            zc_out(8'h40 | c); zc_out(a[31:24]); zc_out(a[23:16]);
            zc_out(a[15:8]); zc_out(a[7:0]); zc_out(k);
            for (j = 0; j < 12; j = j + 1) begin zc_in; r[j] = rd; end
        end
    endtask

    // r[0] is the byte of the CRC's own transfer; R1 follows three idle bytes
    task expect_r(input [8*24-1:0] what, input [7:0] r1);
        begin
            check(what, r[0], 8'hFF); check(what, r[1], 8'hFF); check(what, r[2], 8'hFF);
            check(what, r[3], 8'hFF);
            check(what, r[4], r1);
        end
    endtask

    integer q, g, bad;
    initial begin
        $display("tb_sd_zc: start");
        for (q = 0; q < 64 * 512; q = q + 1) hps.mem[0][q] = (q * 7 + (q >> 9)) & 8'hFF;
        img_size = 64'd32768; #100; @(posedge clk_sys); img_mounted = 1;
        repeat (4) @(posedge clk_sys); img_mounted = 0;
        repeat (10) @(posedge clk_sys); reset = 0; repeat (10) @(posedge clk_sys);

        // ---- init ----
        cs_n = 0; repeat (5) @(posedge clk_bus);
        for (q = 0; q < 12; q = q + 1) zc_out(8'hFF);
        cmd(0, 0, 8'h95);                 expect_r("CMD0 R1", 8'h01);
        cmd(8, 32'h1AA, 8'h87);           expect_r("CMD8 R1", 8'h01);
        check("CMD8 R7 0", r[5], 8'h00); check("CMD8 R7 1", r[6], 8'h00);
        check("CMD8 R7 2", r[7], 8'h01); check("CMD8 R7 3", r[8], 8'hAA);
        check("CMD8 tail", r[9], 8'hFF);
        cmd(55, 0, 8'h65);                expect_r("CMD55 R1", 8'h01);
        cmd(41, 32'h40000000, 8'h77);     expect_r("ACMD41 R1", 8'h00);
        cmd(55, 0, 8'h65);                expect_r("CMD55 again R1", 8'h01);
        cmd(41, 32'h40000000, 8'h77);     expect_r("ACMD41 again R1", 8'h00);
        cmd(58, 0, 8'hFD);                expect_r("CMD58 R1", 8'h00);
        check("OCR 0", r[5], 8'hC0); check("OCR 1", r[6], 8'h00);
        check("OCR 2", r[7], 8'h00); check("OCR 3", r[8], 8'h00);
        check("OCR tail", r[9], 8'hFF);
        $display("%s init", errors == 0 ? "PASS" : "FAIL");

        // ---- cs_toggle ----
        g = errors;
        cs_n = 1; repeat (20) @(posedge clk_bus);
        cs_n = 0; repeat (5) @(posedge clk_bus);
        zc_out(8'hFF);
        cmd(8, 32'h1AA, 8'h87);           expect_r("toggle CMD8 R1", 8'h01);
        check("toggle R7 0", r[5], 8'h00); check("toggle R7 1", r[6], 8'h00);
        check("toggle R7 2", r[7], 8'h01); check("toggle R7 3", r[8], 8'hAA);
        $display("%s cs_toggle", errors == g ? "PASS" : "FAIL");

        // ---- read_sector ----
        g = errors;
        frame(17, 32'd1, 8'h55);
        q = 0; zc_in; while (rd === 8'hFF && q < 40) begin zc_in; q = q + 1; end
        check("CMD17 R1", rd, 8'h00);
        q = 0; zc_in; while (rd !== 8'hFE && q < 600) begin zc_in; q = q + 1; end
        check("CMD17 token", rd, 8'hFE);
        bad = 0;
        for (q = 0; q < 512; q = q + 1) begin
            zc_in;
            if (rd !== (((512 + q) * 7 + 1) & 8'hFF)) bad = bad + 1;
        end
        check("CMD17 sector bad bytes", bad, 0);
        $display("%s read_sector", errors == g ? "PASS" : "FAIL");

        if (errors == 0) $display("tb_sd_zc: PASS");
        else $display("tb_sd_zc: FAIL %0d checks failed", errors);
        $finish;
    end

    // a stuck bench must still end with a verdict
    initial begin #400_000_000; $display("tb_sd_zc: FAIL timeout"); $finish; end
endmodule
