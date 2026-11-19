// Testbench for rtl/host/hotkeys.sv: Ctrl+Alt+Del / End / PgUp from ps2_key
// events. The last line is `tb_hotkeys: PASS` or `tb_hotkeys: FAIL <reason>`.
`timescale 1ns / 1ps
module tb_hotkeys;
    reg clk = 0;
    always #10 clk = ~clk;
    reg reset = 1;
    reg [10:0] key = 11'd0;
    reg  [1:0] turbo_now = 2'd0;
    wire hk_reset, hk_nmi, turbo_set;
    wire [1:0] turbo_new;
    integer fails = 0, rst_clk = 0, nmi_clk = 0, set_n = 0;

    hotkeys #(.HOLD(24'd20)) dut (.clk(clk), .reset(reset), .ps2_key(key),
        .turbo_now(turbo_now), .hk_reset(hk_reset), .hk_nmi(hk_nmi),
        .turbo_new(turbo_new), .turbo_set(turbo_set));

    always @(posedge clk) begin
        if (hk_reset) rst_clk <= rst_clk + 1;
        if (hk_nmi)   nmi_clk <= nmi_clk + 1;
        if (turbo_set) set_n <= set_n + 1;
    end

    task ev(input pr, input ex, input [7:0] c);
    begin
        @(posedge clk); key <= {~key[10], pr, ex, c};
        repeat (4) @(posedge clk);
    end
    endtask
    task chk(input ok, input [255:0] what);
    begin if (!ok) begin fails = fails + 1; $display("tb_hotkeys: FAIL %0s", what); end end
    endtask

    localparam CTRL = 8'h14, ALT = 8'h11;
    initial begin
        repeat (5) @(posedge clk); reset <= 0; repeat (3) @(posedge clk);
        // Del alone: nothing
        ev(1,1,8'h71); ev(0,1,8'h71); repeat (40) @(posedge clk);
        chk(rst_clk == 0, "del alone");
        // Ctrl only + Del: nothing
        ev(1,0,CTRL); ev(1,1,8'h71); ev(0,1,8'h71); repeat (40) @(posedge clk);
        chk(rst_clk == 0, "ctrl+del");
        // Ctrl+Alt+Del: reset for HOLD clk
        ev(1,0,ALT); ev(1,1,8'h71); repeat (40) @(posedge clk);
        chk(rst_clk >= 19 && rst_clk <= 21, "reset hold");
        chk(nmi_clk == 0, "no nmi");
        ev(0,1,8'h71);
        // End: NMI
        ev(1,1,8'h69); ev(0,1,8'h69); repeat (40) @(posedge clk);
        chk(nmi_clk >= 19 && nmi_clk <= 21, "nmi hold");
        // PgUp: turbo 0 -> 1, once per press; then 2 -> 3, 3 -> 0 (wrap)
        ev(1,1,8'h7D); ev(0,1,8'h7D); chk(set_n == 1 && turbo_new == 2'd1, "turbo 1");
        turbo_now = 2'd3; ev(1,1,8'h7D); ev(0,1,8'h7D);
        chk(set_n == 2 && turbo_new == 2'd0, "turbo wrap");
        // a repeated press event while held does not repeat
        turbo_now = 2'd0; ev(1,1,8'h7D); ev(1,1,8'h7D); ev(0,1,8'h7D);
        chk(set_n == 3, "no repeat");
        // right Ctrl / right Alt (E0 14, E0 11) count; releasing a modifier stops it
        ev(0,0,CTRL); ev(0,0,ALT); ev(1,1,CTRL); ev(1,1,ALT);
        ev(1,1,8'h69); ev(0,1,8'h69); repeat (40) @(posedge clk);
        chk(nmi_clk >= 39 && nmi_clk <= 43, "right mods");
        ev(0,1,CTRL); ev(1,1,8'h7D); ev(0,1,8'h7D);
        chk(set_n == 3, "ctrl released");
        if (fails == 0) $display("tb_hotkeys: PASS"); else $display("tb_hotkeys: FAIL (%0d)", fails);
        $finish;
    end
endmodule
