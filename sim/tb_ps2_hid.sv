// Testbench for rtl/host/ps2_hid.sv (hps_io ps2_key -> USB HID boot report).
// Drives ps2_key events (bit 10 toggles per event, bit 9 pressed, bit 8 E0,
// bits 7..0 set-2 code) and checks the 6-key report, the modifier byte, slot
// order and the one-clock `changed` pulses. The last line printed is
// `tb_ps2_hid: PASS` or `tb_ps2_hid: FAIL <reason>`; run via
// sim/run_tb_ps2_hid.sh (iverilog -g2012).
`timescale 1ns / 1ps

module tb_ps2_hid;

   // report slices: [7:0] modifiers, [15:8] key 1 .. [55:48] key 6.
   localparam [55:0] NONE_REPORT = 56'h00000000000000;

   reg clk = 1'b0;
   always #5 clk = ~clk;         // 50 MHz, like MiSTer's CLK_50M

   reg  [10:0] ps2_key = 11'h000;
   wire [55:0] report;
   wire        changed;
   reg         reset = 1'b1;

   ps2_hid dut (
      .clk     (clk),
      .reset   (reset),
      .ps2_key (ps2_key),
      .report  (report),
      .changed (changed)
   );

   // changed is one clock, so it is counted once per event; counting at the
   // negedge and letting send() settle past that negedge keeps this race-free.
   integer pulses = 0;
   always @(negedge clk)
      if (changed === 1'b1) pulses = pulses + 1;

   // One PS/2 event: flip the toggle bit together with the payload.
   reg tog = 1'b0;
   task send(input pressed, input ext, input [7:0] code);
      begin
         @(negedge clk);
         tog     = ~tog;
         ps2_key = {tog, pressed, ext, code};
         @(negedge clk);              // the DUT consumes it at the posedge
         @(negedge clk);              // after that negedge; let it settle
      end
   endtask

   // No comma inside GOT/WANT: Verilog macro arguments split on commas.
   `define CHECK(WHAT, GOT, WANT)                                    \
      if ((GOT) !== (WANT)) begin                                    \
         $display("tb_ps2_hid: FAIL %s got %h want %h",              \
                  (WHAT), (GOT), (WANT));                            \
         $finish;                                                    \
      end

   integer p0;

   initial begin
      repeat (4) @(negedge clk);
      `CHECK("reset: report not zero", report, NONE_REPORT)
      reset = 1'b0;
      repeat (2) @(negedge clk);

      // press_release_a: A down -> key 1 = 0x04, changed once; up -> gone.
      p0 = pulses;
      send(1'b1, 1'b0, 8'h1C);                     // A
      `CHECK("press_release_a: pressed", report, 56'h00000000000400)
      `CHECK("press_release_a: press pulse", pulses, p0 + 1)
      send(1'b0, 1'b0, 8'h1C);
      `CHECK("press_release_a: released", report, NONE_REPORT)
      `CHECK("press_release_a: release pulse", pulses, p0 + 2)

      // modifiers: LShift + RAlt -> 0x02 | 0x40 = 0x42, keys stay empty.
      p0 = pulses;
      send(1'b1, 1'b0, 8'h12);                     // LShift
      `CHECK("modifiers: LShift", report, 56'h00000000000002)
      send(1'b1, 1'b1, 8'h11);                     // RAlt (E0 11)
      `CHECK("modifiers: LShift+RAlt", report, 56'h00000000000042)
      send(1'b0, 1'b0, 8'h12);
      `CHECK("modifiers: LShift off", report, 56'h00000000000040)
      send(1'b0, 1'b1, 8'h11);
      `CHECK("modifiers: all off", report, NONE_REPORT)
      `CHECK("modifiers: four pulses", pulses, p0 + 4)

      // seven_keys: A-G press -> keys 1..6 = A..F (0x04..0x09), G ignored;
      // release B -> slots compact to A,C,D,E,F, the freed slot stays free
      // (key 6 = 0x00: G is not added later).
      p0 = pulses;
      send(1'b1, 1'b0, 8'h1C);                     // A
      send(1'b1, 1'b0, 8'h32);                     // B
      send(1'b1, 1'b0, 8'h21);                     // C
      send(1'b1, 1'b0, 8'h23);                     // D
      send(1'b1, 1'b0, 8'h24);                     // E
      send(1'b1, 1'b0, 8'h2B);                     // F
      send(1'b1, 1'b0, 8'h34);                     // G - no slot left
      `CHECK("seven_keys: slots", report, 56'h09080706050400)
      `CHECK("seven_keys: six pulses", pulses, p0 + 6)
      send(1'b0, 1'b0, 8'h32);                     // release B
      `CHECK("seven_keys: compaction", report, 56'h00090807060400)
      `CHECK("seven_keys: compaction pulse", pulses, p0 + 7)
      send(1'b0, 1'b0, 8'h1C);                     // clear for the next case
      send(1'b0, 1'b0, 8'h21);
      send(1'b0, 1'b0, 8'h23);
      send(1'b0, 1'b0, 8'h24);
      send(1'b0, 1'b0, 8'h2B);
      `CHECK("seven_keys: cleared", report, NONE_REPORT)

      // extended_vs_keypad: E0 75 (Up, 0x52) is not keypad 8 (plain 75,
      // 0x60): releasing plain 75 must leave Up pressed.
      p0 = pulses;
      send(1'b1, 1'b1, 8'h75);                     // Up
      `CHECK("extended_vs_keypad: Up", report, 56'h00000000005200)
      send(1'b0, 1'b0, 8'h75);                     // plain 75 release: none
      `CHECK("extended_vs_keypad: Up stays", report, 56'h00000000005200)
      `CHECK("extended_vs_keypad: one pulse", pulses, p0 + 1)
      send(1'b0, 1'b1, 8'h75);                     // Up release
      `CHECK("extended_vs_keypad: Up released", report, NONE_REPORT)
      `CHECK("extended_vs_keypad: two pulses", pulses, p0 + 2)

      // repeat_press_ignored: typematic repeats of the held A change
      // nothing, changed stays low; so do codes without a usage (0x89).
      p0 = pulses;
      send(1'b1, 1'b0, 8'h1C);                     // A down
      `CHECK("repeat_press_ignored: A", report, 56'h00000000000400)
      send(1'b1, 1'b0, 8'h1C);                     // repeat
      send(1'b1, 1'b0, 8'h1C);                     // repeat
      send(1'b1, 1'b0, 8'h89);                     // unknown code
      send(1'b0, 1'b0, 8'h89);                     // unknown code
      `CHECK("repeat_press_ignored: report stays",
             report, 56'h00000000000400)
      `CHECK("repeat_press_ignored: still one pulse", pulses, p0 + 1)
      send(1'b0, 1'b0, 8'h1C);                     // A up
      `CHECK("repeat_press_ignored: released", report, NONE_REPORT)
      `CHECK("repeat_press_ignored: release pulse", pulses, p0 + 2)

      $display("tb_ps2_hid: PASS");
      $finish;
   end

endmodule
