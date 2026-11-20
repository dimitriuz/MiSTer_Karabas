// tb_core_beacon.sv - rtl/host/core_beacon.sv: the heartbeat line on the UART pin.
`timescale 1ns / 1ps
module tb_core_beacon;
    localparam integer CPB = 8, WINC = 4000;
    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg [7:0] flags = 8'hA5;
    reg t_bus = 0, t_mem = 0, t_vid = 0, t_vs = 0, t_cpu = 0;
    wire tx;
    core_beacon #(.CLKS_PER_BIT(CPB), .WIN(WINC)) dut (
        .clk(clk), .flags(flags), .t_bus(t_bus), .t_mem(t_mem), .t_vid(t_vid),
        .t_vs(t_vs), .t_cpu(t_cpu), .tx(tx));
    always #200 t_bus = ~t_bus;           // an edge every 10 clk
    always #1000 t_vid = ~t_vid;          // an edge every 50 clk
    always #4000 t_cpu = ~t_cpu;          // t_mem and t_vs stay dead (0000)

    // a UART receiver: 8 data bits LSB first
    reg [7:0] chars [0:127];
    integer n = 0, errors = 0;
    integer i;
    reg [7:0] c;
    initial begin
        forever begin
            @(negedge tx);
            repeat (CPB + CPB / 2) @(posedge clk);
            c = 0;
            for (i = 0; i < 8; i = i + 1) begin c[i] = tx; repeat (CPB) @(posedge clk); end
            if (tx !== 1'b1) begin $display("FAIL stop bit low"); errors = errors + 1; end
            chars[n] = c; n = n + 1;
        end
    end
    integer k;
    initial begin
        repeat (WINC * 3 + 2000) @(posedge clk);
        if (n < 33 * 2) begin $display("FAIL only %0d characters", n); errors = errors + 1; end
        // the second line (the first window has partial counts)
        if (chars[33] !== "S" || chars[34] !== "A" || chars[35] !== "5") begin
            $display("FAIL line head %c%c%c", chars[33], chars[34], chars[35]); errors = errors + 1; end
        for (k = 0; k < 6; k = k + 1)
            if (chars[36 + 5 * k] !== 8'h20) begin $display("FAIL separator %0d", k); errors = errors + 1; end
        if (chars[37] === "0" && chars[38] === "0" && chars[39] === "0" && chars[40] === "0") begin
            $display("FAIL bus count is zero"); errors = errors + 1; end
        if (chars[42] !== "0" || chars[43] !== "0" || chars[44] !== "0" || chars[45] !== "0") begin
            $display("FAIL mem count must be 0000, got %c%c%c%c", chars[42], chars[43], chars[44], chars[45]); errors = errors + 1; end
        if (chars[47] === "0" && chars[48] === "0" && chars[49] === "0" && chars[50] === "0") begin
            $display("FAIL vid count is zero"); errors = errors + 1; end
        if (chars[64] !== 8'h0D || chars[65] !== 8'h0A) begin $display("FAIL line end"); errors = errors + 1; end
        $write("tb_core_beacon: line = ");
        for (k = 33; k < 66; k = k + 1) if (chars[k] >= 32) $write("%c", chars[k]);
        $write("\n");
        if (errors == 0) $display("tb_core_beacon: PASS"); else $display("tb_core_beacon: FAIL %0d errors", errors);
        $finish;
    end
endmodule
