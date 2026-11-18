// tb_td0_lzh.sv - rtl/disk/td0_lzh.sv against tools/td0.py: a prefix of a real
// Teledisk file (the compressed bytes after the 12-byte header) goes in, and
// every decoded byte must be the model's. The prefix is long enough for the
// tree to be rebuilt once (32768 symbols). The source and the consumer use
// the module's own pull handshakes, the consumer with a gap now and then so
// the decoder is held on a request that is not there yet.
`timescale 1ns/1ps
module tb_td0_lzh;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1, init = 1'b0;
    wire need;
    reg in_vld = 1'b0;
    reg [7:0] in_data = 8'd0;
    reg out_req = 1'b0;
    wire out_vld;
    wire [7:0] out_data;

    td0_lzh dut (.clk(clk), .rst(rst), .init(init), .need(need), .in_vld(in_vld),
                 .in_data(in_data), .out_req(out_req), .out_vld(out_vld),
                 .out_data(out_data));

    localparam integer NC = `NC;
    localparam integer NE = `NE;
    reg [7:0] cmp [0:NC-1];
    reg [7:0] exp [0:NE-1];
    integer ci = 0, ei = 0, errors = 0, gap = 0;
    initial begin
        $readmemh("build/sim/td0/lzh.in", cmp);
        $readmemh("build/sim/td0/lzh.out", exp);
    end

    // the source
    always @(posedge clk) begin
        in_vld <= 1'b0;
        if (need && !in_vld && ci < NC) begin
            in_vld  <= 1'b1;
            in_data <= cmp[ci];
            ci      <= ci + 1;
        end
    end

    // the consumer
    always @(posedge clk) begin
        if (out_vld) begin
            out_req <= 1'b0;
            if (out_data !== exp[ei]) begin
                if (errors < 5)
                    $display("FAIL byte %0d: got %02x want %02x", ei, out_data, exp[ei]);
                errors = errors + 1;
            end
            ei <= ei + 1;
            gap <= (ei % 97 == 0) ? 40 : 0;
        end
        else if (gap > 0) gap <= gap - 1;
        else if (!out_req && ei < NE) out_req <= 1'b1;
    end

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);
        init <= 1'b1;
        @(posedge clk);
        init <= 1'b0;
        wait (ei >= NE);
        repeat (4) @(posedge clk);
        if (errors == 0) $display("tb_td0_lzh: PASS %0d bytes", NE);
        else             $display("tb_td0_lzh: FAIL %0d wrong of %0d", errors, NE);
        $finish;
    end
    initial begin
        #4_000_000_000;
        $display("tb_td0_lzh: FAIL timeout at byte %0d, input %0d of %0d", ei, ci, NC);
        $finish;
    end
endmodule
