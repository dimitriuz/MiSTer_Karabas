// Testbench for rtl/host/bcd_clock.sv: the RTC registers mcu_emu sends,
// loaded from hps_io's BCD RTC and ticked in the FPGA between HPS updates.
// SEC_CLKS is small so a second is a few clocks.
//
// Checks (hps_io layout {weekday 0-6, year, month, date, hour, min, sec},
// BCD; the output keeps that layout with weekday 1-7):
//   load   23:59:58 31.12.25 weekday 3 -> now weekday 04;
//   ticks  after two seconds: 00:00:00 01.01.26 weekday 05;
//   leap  23:59:59 28.02.24 -> 29.02.24, 29.02.24 -> 01.03.24,
//         28.02.25 -> 01.03.25;
//   month 30.04.25 -> 01.05.25, 31.05.25 -> 01.06.25;
//   wday  weekday 07 -> 01 at the day rollover;
//   carry 12:34:59 -> 12:35:00;
//   year  31.12.99 -> 01.01.00;
//   reload:a toggle of rtc[64] in the middle of a run loads the new time
//         and restarts the second counter.
// The last line printed is `tb_bcd_clock: PASS` or `tb_bcd_clock: FAIL
// <case>`; run via sim/run_tb_bcd_clock.sh (iverilog -g2012).
`timescale 1ns / 1ps

module tb_bcd_clock;

   localparam integer SEC_CLKS = 5;   // a second is five 20 ns clocks

   reg clk = 1'b0;
   always #10 clk = ~clk;

   reg reset = 1'b1;
   reg [64:0] rtc = 65'd0;
   wire [55:0] now;

   bcd_clock #(.SEC_CLKS (SEC_CLKS)) dut (
      .clk (clk), .reset (reset), .rtc (rtc), .now (now)
   );

   // hps_io's RTC bytes (weekday 0-6)
   function [55:0] hps_time;
      input [7:0] wd, y, mo, d, h, mi, s;
      begin
         hps_time = {wd, y, mo, d, h, mi, s};
      end
   endfunction

   // bcd_clock's now: the same bytes, weekday 1-7
   function [55:0] exp_time;
      input [7:0] wd, y, mo, d, h, mi, s;
      begin
         exp_time = {wd, y, mo, d, h, mi, s};
      end
   endfunction

   task chk;
      input [55:0] want;
      input integer id;
      begin
         if (now !== want) begin
            $display("tb_bcd_clock: FAIL case %0d: now %14h expected %14h",
                     id, now, want);
            $finish;
         end
      end
   endtask

   // drive an hps time and toggle rtc[64]: the clock loads it
   task load;
      input [55:0] t;
      begin
         @(negedge clk);
         rtc[55:0] = t;
         rtc[64]   = ~rtc[64];
         @(negedge clk);
      end
   endtask

   task ticks;
      input integer n;
      begin
         repeat (n * SEC_CLKS) @(negedge clk);
      end
   endtask

   initial begin
      // the reset load (hps weekday 3 -> now 4)
      rtc = {1'b0, hps_time(8'h03, 8'h25, 8'h12, 8'h31, 8'h23, 8'h59, 8'h58)};
      repeat (5) @(negedge clk);
      reset = 1'b0;
      @(negedge clk);
      chk(exp_time(8'h04, 8'h25, 8'h12, 8'h31, 8'h23, 8'h59, 8'h58), 1);

      // two ticks: the day, month and year roll over
      ticks(2);
      chk(exp_time(8'h05, 8'h26, 8'h01, 8'h01, 8'h00, 8'h00, 8'h00), 2);

      // leap year 2024
      load(hps_time(8'h03, 8'h24, 8'h02, 8'h28, 8'h23, 8'h59, 8'h59));
      ticks(1);
      chk(exp_time(8'h05, 8'h24, 8'h02, 8'h29, 8'h00, 8'h00, 8'h00), 3);

      load(hps_time(8'h04, 8'h24, 8'h02, 8'h29, 8'h23, 8'h59, 8'h59));
      ticks(1);
      chk(exp_time(8'h06, 8'h24, 8'h03, 8'h01, 8'h00, 8'h00, 8'h00), 4);

      // 2025 is not a leap year
      load(hps_time(8'h05, 8'h25, 8'h02, 8'h28, 8'h23, 8'h59, 8'h59));
      ticks(1);
      chk(exp_time(8'h07, 8'h25, 8'h03, 8'h01, 8'h00, 8'h00, 8'h00), 5);

      // 30- and 31-day months
      load(hps_time(8'h03, 8'h25, 8'h04, 8'h30, 8'h23, 8'h59, 8'h59));
      ticks(1);
      chk(exp_time(8'h05, 8'h25, 8'h05, 8'h01, 8'h00, 8'h00, 8'h00), 6);

      load(hps_time(8'h03, 8'h25, 8'h05, 8'h31, 8'h23, 8'h59, 8'h59));
      ticks(1);
      chk(exp_time(8'h05, 8'h25, 8'h06, 8'h01, 8'h00, 8'h00, 8'h00), 7);

      // weekday 7 wraps to 1
      load(hps_time(8'h06, 8'h25, 8'h05, 8'h31, 8'h23, 8'h59, 8'h59));
      ticks(1);
      chk(exp_time(8'h01, 8'h25, 8'h06, 8'h01, 8'h00, 8'h00, 8'h00), 8);

      // a plain minute carry
      load(hps_time(8'h05, 8'h25, 8'h06, 8'h15, 8'h12, 8'h34, 8'h59));
      ticks(1);
      chk(exp_time(8'h06, 8'h25, 8'h06, 8'h15, 8'h12, 8'h35, 8'h00), 9);

      // the year wraps past 99
      load(hps_time(8'h03, 8'h99, 8'h12, 8'h31, 8'h23, 8'h59, 8'h59));
      ticks(1);
      chk(exp_time(8'h05, 8'h00, 8'h01, 8'h01, 8'h00, 8'h00, 8'h00), 10);

      // a mid-run toggle loads the new time and restarts the counter
      load(hps_time(8'h05, 8'h25, 8'h06, 8'h15, 8'h12, 8'h34, 8'h59));
      ticks(3);
      chk(exp_time(8'h06, 8'h25, 8'h06, 8'h15, 8'h12, 8'h35, 8'h02), 11);
      load(hps_time(8'h02, 8'h26, 8'h01, 8'h01, 8'h00, 8'h00, 8'h00));
      chk(exp_time(8'h03, 8'h26, 8'h01, 8'h01, 8'h00, 8'h00, 8'h00), 12);
      ticks(1);
      chk(exp_time(8'h03, 8'h26, 8'h01, 8'h01, 8'h00, 8'h00, 8'h01), 13);

      $display("tb_bcd_clock: PASS");
      $finish;
   end

   initial begin
      #1000000;
      $display("tb_bcd_clock: FAIL timeout");
      $finish;
   end

endmodule