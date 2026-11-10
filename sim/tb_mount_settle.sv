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
//   tape    mounted[0] (the tape) does not restart it.
// The last line printed is `tb_mount_settle: PASS` or
// `tb_mount_settle: FAIL <case>`; run via sim/run_tb_mount_settle.sh.
`timescale 1ns / 1ps

module tb_mount_settle;

   localparam integer SETTLE = 10;
   localparam integer BUDGET = 50;

   reg clk = 1'b0;
   always #10 clk = ~clk;

   reg        reset = 1'b1;
   reg  [3:0] mounted = 4'd0;
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
      mounted = 4'b0010;                    // slot 1, the SD card
      @(posedge clk); #1;
      mounted = 4'd0;
      check("mount", "held right after the mount", settled, 0);
      count_until_settled(SETTLE + 20, n);
      check("mount", "settled a SETTLE window later", n, SETTLE);

      // ---- extend: a second mount during the window ----
      reset = 1'b1;
      repeat (3) @(posedge clk); #1;
      reset = 1'b0;
      repeat (2) @(posedge clk); #1;
      mounted = 4'b0100;                    // slot 2, IDE 0
      @(posedge clk); #1;
      mounted = 4'd0;
      repeat (4) @(posedge clk); #1;
      mounted = 4'b1000;                    // slot 3, IDE 1
      @(posedge clk); #1;
      mounted = 4'd0;
      count_until_settled(SETTLE + 20, n);
      check("extend", "settled a SETTLE window after the last mount",
            n, SETTLE);

      // ---- tape: slot 0 does not count ----
      reset = 1'b1;
      repeat (3) @(posedge clk); #1;
      reset = 1'b0;
      repeat (5) @(posedge clk); #1;
      mounted = 4'b0001;                    // slot 0, the tape
      @(posedge clk); #1;
      mounted = 4'd0;
      count_until_settled(BUDGET + 20, n);
      check("tape", "the tape leaves the budget running", n, BUDGET - 6);

      if (fail_cnt == 0) $display("tb_mount_settle: PASS");
      else $display("tb_mount_settle: FAIL %0d checks", fail_cnt);
      $finish;
   end

endmodule
