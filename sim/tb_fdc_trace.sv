// tb_fdc_trace.sv - rtl/host/fdc_trace.sv: FDC accesses seen on a clk_bus bus cycle come
// out as three-byte records on the clk_sys byte port.
`timescale 1ns / 1ps
module tb_fdc_trace;
    reg clk_bus = 1'b0, clk_sys = 1'b0;
    always #17.778 clk_bus = ~clk_bus;
    always #10 clk_sys = ~clk_sys;

    reg enable = 1'b0;
    reg dbg_wr = 1'b0, dbg_rd = 1'b0, dbg_ff = 1'b0;
    reg [1:0] dbg_reg = 2'd0;
    reg [7:0] dbg_d = 8'd0, dbg_q = 8'd0;
    wire [7:0] tx_data;
    wire tx_wr;

    fdc_trace #(.BYTE_CLKS(200)) dut (
        .clk_bus(clk_bus), .clk_sys(clk_sys), .enable(enable),
        .dbg_wr(dbg_wr), .dbg_rd(dbg_rd), .dbg_ff(dbg_ff), .dbg_reg(dbg_reg),
        .dbg_d(dbg_d), .dbg_q(dbg_q), .tx_data(tx_data), .tx_wr(tx_wr)
    );

    reg [7:0] got [0:1023];
    integer ngot = 0, errors = 0;
    always @(posedge clk_sys) if (tx_wr) begin got[ngot] = tx_data; ngot = ngot + 1; end

    task wr(input ff, input [1:0] r, input [7:0] v);
    begin
        @(negedge clk_bus); dbg_ff = ff; dbg_reg = r; dbg_d = v; dbg_wr = 1'b1;
        repeat (12) @(negedge clk_bus);
        dbg_wr = 1'b0;
        repeat (6) @(negedge clk_bus);
    end endtask

    task rd(input [1:0] r, input [7:0] v);     // a read of FDC register r (not #FF)
    begin
        @(negedge clk_bus); dbg_ff = 1'b0; dbg_reg = r; dbg_q = v; dbg_rd = 1'b1;
        repeat (12) @(negedge clk_bus);
        dbg_rd = 1'b0;
        repeat (6) @(negedge clk_bus);
    end endtask

    task expect_r(input integer base, input [7:0] b0, input [7:0] b1, input [7:0] b2);
    begin
        if (got[base] !== b0 || got[base + 1] !== b1 || got[base + 2] !== b2) begin
            $display("FAIL record at byte %0d: got %h %h %h want %h %h %h",
                     base, got[base], got[base + 1], got[base + 2], b0, b1, b2);
            errors = errors + 1;
        end
    end endtask

    integer k;
    initial begin
        repeat (20) @(posedge clk_bus);
        wr(1'b1, 2'd0, 8'h3C);            // before enable: not logged
        repeat (20) @(posedge clk_bus);
        enable = 1'b1;
        repeat (20) @(posedge clk_bus);
        wr(1'b0, 2'd1, 8'hFF);            // 0: track
        wr(1'b0, 2'd2, 8'h85);            // 1: sector
        wr(1'b0, 2'd0, 8'h80);            // 2: command
        rd(2'd0, 8'h81);                  // 3: status (every read is logged)
        rd(2'd0, 8'h81);                  // 4
        wr(1'b1, 2'd0, 8'h1C);            // 5: #FF
        for (k = 1; k <= 5; k = k + 1) rd(2'd3, 8'h10 * k + 8'd1);   // a burst of 5 data reads
        rd(2'd0, 8'h00);                  // 6.. the burst summary (4 records) then this status
        for (k = 0; k < 20; k = k + 1) wr(1'b1, 2'd0, 8'h37 + (k & 1) * 8);   // a flood: 8 logged
        wr(1'b0, 2'd0, 8'h08);            // another access restarts the allowance
        wr(1'b1, 2'd0, 8'h18);
        repeat (20000) @(posedge clk_sys);
        // 3 writes, 1 status (the repeat is not logged), #FF, 4 burst records, a status,
        // 8 of the flood, 2 more = 20 records of three bytes
        if (ngot !== 60) begin $display("FAIL %0d bytes, want 60", ngot); errors = errors + 1; end
        expect_r(0,  8'h81, 8'h00, 8'hFF);
        expect_r(3,  8'h82, 8'h00, 8'h85);
        expect_r(6,  8'h80, 8'h00, 8'h80);
        expect_r(9,  8'h88, 8'h00, 8'h81);          // the second identical status read: not logged
        expect_r(12, 8'h84, 8'h00, 8'h1C);
        expect_r(15, 8'h90, 8'h00, 8'h05);          // five data reads
        expect_r(18, 8'h91, 8'h11, 8'h21);          // first two bytes
        expect_r(21, 8'h92, 8'h31, 8'h41);          // third and fourth
        expect_r(24, 8'h93, 8'h51, 8'h00);          // the last
        expect_r(27, 8'h88, 8'h00, 8'h00);          // the status that ended it
        expect_r(30, 8'h84, 8'h00, 8'h37);          // first of the flood
        expect_r(30 + 7 * 3, 8'h84, 8'h00, 8'h3F);  // the eighth
        expect_r(30 + 8 * 3, 8'h80, 8'h00, 8'h08);  // the 9th..20th were not logged
        expect_r(30 + 9 * 3, 8'h84, 8'h00, 8'h18);
        // a burst longer than the buffer must not wedge anything: the newest are dropped
        ngot = 0;
        repeat (80) wr(1'b0, 2'd3, 8'h55);
        repeat (60000) @(posedge clk_sys);
        if (ngot < 3 * 60 || ngot >= 3 * 80) begin
            $display("FAIL the burst gave %0d bytes (a full buffer drops the newest)", ngot);
            errors = errors + 1;
        end
        if (errors == 0) $display("tb_fdc_trace: PASS");
        else $display("tb_fdc_trace: FAIL %0d errors", errors);
        $finish;
    end
endmodule
