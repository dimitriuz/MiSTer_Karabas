// Testbench for rtl/host/mount_settle.sv: when the machine may start.
// SETTLE_CLKS and BUDGET_CLKS are small, so the windows are counted in
// clocks here. The initial block drives `mounted` on clk edges and counts
// the clocks until `settled` rises.
//
// Checks:
//   budget  reset with no mount: not settled before BUDGET_CLKS, settled
//           at BUDGET_CLKS;
//   mount   a disk mount restarts the wait at SETTLE_CLKS, and `settled`
//           stays low until it has run out;
//   extend  a second mount during the window restarts it again;
//   floppy  mounted[4] and mounted[5] (the floppy images, stage 4c)
//           restart it like any other disk image;
//   tape    mounted[0] (the tape) does not restart it;
//   level   a mount bit that is left up (hps_io's img_mounted is a level and
//           clears only on the next ioctl command) restarts the wait once,
//           not on every clock: with a level reload the machine never starts
//           and the screen stays black (board, 2026-11-11).
// The last line printed is `tb_mount_settle: PASS` or
// `tb_mount_settle: FAIL <case>`; run via sim/run_tb_mount_settle.sh.
`timescale 1ns / 1ps

module tb_mount_settle;

   localparam integer SETTLE = 10;
   localparam integer BUDGET = 50;

   reg clk = 1'b0;
   always #10 clk = ~clk;

   reg        reset = 1'b1;
   reg  [5:0] mounted = 6'd0;
   wire       settled;

   mount_settle #(.SETTLE_CLKS (SETTLE), .BUDGET_CLKS (BUDGET)) dut (
      .clk (clk), .reset (reset), .mounted (mounted), .settled (settled)
   );

   integer fail_cnt = 0;
   integer n;

   task check(input [8*10-1:0] cs, input [8*30-1:0] what,
              input integer got, input integer want);
      begin
         if (got !== want) begin
            $display("FAIL %0s %0s got %0d want %0d", cs, what, got, want);
            fail_cnt = fail_cnt + 1;
         end
      end
   endtask

   // clocks until settled, or -1 after `limit`
   task count_until_settled(input integer limit, output integer cnt);
      begin
         cnt = 0;
         while (!settled && cnt < limit) begin
            @(posedge clk); #1;
            cnt = cnt + 1;
         end
         if (settled) cnt = cnt;
         else cnt = -1;
      end
   endtask

   initial begin
      $display("tb_mount_settle: start");

      // ---- budget: no mount at all ----
      reset = 1'b1;
      repeat (3) @(posedge clk); #1;
      reset = 1'b0;
      count_until_settled(BUDGET + 20, n);
      check("budget", "settled after BUDGET clocks", n, BUDGET);

      // ---- mount: a disk mount restarts the window ----
      reset = 1'b1;
      repeat (3) @(posedge clk); #1;
      reset = 1'b0;
      repeat (5) @(posedge clk); #1;       // 5 clocks into the budget
      mounted = 6'b000010;                // slot 1, the SD card
      @(posedge clk); #1;
      mounted = 6'd0;
      check("mount", "held right after the mount", settled, 0);
      count_until_settled(SETTLE + 20, n);
      check("mount", "settled a SETTLE window later", n, SETTLE);

      // ---- floppy: slots 4, 5 (the drive images) restart the window ----
      // The slots the settle used not to know (they arrive with stage 4c):
      // left out, the machine starts onto an unsettled image.
      reset = 1'b1;
      repeat (3) @(posedge clk); #1;
      reset = 1'b0;
      repeat (2) @(posedge clk); #1;
      mounted = 6'b010000;                // slot 4, floppy drive A
      @(posedge clk); #1;
      mounted = 6'd0;
      count_until_settled(SETTLE + 20, n);
      check("floppy", "drive A settled a SETTLE window after its mount",
            n, SETTLE);
      reset = 1'b1;
      repeat (3) @(posedge clk); #1;
      reset = 1'b0;
      repeat (2) @(posedge clk); #1;
      mounted = 6'b100000;                // slot 5, floppy drive B
      @(posedge clk); #1;
      mounted = 6'd0;
      count_until_settled(SETTLE + 20, n);
      check("floppy", "drive B settles too", n, SETTLE);

      // ---- extend: a second mount during the window ----
      reset = 1'b1;
      repeat (3) @(posedge clk); #1;
      reset = 1'b0;
      repeat (2) @(posedge clk); #1;
      mounted = 6'b000100;                // slot 2, IDE 0
      @(posedge clk); #1;
      mounted = 6'd0;
      repeat (4) @(posedge clk); #1;
      mounted = 6'b001000;                // slot 3, IDE 1
      @(posedge clk); #1;
      mounted = 6'd0;
      count_until_settled(SETTLE + 20, n);
      check("extend", "settled a SETTLE window after the last mount",
            n, SETTLE);

      // ---- level: a bit left up restarts it once, then it settles ----
      reset = 1'b1;
      repeat (3) @(posedge clk); #1;
      reset = 1'b0;
      repeat (5) @(posedge clk); #1;
      mounted = 6'b000100;                // slot 2, and it stays up
      @(posedge clk); #1;
      count_until_settled(SETTLE + 20, n);
      check("level", "settled a SETTLE window after the edge", n, SETTLE);
      mounted = 6'd0;

      // ---- tape: slot 0 does not count ----
      reset = 1'b1;
      repeat (3) @(posedge clk); #1;
      reset = 1'b0;
      repeat (5) @(posedge clk); #1;
      mounted = 6'b000001;                // slot 0, the tape
      @(posedge clk); #1;
      mounted = 6'd0;
      count_until_settled(BUDGET + 20, n);
      check("tape", "the tape leaves the budget running", n, BUDGET - 6);

      if (fail_cnt == 0) $display("tb_mount_settle: PASS");
      else $display("tb_mount_settle: FAIL %0d checks", fail_cnt);
      $finish;
   end

endmodule
