// Testbench for rtl/host/mcu_emu.sv: the emulated MCU behind upstream's
// unmodified kg_mcu (generics and the tied inputs as in profi.vhd U7) on a
// 28.125 MHz clk_bus of unrelated phase, plus kg_soft_switches #(.N(15))
// fed by SOFTSW_COMMAND as in profi.vhd U9.
//
// A behavioural ioctl source streams a 0x58000-byte pseudo-random boot.rom
// (fixed LFSR; one byte at a time, the next byte only after ioctl_wait
// falls). The bench decodes every SPI frame from the link wires and checks:
//   no_boot_rom_stays_busy  no download -> no frame at all, BUSY stays 1;
//   rom_load                every ROMLOAD_WR equals the mapped source byte,
//                           in order, no duplicates, ROMLOADER_ACTIVE from
//                           before the first write to after the last, and
//                           the whole frame stream (bank frames only when
//                           the address bytes change) is exactly the
//                           protocol's;
//   init_and_busy           BUSY 1 until after INIT_DONE, then 0;
//   switch_during_load      status changes while streaming: no 05 frame
//                           before the ROMLOADER-off frame (the stream
//                           walk proves it), and the registers hold the
//                           last value after INIT_DONE;
//   switches                every soft-switch register 0..14 holds the
//                           osd_items table's value after INIT_DONE; a
//                           status change reaches register 0 in 50 us;
//   keyboard                a kb_changed report reaches KB_STATUS/KB_DAT0;
//   reset_trigger           osd_reset pulses register 14, and the pulse
//                           ends after TRIGGER_CLKS;
//   and a second download repeating the whole start sequence.
// The last line printed is `tb_mcu_emu: PASS` or `tb_mcu_emu: FAIL <reason>`;
// run via sim/run_tb_mcu_emu.sh (iverilog -g2012).
`timescale 1ns / 1ps

module tb_mcu_emu;

   localparam integer ROMSIZE = 360448;      // 0x58000
   localparam integer ROMMAX  = 360704;      // + the second 256-byte run
   localparam integer FMAX    = 370000;

   reg clk = 1'b0;
   always #10 clk = ~clk;                    // clk_sys 50 MHz
   reg clk_bus = 1'b0;
   always #17.7778 clk_bus = ~clk_bus;       // 28.125 MHz, unrelated phase

   reg reset = 1'b1;

   `define FAIL(MSG) begin \
      $display("tb_mcu_emu: FAIL %s at %0t", (MSG), $time); \
      $finish; \
   end

   // ---------------- mcu_emu ----------------

   reg          ioctl_download = 1'b0;
   reg  [15:0]  ioctl_index    = 16'd0;
   reg          ioctl_wr       = 1'b0;
   reg  [26:0]  ioctl_addr     = 27'd0;
   reg  [7:0]   ioctl_dout     = 8'd0;
   wire         ioctl_wait;
   reg  [127:0] status         = 128'd0;
   reg          osd_reset      = 1'b0;
   reg  [55:0]  kb_report      = 56'd0;
   reg          kb_changed     = 1'b0;
   wire         spi_cs_n, spi_sck, spi_mosi;
   wire         spi_miso;
   wire [23:0]  last_reply;
   wire         reply_valid;

   mcu_emu #(
      .TRIGGER_CLKS (2000),   // 40 us at 50 MHz
      .NOP_CLKS     (200)     // 4 us
   ) dut (
      .clk (clk), .reset (reset),
      .ioctl_download (ioctl_download), .ioctl_index (ioctl_index),
      .ioctl_wr (ioctl_wr), .ioctl_addr (ioctl_addr),
      .ioctl_dout (ioctl_dout), .ioctl_wait (ioctl_wait),
      .status (status), .osd_reset (osd_reset),
      .kb_report (kb_report), .kb_changed (kb_changed),
      .spi_cs_n (spi_cs_n), .spi_sck (spi_sck), .spi_mosi (spi_mosi),
      .spi_miso (spi_miso),
      .last_reply (last_reply), .reply_valid (reply_valid)
   );

   // ---------------- kg_mcu, profi.vhd U7 ----------------

   wire mcu_miso;
   assign spi_miso = mcu_miso;

   wire [7:0]  KB_STATUS, KB_DAT0, KB_DAT1, KB_DAT2;
   wire [7:0]  KB_DAT3, KB_DAT4, KB_DAT5;
   wire        ROMLOADER_ACTIVE, ROMLOAD_WR;
   wire [31:0] ROMLOAD_ADDR;
   wire [7:0]  ROMLOAD_DATA;
   wire [15:0] SOFTSW_COMMAND;
   wire [7:0]  HWID;
   wire        BUSY;
   wire [15*8-1:0] softsw_regs;

   kg_mcu #(
      .BURST_MAX_MHZ (0), .CS_FILTER (3), .ENABLE_RTC (1), .ENABLE_UART (1),
      .ENABLE_MATRIX (1), .ENABLE_DEBUG (0), .ENABLE_IMG (1),
      .ENABLE_FILE (0), .ENABLE_FT (0), .ENABLE_SD2 (0)
   ) u_mcu (
      .CLK (clk_bus), .N_RESET (~reset),
      .MCU_MOSI (spi_mosi), .MCU_MISO (mcu_miso), .MCU_SCK (spi_sck),
      .MCU_SS (spi_cs_n), .MCU_SPI_FT_SS (1'b1), .MCU_SPI_SD2_SS (1'b1),
      .MCU_BURST_CS_N (1'b1), .MCU_BURST_READY (),
      .MS_X (), .MS_Y (), .MS_Z (), .MS_B (), .MS_UPD (),
      .KB_STATUS (KB_STATUS), .KB_DAT0 (KB_DAT0), .KB_DAT1 (KB_DAT1),
      .KB_DAT2 (KB_DAT2), .KB_DAT3 (KB_DAT3), .KB_DAT4 (KB_DAT4),
      .KB_DAT5 (KB_DAT5), .KB_SCANCODE (), .KB_SCANCODE_UPD (),
      .XT_SCANCODE (), .XT_SCANCODE_UPD (),
      .JOY_L (), .JOY_R (), .BTNS (),
      .RTC_A (8'h00), .RTC_DI (8'h00), .RTC_DO (), .RTC_CS (1'b1),
      .RTC_WR_N (1'b1),
      .UART_RX_DATA (), .UART_RX_IDX (), .UART_TX_DATA (8'h00),
      .UART_TX_WR (1'b0), .UART_TX_MODE (1'b0), .UART_DLM (8'h00),
      .UART_DLL (8'h00), .UART_DLM_WR (1'b0), .UART_DLL_WR (1'b0),
      .SOFTSW_COMMAND (SOFTSW_COMMAND), .OSD_COMMAND (),
      .ROMLOADER_ACTIVE (ROMLOADER_ACTIVE), .ROMLOAD_ADDR (ROMLOAD_ADDR),
      .ROMLOAD_DATA (ROMLOAD_DATA), .ROMLOAD_WR (ROMLOAD_WR),
      .IOCTL_ACTIVE (), .FILELOAD_RESET (), .FILELOAD_ACTIVE (),
      .FILELOAD_SIZE (), .FILELOAD_ADDR (), .FILELOAD_DATA (),
      .FILELOAD_WR (),
      .FT_SPI_ON (), .FT_VGA_ON (), .FT_RESET (), .FT_SCK (), .FT_MOSI (),
      .FT_MISO (1'b1), .FT_CS_N (),
      .SD2_SCK (), .SD2_MOSI (), .SD2_MISO (1'b1), .SD2_CS_N (),
      .MATRIX_CMD (24'd0), .MATRIX_CMD_WR (1'b0),
      .DEBUG_ADDR (16'd0), .DEBUG_DATA (16'd0),
      .HWID (HWID), .DVI_ONLY (),
      .IMG_MOUNTED (), .IMG_SIZE (), .IMG_DATA_WR (), .IMG_DATA_ADDR (),
      .IMG_DATA (), .IMG_RESULT_WR (), .IMG_RESULT (), .IMG_SUM (),
      .IMG_Q_WR (1'b0), .IMG_Q_DI (24'd0), .IMG_Q_ACK (), .IMG_PHYS_WR (),
      .IMG_PHYS (), .IMG_FLUSH (),
      .ESP_UART_TX_DATA (), .ESP_UART_TX_WR (), .ESP_UART_RX_DATA (8'h00),
      .ESP_UART_RX_WR (1'b0), .ESP_UART_RX_ACK (),
      .FLASHBOOT_START (1'b0), .FLASHBOOT_COREID (5'd0),
      .BUSY (BUSY)
   );

   kg_soft_switches #(.N (15)) u_sw (
      .clk (clk_bus), .command (SOFTSW_COMMAND),
      .regs (softsw_regs), .upd ()
   );

   // ---------------- expected ROM image (fixed LFSR) ----------------

   reg [31:0] lfsr;
   reg [31:0] exp_addr [0:ROMMAX-1];
   reg [7:0]  exp_data [0:ROMMAX-1];
   integer    expected_total;

   function [31:0] rom_map;    // the boot.rom map (Global Constraints)
      input [26:0] o;
      begin
         rom_map = (o < 27'h50000) ? (32'h00100000 + {5'd0, o})
                                   : (32'h80000000 + ({5'd0, o} - 32'h00050000));
      end
   endfunction

   // ---------------- frame decoder (the link wires) ----------------

   reg [23:0] flog [0:FMAX-1];
   integer    nfrm = 0;
   integer    cbits = 0;
   reg [23:0] cword = 24'd0;
   integer    cs_ever_low = 0;
   // BUSY is 1 from INIT_START to INIT_DONE; INIT_START's own frame is
   // excluded (kg_mcu sees it only after the frame).
   integer    busy_mode = 0;      // 1: busy, 2: free, 3: busy again
   integer    busy_skip = -1;     // frame index of the last INIT_START
   integer    fe_total  = 0;      // INIT_DONE frames seen

   always @(negedge spi_cs_n) cbits = 0;
   always @(posedge spi_sck)
      if (!reset && !spi_cs_n) begin
         cword = {cword[22:0], spi_mosi};
         cbits = cbits + 1;
      end
   always @(posedge spi_cs_n) begin
      if (!reset) begin
         cs_ever_low = 1;
         if (cbits == 24) begin
            if (nfrm >= FMAX) `FAIL("frame log overflow")
            flog[nfrm] = cword;
            if (cword == 24'hFD0000) begin
               busy_mode  = 1;
               busy_skip  = nfrm;
            end else if (cword == 24'hFE0000) begin
               fe_total = fe_total + 1;
               if (busy_mode == 1) busy_mode = 2;
            end
            if (busy_mode == 1 && nfrm != busy_skip && BUSY !== 1'b1)
               `FAIL("BUSY dropped before INIT_DONE")
            nfrm = nfrm + 1;
         end
      end
   end

   // ---------------- ROM write recorder ----------------

   integer rom_rec = 0;
   integer act_prev = 0, act_downs = 0;
   integer t_act_up = 0, t_first_wr = 0, t_last_wr = 0, t_act_down = 0;

   always @(posedge clk_bus) begin
      if (ROMLOADER_ACTIVE && !act_prev) begin
         act_prev = 1;
         t_act_up = $time;
      end else if (!ROMLOADER_ACTIVE && act_prev) begin
         act_prev   = 0;
         t_act_down = $time;
         act_downs  = act_downs + 1;
         if (rom_rec != expected_total)
            `FAIL("ROMLOADER off before every byte was written")
      end
      if (ROMLOAD_WR) begin
         if (rom_rec >= ROMMAX) `FAIL("more ROMLOAD_WR than source bytes")
         if (!ROMLOADER_ACTIVE) `FAIL("ROMLOAD_WR with ROMLOADER_ACTIVE 0")
         if (ROMLOAD_ADDR !== exp_addr[rom_rec] ||
             ROMLOAD_DATA !== exp_data[rom_rec]) begin
            $display("tb_mcu_emu: FAIL write %08d is %8h/%02h expected %8h/%02h at %0d",
                     rom_rec, ROMLOAD_ADDR, ROMLOAD_DATA,
                     exp_addr[rom_rec], exp_data[rom_rec], rom_rec);
            $finish;
         end
         if (rom_rec == 0) t_first_wr = $time;
         t_last_wr = $time;
         rom_rec   = rom_rec + 1;
      end
   end

   // ---------------- expected OSD values (osd_items.svh table) -------

   // the status vector exercising every row of the table, ROM Bank = bank
   function [127:0] status_full;
      input [1:0] bank;
      begin
         status_full = (128'd1 << 1) | (128'd1 << 2) |        // ROM Bank 3
                       (128'd1 << 4) | (128'd1 << 6) |        // PSG field 5
                       (128'd1 << 7) |                        // VSync 1
                       (128'd1 << 9) |                        // Turbo 2
                       (128'd1 << 12) |                     // Joy L field 4
                       (128'd1 << 13) | (128'd1 << 15) |     // Joy R field 5
                       (128'd1 << 16) | (128'd1 << 17) |      // DivMMC, Kbd
                       (128'd1 << 18);                        // Pause
         status_full[2:1] = bank;
      end
   endfunction

   integer curbank = 3;                  // status[2:1] as last sent
   function [7:0] exp_sw;
      input integer idx;
      begin
         case (idx)
            0:       exp_sw = curbank[7:0];
            1:       exp_sw = 8'd1;      // Covox: field 0, ~0
            2:       exp_sw = 8'd0;      // PSG mix: (5 + 1) % 6
            3:       exp_sw = 8'd1;
            4:       exp_sw = 8'd2;
            5:       exp_sw = 8'd4;
            6:       exp_sw = 8'd0;      // Joy R: (5 + 1) % 6
            7:       exp_sw = 8'd1;
            8:       exp_sw = 8'd1;      // HDD: constant 1
            10:      exp_sw = 8'd1;
            11:      exp_sw = 8'd1;
            default: exp_sw = 8'd0;      // 9, and the triggers 12..14
         endcase
      end
   endfunction

   // ---------------- ioctl source ----------------

   task stream_range;                     // source bytes [lo, hi)
      input integer lo;
      input integer hi;
      integer k;
      begin
         for (k = lo; k < hi; k = k + 1) begin
            @(negedge clk);
            ioctl_addr = k[26:0];
            ioctl_dout = exp_data[k];
            ioctl_wr   = 1'b1;
            while (ioctl_wait !== 1'b1) @(posedge clk);
            @(negedge clk);
            ioctl_wr = 1'b0;
            while (ioctl_wait !== 1'b0) @(posedge clk);
         end
      end
   endtask

   integer walk_n;

   // one frame against its expected word
   task chkfrm;
      input integer j;
      input [23:0] want;
      begin
         if (flog[j] !== want) begin
            $display("tb_mcu_emu: FAIL frame %0d is %6h expected %6h",
                     j, flog[j], want);
            $finish;
         end
      end
   endtask

   // compare the frames [fbase, ...) with the protocol's stream for source
   // bytes [lo, hi): start sequence, banks only when they change, data,
   // ROMLOADER off, the 14 switches, the keyboard clear, INIT_DONE.
   task walk_stream;
      input integer fbase;
      input integer lo;
      input integer hi;
      integer j, k, b;
      reg [7:0] pb0, pb1, pb2, bb;
      reg [31:0] a;
      begin
         j = fbase;
         chkfrm(j, 24'hFD0000);   j = j + 1;
         chkfrm(j, 24'hF90001);   j = j + 1;
         chkfrm(j, 24'h080001);   j = j + 1;
         pb0 = 8'hFF; pb1 = 8'hFF; pb2 = 8'hFF;
         for (k = lo; k < hi; k = k + 1) begin
            a = exp_addr[k];
            if (a[15:8] !== pb0) begin
               chkfrm(j, {8'h06, 8'h00, a[15:8]}); j = j + 1; pb0 = a[15:8];
            end
            if (a[23:16] !== pb1) begin
               chkfrm(j, {8'h06, 8'h01, a[23:16]}); j = j + 1; pb1 = a[23:16];
            end
            if (a[31:24] !== pb2) begin
               chkfrm(j, {8'h06, 8'h02, a[31:24]}); j = j + 1; pb2 = a[31:24];
            end
            chkfrm(j, {8'h07, a[7:0], exp_data[k]}); j = j + 1;
         end
         chkfrm(j, 24'h080000);   j = j + 1;
         for (b = 0; b <= 14; b = b + 1)
            if (b != 9) begin
               bb = b;
               chkfrm(j, {8'h05, bb, exp_sw(b)});   j = j + 1;
            end
         for (b = 0; b <= 6; b = b + 1) begin
            bb = b;
            chkfrm(j, {8'h01, bb, 8'h00});          j = j + 1;
         end
         chkfrm(j, 24'hFE0000);   j = j + 1;
         walk_n = j - fbase;
      end
   endtask

   // ---------------- main ----------------

   integer i, base, t0;

   initial begin
      // the image (the fixed LFSR the source plays)
      lfsr = 32'h12345678;
      for (i = 0; i < ROMSIZE; i = i + 1) begin
         lfsr = (lfsr >> 1) ^ (lfsr[0] ? 32'hEDB88320 : 32'd0);
         exp_addr[i] = rom_map(i[26:0]);
         exp_data[i] = lfsr[7:0];
      end
      for (i = 0; i < 256; i = i + 1) begin    // the second download replays
         exp_addr[ROMSIZE + i] = exp_addr[i];
         exp_data[ROMSIZE + i] = exp_data[i];
      end
      expected_total = ROMSIZE;

      status = status_full(2'b11);
      repeat (20) @(negedge clk);
      reset = 1'b0;

      // no_boot_rom_stays_busy: nothing may move for 2 ms
      #2000000;
      if (nfrm != 0 || cs_ever_low != 0)
         `FAIL("frames were sent without a boot.rom download")
      if (BUSY !== 1'b1) `FAIL("BUSY is 0 before INIT_START")

      // the full download, two status changes while streaming
      ioctl_download = 1'b1;
      stream_range(0, 65536);            // 0x10000
      status = status_full(2'b01);
      stream_range(65536, 196608);       // 0x30000
      status = status_full(2'b10);
      stream_range(196608, ROMSIZE);
      status         = status_full(2'b11);
      curbank        = 3;
      ioctl_download = 1'b0;

      // INIT_DONE closes the start sequence
      t0 = $time;
      while (fe_total < 1) begin
         if ($time - t0 > 200000 * 1000000) `FAIL("INIT_DONE was not sent")
         @(negedge clk);
      end
      walk_stream(0, 0, ROMSIZE);
      if (nfrm != walk_n) begin
         $display("tb_mcu_emu: FAIL %0d frames logged, %0d expected",
                  nfrm, walk_n);
         $finish;
      end

      // rom_load: the recorder walked the whole image; the per-write
      // checks ran live. What is left: the counts and the loader window.
      if (rom_rec != ROMSIZE) `FAIL("ROMLOAD_WR count differs from the source")
      if (act_downs != 1) `FAIL("ROMLOADER_ACTIVE did not fall exactly once")
      if (!(t_act_up < t_first_wr))
         `FAIL("ROMLOADER_ACTIVE rose after the first write")
      if (!(t_act_down > t_last_wr))
         `FAIL("ROMLOADER_ACTIVE fell before the last write")

      // init_and_busy: BUSY is 1 until after INIT_DONE, then 0 (the walk
      // checked every frame up to INIT_DONE; now the drop)
      t0 = $time;
      while (BUSY !== 1'b0) begin
         if ($time - t0 > 5000 * 1000000) `FAIL("BUSY stuck after INIT_DONE")
         @(negedge clk);
      end
      if (HWID !== 8'h01) `FAIL("HW_SETUP board is not Go")

      // switch_during_load / switches: every register holds the table's
      // value for the last status (the walk proved no 05 frame went out
      // before the ROMLOADER-off frame)
      #10000;
      for (i = 0; i <= 14; i = i + 1)
         if (softsw_regs[i*8 +: 8] !== exp_sw(i)) begin
            $display("tb_mcu_emu: FAIL reg %0d is %02h expected %02h",
                     i, softsw_regs[i*8 +: 8], exp_sw(i));
            $finish;
         end

      // a changed status reaches register 0 within 50 us
      @(negedge clk);
      status[2:1] = 2'b01;
      curbank     = 1;
      t0 = $time;
      while (softsw_regs[0*8 +: 8] !== 8'd1) begin
         if ($time - t0 > 50000 * 1000000) `FAIL("register 0 did not follow status")
         @(negedge clk);
      end

      // keyboard
      @(negedge clk);
      kb_report  = {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h04, 8'h02};
      kb_changed = 1'b1;
      @(negedge clk);
      kb_changed = 1'b0;
      t0 = $time;
      while (KB_STATUS !== 8'h02 || KB_DAT0 !== 8'h04 || KB_DAT1 !== 8'h00 ||
             KB_DAT2 !== 8'h00 || KB_DAT3 !== 8'h00 || KB_DAT4 !== 8'h00 ||
             KB_DAT5 !== 8'h00) begin
         if ($time - t0 > 50000 * 1000000) `FAIL("the keyboard report did not arrive")
         @(negedge clk);
      end
      if (BUSY !== 1'b0) `FAIL("BUSY went back to 1 in the run loop")

      // reset_trigger: one clock of osd_reset pulses register 14, and the
      // pulse ends after TRIGGER_CLKS (2000 clocks = 40 us)
      @(negedge clk);
      osd_reset = 1'b1;
      @(negedge clk);
      osd_reset = 1'b0;
      t0 = $time;
      while (softsw_regs[14*8 +: 8] !== 8'h01) begin
         if ($time - t0 > 15000 * 1000000) `FAIL("osd_reset did not pulse register 14")
         @(negedge clk);
      end
      #20000;                       // TRIGGER_CLKS has not passed yet
      if (softsw_regs[14*8 +: 8] !== 8'h01)
         `FAIL("the Reset pulse ended before TRIGGER_CLKS")
      t0 = $time;
      while (softsw_regs[14*8 +: 8] !== 8'h00) begin
         if ($time - t0 > 60000 * 1000000) `FAIL("the Reset pulse did not end")
         @(negedge clk);
      end
      // the keyboard back to idle, so the report frames between ROMLOADER
      // off and INIT_DONE carry zeros again
      @(negedge clk);
      kb_report  = 56'd0;
      kb_changed = 1'b1;
      @(negedge clk);
      kb_changed = 1'b0;
      t0 = $time;
      while (KB_STATUS !== 8'h00) begin
         if ($time - t0 > 50000 * 1000000) `FAIL("the keyboard did not reach idle")
         @(negedge clk);
      end

      // a second boot.rom download repeats the whole start sequence
      expected_total = ROMSIZE + 256;
      base           = nfrm;
      ioctl_download = 1'b1;
      stream_range(0, 256);
      ioctl_download = 1'b0;
      t0 = $time;
      while (fe_total < 2) begin
         if ($time - t0 > 200000 * 1000000) `FAIL("the second INIT_DONE was not sent")
         @(negedge clk);
      end
      walk_stream(base, 0, 256);
      if (nfrm != base + walk_n) `FAIL("stray frames in the second download")
      if (rom_rec != ROMSIZE + 256)
         `FAIL("the second download did not reach the ROM")
      if (act_downs != 2) `FAIL("ROMLOADER_ACTIVE did not fall the second time")
      t0 = $time;
      while (BUSY !== 1'b0) begin
         if ($time - t0 > 5000 * 1000000) `FAIL("BUSY stuck after the second INIT_DONE")
         @(negedge clk);
      end

      $display("tb_mcu_emu: PASS");
      $finish;
   end

   // global timeout
   initial begin
      #1_900_000_000;
      $display("tb_mcu_emu: FAIL timeout");
      $finish;
   end

endmodule
