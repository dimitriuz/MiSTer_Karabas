// tb_pc_trace.sv - rtl/host/pc_trace.sv: DEPTH instruction-fetch addresses after a trigger,
// sent as 'P' 'C' and address high/low pairs once the other sender is idle.
`timescale 1ns / 1ps
module tb_pc_trace;
    localparam integer AW = 4, DEPTH = 16;
    reg clk_bus = 1'b0, clk_sys = 1'b0;
    always #17.778 clk_bus = ~clk_bus;
    always #10 clk_sys = ~clk_sys;
    reg enable = 1'b0, trig = 1'b0, fetch = 1'b0, other_idle = 1'b0;
    reg [15:0] a = 16'h0000;
    reg  [7:0] di = 8'h00;
    wire [7:0] tx_data; wire tx_wr;
    pc_trace #(.BYTE_CLKS(60), .AW(AW)) dut (
        .clk_bus(clk_bus), .clk_sys(clk_sys), .enable(enable), .trig(trig),
        .fetch(fetch), .a(a), .di(di), .other_idle(other_idle), .tx_data(tx_data), .tx_wr(tx_wr));

    reg [7:0] got [0:255];
    integer ngot = 0, errors = 0, k;
    always @(posedge clk_sys) if (tx_wr) begin got[ngot] = tx_data; ngot = ngot + 1; end

    task fetch_at(input [15:0] addr);
    begin
        @(negedge clk_bus); a = addr; di = addr[7:0] ^ 8'h5A; fetch = 1'b1;
        repeat (6) @(negedge clk_bus);
        fetch = 1'b0;
        repeat (4) @(negedge clk_bus);
    end endtask

    initial begin
        repeat (20) @(posedge clk_bus);
        enable = 1'b1;
        repeat (10) @(posedge clk_bus);
        fetch_at(16'h1111);                       // before the trigger: not stored
        @(negedge clk_bus); trig = 1'b1; @(negedge clk_bus); trig = 1'b0;
        for (k = 0; k < DEPTH; k = k + 1) fetch_at(16'h3D00 + k * 3);
        fetch_at(16'h2222);                       // after the buffer is full: ignored
        repeat (800) @(posedge clk_sys);
        if (ngot !== 0) begin $display("FAIL sent %0d bytes while the other sender was busy", ngot); errors = errors + 1; end
        other_idle = 1'b1;
        repeat (4000) @(posedge clk_sys);
        if (ngot !== 2 + 3 * DEPTH) begin $display("FAIL %0d bytes, want %0d", ngot, 2 + 3 * DEPTH); errors = errors + 1; end
        if (got[0] !== "P" || got[1] !== "C") begin $display("FAIL header %h %h", got[0], got[1]); errors = errors + 1; end
        for (k = 0; k < DEPTH; k = k + 1)
            if ({got[2 + 3 * k], got[3 + 3 * k]} !== 16'h3D00 + k * 3 ||
                got[4 + 3 * k] !== (((16'h3D00 + k * 3) & 16'hFF) ^ 8'h5A)) begin
                $display("FAIL entry %0d: %h%h %h want %h", k, got[2 + 3 * k], got[3 + 3 * k], got[4 + 3 * k], 16'h3D00 + k * 3);
                errors = errors + 1;
            end
        if (errors == 0) $display("tb_pc_trace: PASS"); else $display("tb_pc_trace: FAIL %0d errors", errors);
        $finish;
    end
endmodule
