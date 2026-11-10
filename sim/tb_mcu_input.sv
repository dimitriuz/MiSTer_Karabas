// Testbench for the input side of rtl/host/mcu_emu.sv: the RTC block of the
// start sequence and the RTC, mouse and joystick frames of the run loop
// (protocol.md section 4; upstream kg_mcu_hid.v and kg_mcu_rtc.v). The frame
// decoder and the timeout guard are those of sim/tb_mcu_emu.sv; the link
// slave is a kg_spi_slave whose reply word the bench picks (a reply
// FA 0B 06 clears the RTC's BCD mode, as a CPU write of register B does).
//
// Checks:
//   start_rtc   after the 15 switch frames and before the keyboard clear,
//               256 RTC frames: the seven time registers of the fixed BCD
//               RTC 23:59:58 31.12.25 weekday 3, then 01 00, 03 00, 05 00,
//               0A 26, 0B 02, 0C 00, 0D 80 and FA 0E..FF FF;
//   rtc_toggle  the first toggle of RTC[64] sends the time frames at once:
//               they are the first frames after INIT_DONE; the clock then
//               ticks in the FPGA, so the next burst is one second later
//               (SEC_CLKS = RTC_CLKS here, and the bench reloads the clock
//               through RTC[64] right before each checked burst);
//   mouse       X=+5, Y=+3 (up), wheel up (8'hFF), left button is
//               02 00 05, 02 01 FD, 02 02 01, 02 03 01; wheel down 3 is
//               02 02 FD and 8'h80 (-128) clamps to 02 02 7F; X=-200
//               clamps to 81; two reports of X=+5 arriving while a keyboard
//               burst holds the link add to one report 02 00 0A;
//   joystick    joystick_0 = up+A is 03 00 43, 03 01 00, and the R frames
//               carry joystick_1 (the idle word: 03 02 01, 03 03 00);
//   rtc_binary  after a reply FA 0B 06 the time frames are binary: FA 00 3A,
//               FA 02 3B, FA 04 17, FA 06 04, FA 07 1F, FA 08 0C, FA 09 19.
// The last line printed is `tb_mcu_input: PASS` or `tb_mcu_input: FAIL
// <reason>`; run via sim/run_tb_mcu_input.sh (iverilog -g2012).
`timescale 1ns / 1ps

module tb_mcu_input;

   reg clk = 1'b0;
   always #10 clk = ~clk;                    // clk_sys 50 MHz

   reg reset = 1'b1;

   `define FAIL(MSG) begin \
      $display("tb_mcu_input: FAIL %s at %0t", (MSG), $time); \
      $finish; \
   end

   // wait for a condition to stop holding, with a timeout in microseconds
   // (50 clocks at the 20 ns clock); edge counting, not $time arithmetic -
   // the guard idiom of tb_mcu_emu.sv
   integer g_n;
   `define WAIT_GT(COND, BUDGET_US, WHY) begin                          \
         g_n = 0;                                                       \
         while (COND) begin                                             \
            if (g_n >= (BUDGET_US) * 50 || g_n < 0)                     \
               `FAIL(WHY)                                               \
            g_n = g_n + 1;                                              \
            @(negedge clk);                                             \
         end                                                            \
      end

   // ---------------- mcu_emu and its link slave ----------------

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
   reg          mem_ready      = 1'b1;
   reg          mounts_settled = 1'b1;   // the disk mounts have settled

   // hps_io RTC: BCD 23:59:58, 31.12.25, weekday 3; bit 64 is the update
   // toggle and starts at 0
   reg  [64:0]  rtc = {1'b0, 8'h00, 8'h03, 8'h25, 8'h12, 8'h31,
                       8'h23, 8'h59, 8'h58};
   reg  [24:0]  ps2_mouse     = 25'd0;
   reg  [15:0]  ps2_mouse_ext = 16'd0;
   reg  [31:0]  joy0 = 32'd0, joy1 = 32'd0;

   wire         spi_cs_n, spi_sck, spi_mosi, spi_miso;
   wire [23:0]  last_reply;
   wire         reply_valid;

   wire sck_dly, mosi_dly;    // the wire transport, as in tb_mcu_emu
   assign #5  sck_dly  = spi_sck;
   assign #15 mosi_dly = spi_mosi;

   mcu_emu #(
      .TRIGGER_CLKS (2000),   // 40 us
      .NOP_CLKS     (200),    // 4 us
      .RTC_CLKS     (5000),   // 100 us, so run-loop refreshes come quickly
      .SEC_CLKS     (5000)    // and one RTC second per refresh interval
   ) dut (
      .clk (clk), .reset (reset),
      .ioctl_download (ioctl_download), .ioctl_index (ioctl_index),
      .ioctl_wr (ioctl_wr), .ioctl_addr (ioctl_addr),
      .ioctl_dout (ioctl_dout), .ioctl_wait (ioctl_wait),
      .status (status), .osd_reset (osd_reset),
      .kb_report (kb_report), .kb_changed (kb_changed),
      .rtc (rtc), .ps2_mouse (ps2_mouse), .ps2_mouse_ext (ps2_mouse_ext),
      .joy0 (joy0), .joy1 (joy1),
      .mem_ready (mem_ready),
      .mounts_settled (mounts_settled),
      .spi_cs_n (spi_cs_n), .spi_sck (spi_sck), .spi_mosi (spi_mosi),
      .spi_miso (spi_miso),
      .last_reply (last_reply), .reply_valid (reply_valid)
   );

   // the slave preloads di every clock: the bench sets the reply word of
   // the next frame directly
   reg [23:0] stub_word = 24'hFF0000;     // NOPE
   kg_spi_slave #(.N (24)) stub (
      .clk (clk), .sck (sck_dly), .ssel (spi_cs_n), .mosi (mosi_dly),
      .miso (spi_miso),
      .di (stub_word), .wren (1'b1), .di_req (),
      .do_valid (), .dout ()
   );

   // ---------------- frame decoder (the link wires) ----------------

   reg [23:0] flog [0:8191];
   integer    nfrm = 0;
   integer    cbits = 0;
   reg [23:0] cword = 24'd0;

   always @(negedge spi_cs_n) cbits = 0;
   always @(posedge sck_dly)
      if (!reset && !spi_cs_n) begin
         cword = {cword[22:0], mosi_dly};
         cbits = cbits + 1;
      end
   always @(posedge spi_cs_n)
      if (!reset && cbits == 24) begin
         if (nfrm >= 8192) `FAIL("frame log overflow")
         flog[nfrm] = cword;
         nfrm = nfrm + 1;
      end

   // ---------------- expected frames ----------------

   // the RTC block of the start sequence, k = 0..255
   function [23:0] rtc_start;
      input integer k;
      begin
         case (k)
            0:  rtc_start = 24'hFA0058;   // sec   (BCD)
            1:  rtc_start = 24'hFA0259;   // min
            2:  rtc_start = 24'hFA0423;   // hour
            3:  rtc_start = 24'hFA0604;   // weekday (0-6 + 1)
            4:  rtc_start = 24'hFA0731;   // date
            5:  rtc_start = 24'hFA0812;   // month
            6:  rtc_start = 24'hFA0925;   // year
            7:  rtc_start = 24'hFA0100;   // 01: seconds alarm
            8:  rtc_start = 24'hFA0300;   // 03: minutes alarm
            9:  rtc_start = 24'hFA0500;   // 05: hours alarm
            10: rtc_start = 24'hFA0A26;   // 0A: century 20
            11: rtc_start = 24'hFA0B02;   // 0B: BCD, 24 h
            12: rtc_start = 24'hFA0C00;   // 0C: flags
            13: rtc_start = 24'hFA0D80;   // 0D: valid RAM/time
            default: rtc_start = {8'hFA, k[7:0], 8'hFF};
         endcase
      end
   endfunction

   // the run-loop time frames, BCD
   function [23:0] rtc_time;
      input integer k;
      begin
         case (k)
            0:  rtc_time = 24'hFA0058;
            1:  rtc_time = 24'hFA0259;
            2:  rtc_time = 24'hFA0423;
            3:  rtc_time = 24'hFA0604;
            4:  rtc_time = 24'hFA0731;
            5:  rtc_time = 24'hFA0812;
            default: rtc_time = 24'hFA0925;
         endcase
      end
   endfunction

   // wait until frame `want` appears at or after frame `from`
   integer find_i;
   task find_frame;
      input integer from;
      input [23:0]  want;
      input integer budget_us;
      begin
         find_i = from;
         g_n = 0;
         while (find_i >= nfrm || flog[find_i] !== want) begin
            if (g_n >= budget_us * 50 || g_n < 0) begin
               $display("tb_mcu_input: FAIL frame %6h not seen from %0d at %0t",
                        want, from, $time);
               for (i = (from > 16 ? from - 16 : 0);
                    i < nfrm && i < from + 40; i = i + 1)
                  $display("  frame %0d: %6h", i, flog[i]);
               $finish;
            end
            g_n = g_n + 1;
            @(negedge clk);
            if (find_i < nfrm && flog[find_i] !== want)
               find_i = find_i + 1;
         end
      end
   endtask

   task chkfrm;
      input integer j;
      input [23:0]  want;
      begin
         if (flog[j] !== want) begin
            $display("tb_mcu_input: FAIL frame %0d is %6h expected %6h at %0t",
                     j, flog[j], want, $time);
            $finish;
         end
      end
   endtask

   // wait for a CMD_RTC seconds frame (FA 00), the first frame of a time
   // burst, at or after `from`
   integer find_sec_i;
   task find_sec;
      input integer from;
      input integer budget_us;
      begin
         find_sec_i = from;
         g_n = 0;
         while (find_sec_i >= nfrm ||
                flog[find_sec_i][23:16] !== 8'hFA ||
                flog[find_sec_i][15:8] !== 8'h00) begin
            if (g_n >= budget_us * 50 || g_n < 0) begin
               $display("tb_mcu_input: FAIL no RTC seconds frame from %0d at %0t",
                        from, $time);
               $finish;
            end
            g_n = g_n + 1;
            @(negedge clk);
            if (find_sec_i < nfrm &&
                !(flog[find_sec_i][23:16] === 8'hFA &&
                  flog[find_sec_i][15:8] === 8'h00))
               find_sec_i = find_sec_i + 1;
         end
      end
   endtask

   // ---------------- ioctl source ----------------

   task stream16;
      integer k;
      begin
         ioctl_download = 1'b1;
         for (k = 0; k < 16; k = k + 1) begin
            if (k != 0) @(negedge clk);  // the first byte rides the
            else         #1;             // download edge itself
            ioctl_addr = k[26:0];
            ioctl_dout = k[7:0];
            ioctl_wr   = 1'b1;
            @(posedge clk);
            #1;
            ioctl_wr   = 1'b0;
            while (ioctl_wait === 1'b1) @(posedge clk);
         end
         ioctl_download = 1'b0;
      end
   endtask

   // ---------------- main ----------------

   integer i, j, base, n0;

   initial begin
      repeat (20) @(negedge clk);
      reset = 1'b0;

      // the first RTC[64] toggle: the run loop must refresh the time at
      // once, not only on the RTC_CLKS tick
      #101;
      rtc[64] = 1'b1;

      // a 16-byte boot.rom download carries the whole start sequence
      stream16;

      // pin the FPGA clock: ROMLOADER off, then a reload keeps the start
      // block (latched at the last switch) at 23:59:58
      find_frame(0, 24'h080000, 20000);
      @(negedge clk);
      rtc[64] = ~rtc[64];
      // and another reload right before INIT_DONE pins the first run-loop
      // burst the same way
      find_frame(0, 24'h010600, 20000);
      @(negedge clk);
      rtc[64] = ~rtc[64];

      `WAIT_GT(nfrm < 1, 20000, "no frame at all")
      find_frame(0, 24'hFE0000, 20000);
      base = find_i;                 // INIT_DONE

      // start_rtc: the RTC block sits between the last switch (index 15,
      // the Mode item) and the keyboard clear
      find_frame(0, 24'h050F00, 20000);
      j = find_i;
      for (i = 0; i < 256; i = i + 1)
         chkfrm(j + 1 + i, rtc_start(i));
      for (i = 0; i < 7; i = i + 1)
         chkfrm(j + 257 + i, {8'h01, i[7:0], 8'h00});
      chkfrm(j + 264, 24'hFE0000);
      if (j + 264 != base)
         `FAIL("INIT_DONE is not the frame after the start sequence")

      // rtc_toggle: the time frames are the first frames of the run loop
      `WAIT_GT(nfrm < base + 8, 5000, "no RTC time frames after INIT_DONE")
      for (i = 0; i < 7; i = i + 1)
         chkfrm(base + 1 + i, rtc_time(i));

      // the FPGA clock ticks: the next burst is one second later
      find_frame(base + 8, 24'hFA0059, 5000);
      j = find_i;
      `WAIT_GT(nfrm < j + 7, 5000, "the second time burst did not finish")
      chkfrm(j + 1, 24'hFA0259);
      chkfrm(j + 2, 24'hFA0423);
      chkfrm(j + 3, 24'hFA0604);
      chkfrm(j + 4, 24'hFA0731);
      chkfrm(j + 5, 24'hFA0812);
      chkfrm(j + 6, 24'hFA0925);

      // mouse: X=+5, Y=+3 (up), wheel -1 (MiSTer's wheel up), left button
      @(negedge clk);
      ps2_mouse[7:0]     = 8'h01;
      ps2_mouse[15:8]    = 8'h05;
      ps2_mouse[23:16]   = 8'h03;
      ps2_mouse[24]      = 1'b1;
      ps2_mouse_ext[7:0] = 8'hFF;
      find_frame(base, 24'h020005, 2000);
      j = find_i;
      `WAIT_GT(nfrm < j + 4, 5000, "the mouse report did not finish")
      chkfrm(j + 1, 24'h0201FD);     // Y = -3
      chkfrm(j + 2, 24'h020201);     // wheel +1
      chkfrm(j + 3, 24'h020301);     // left button

      // X = -200 (9-bit sign bit + 0x38) clamps to -127 = 0x81
      @(negedge clk);
      ps2_mouse[7:0]   = 8'h00;
      ps2_mouse[4]     = 1'b1;
      ps2_mouse[15:8]  = 8'h38;
      ps2_mouse[23:16] = 8'h00;
      ps2_mouse[24]    = 1'b0;
      ps2_mouse_ext    = 16'd0;
      find_frame(j + 4, 24'h020081, 2000);
      j = find_i;
      `WAIT_GT(nfrm < j + 4, 5000, "the clamped mouse report did not finish")
      chkfrm(j + 1, 24'h020100);
      chkfrm(j + 2, 24'h020200);
      chkfrm(j + 3, 24'h020300);

      // wheel down 3 from the user (mousedev: +3) is -3 to the MCU
      @(negedge clk);
      ps2_mouse[4]       = 1'b0;
      ps2_mouse[15:8]    = 8'h00;
      ps2_mouse[23:16]   = 8'h00;
      ps2_mouse[24]      = 1'b1;
      ps2_mouse_ext[7:0] = 8'h03;
      find_frame(j + 4, 24'h020000, 2000);
      j = find_i;
      `WAIT_GT(nfrm < j + 4, 5000, "the wheel-down report did not finish")
      chkfrm(j + 1, 24'h020100);
      chkfrm(j + 2, 24'h0202FD);     // wheel -3
      chkfrm(j + 3, 24'h020300);

      // 8'h80 (-128) negates to +128, which clamps to +127
      @(negedge clk);
      ps2_mouse[24]      = 1'b0;
      ps2_mouse_ext[7:0] = 8'h80;
      find_frame(j + 4, 24'h020000, 2000);
      j = find_i;
      `WAIT_GT(nfrm < j + 4, 5000, "the clamped wheel report did not finish")
      chkfrm(j + 1, 24'h020100);
      chkfrm(j + 2, 24'h02027F);     // wheel +127
      chkfrm(j + 3, 24'h020300);

      // two +5 reports while a keyboard burst holds the link: the deltas
      // add to one report of 0x0A
      @(negedge clk);
      ps2_mouse[4]     = 1'b0;
      ps2_mouse[15:8]  = 8'h05;
      ps2_mouse[23:16] = 8'h00;
      ps2_mouse[7:0]   = 8'h00;
      ps2_mouse_ext    = 16'd0;
      kb_report  = {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h04, 8'h02};
      kb_changed = 1'b1;
      @(negedge clk);
      kb_changed = 1'b0;
      find_frame(j + 4, 24'h010104, 2000);   // the burst is in flight
      base = find_i;
      @(negedge clk);
      ps2_mouse[24] = 1'b1;
      @(negedge clk);
      ps2_mouse[24] = 1'b0;
      find_frame(base + 1, 24'h02000A, 5000);
      j = find_i;
      `WAIT_GT(nfrm < j + 4, 5000, "the accumulated mouse report did not finish")
      chkfrm(j + 1, 24'h020100);
      chkfrm(j + 2, 24'h020200);
      chkfrm(j + 3, 24'h020300);
      n0 = 0;
      for (i = base + 1; i <= j; i = i + 1)
         if (flog[i][23:16] == 8'h02 && flog[i][15:8] == 8'h00)
            n0 = n0 + 1;
      if (n0 != 1) `FAIL("the two mouse reports were not one 0A report")

      // a toggle on the very edge that fires the burst's first frame must
      // not add to the deltas already on their way: the next report carries
      // only the new delta
      @(negedge clk);
      ps2_mouse[7:0]   = 8'h00;
      ps2_mouse[15:8]  = 8'h05;
      ps2_mouse[23:16] = 8'h00;
      ps2_mouse[24]    = ~ps2_mouse[24];   // a report waits for the link
      // wait until the arbiter is one clock away from firing its frame 0
      g_n = 0;
      while (!(dut.fire && dut.faction == 5'd14 && dut.ms_i == 2'd0)) begin
         if (g_n >= 5000 * 50) `FAIL("the mouse burst never came up")
         g_n = g_n + 1;
         @(negedge clk);
      end
      ps2_mouse[24] = ~ps2_mouse[24];      // a report on that same edge
      find_frame(j + 4, 24'h020005, 2000);
      j = find_i;
      `WAIT_GT(nfrm < j + 4, 5000, "the edge report did not finish")
      chkfrm(j + 1, 24'h020100);
      chkfrm(j + 2, 24'h020200);
      chkfrm(j + 3, 24'h020300);
      find_frame(j + 4, 24'h020005, 2000);
      j = find_i;
      `WAIT_GT(nfrm < j + 4, 5000, "the second edge report did not finish")
      chkfrm(j + 1, 24'h020100);
      chkfrm(j + 2, 24'h020200);
      chkfrm(j + 3, 24'h020300);

      // joystick_0 = up + A: word 0x0043; joystick_1 is the idle word
      @(negedge clk);
      joy0 = (1 << 3) | (1 << 4);
      find_frame(j + 4, 24'h030043, 2000);
      j = find_i;
      `WAIT_GT(nfrm < j + 4, 5000, "the joystick report did not finish")
      chkfrm(j + 1, 24'h030100);
      chkfrm(j + 2, 24'h030201);
      chkfrm(j + 3, 24'h030300);

      // a reply FA 0B 06 clears BCD mode; the clock is reloaded right after
      // a burst so the next one is the binary form of the pinned 23:59:58
      @(negedge clk);
      stub_word = 24'hFA0B06;
      #5000;                          // a frame carries the reply
      stub_word = 24'hFF0000;
      find_sec(nfrm, 5000);           // a time burst is in flight
      @(negedge clk);
      rtc[64] = ~rtc[64];
      find_frame(find_sec_i + 1, 24'hFA003A, 5000);
      j = find_i;
      `WAIT_GT(nfrm < j + 7, 5000, "the binary time burst did not finish")
      chkfrm(j + 1, 24'hFA023B);
      chkfrm(j + 2, 24'hFA0417);
      chkfrm(j + 3, 24'hFA0604);
      chkfrm(j + 4, 24'hFA071F);
      chkfrm(j + 5, 24'hFA080C);
      chkfrm(j + 6, 24'hFA0919);

      $display("tb_mcu_input: PASS");
      $finish;
   end

   // global timeout
   initial begin
      #50_000_000;
      $display("tb_mcu_input: FAIL timeout");
      $finish;
   end

endmodule