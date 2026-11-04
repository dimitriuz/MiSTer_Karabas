// tb_video_cdc.sv - the pixel CDC of the top: pushes a counter pattern over
// the bus clock at two machine modes (28.125 MHz with the enable 1-in-4,
// 24.107142 MHz with 1-in-2) into the 112.5 MHz video clock and checks
// every word arrives exactly once, in order, and that dout only ever
// changes in a cycle with ce_out = 1 (stable from one strobe to the next).
// A burst queues three words against a stalled read side first.
`timescale 1ns/1ps
`default_nettype none

module tb_video_cdc;

    localparam integer W = 12;

    reg clk_bus = 1'b0;
    reg clk_vid = 1'b0;
    real half_bus = 17.7778;          // 28.125 MHz half period, ns
    real half_vid =  4.4444;          // 112.5 MHz
    always #(half_bus) clk_bus = ~clk_bus;
    always #(half_vid) clk_vid = ~clk_vid;

    reg          reset = 1'b1;
    reg          stall = 1'b0;
    reg          ce_in = 1'b0;
    reg  [W-1:0] din = '0;

    wire         ce_out;
    wire [W-1:0] dout;

    video_cdc #(.W(W)) dut (
        .clk_bus(clk_bus), .clk_vid(clk_vid), .reset(reset),
        .ce_in(ce_in), .din(din), .stall(stall),
        .ce_out(ce_out), .dout(dout)
    );

    integer errors = 0;
    task fail(input [8*44:1] why);
        begin
            errors = errors + 1;
            $display("tb_video_cdc: FAIL %0s (at %0t)", why, $time);
        end
    endtask

    // ---------------- push side: the two cadences ------------------------
    integer ce_div  = 4;              // enable 1-in-ce_div bus clocks
    integer ce_cnt  = 0;
    integer pushes  = 0;              // words really pushed (monitor)
    reg     push_en = 1'b0;           // cadence generator on/off
    integer burst_n = 0;              // consecutive pushes to force
    always @(posedge clk_bus) begin
        if (reset) begin
            ce_in  <= 1'b0;
            ce_cnt <= 0;
        end else if (burst_n > 0) begin
            burst_n <= burst_n - 1;   // burst beats over the cadence
            ce_cnt  <= 0;
            ce_in   <= 1'b1;
        end else if (push_en) begin
            if (ce_cnt == ce_div - 1) begin
                ce_cnt <= 0;
                ce_in  <= 1'b1;
            end else begin
                ce_cnt <= ce_cnt + 1;
                ce_in  <= 1'b0;
            end
        end else ce_in <= 1'b0;
    end

    // the testbook and the data counter move on what the DUT actually
    // sees (din still holds the value being pushed in that cycle).
    always @(posedge clk_bus)
        if (!reset && ce_in) begin
            pushes = pushes + 1;
            din    <= din + 1'b1;
        end


    // ---------------- receive side ----------------------------------------
    localparam integer RXMAX = 4096;
    reg [W-1:0] rx [0:RXMAX-1];
    integer     rxn = 0;
    reg  [W-1:0] dout_q = '0;
    reg          ce_out_q = 1'b0;

    always @(posedge clk_vid) begin
        // the word is stable from one strobe to the next: dout changes only
        // in cycles that showed ce_out.
        if (!reset && (dout !== dout_q) && !(ce_out || ce_out_q))
            fail("dout changed while ce_out low");
        if (ce_out && !reset) begin
            if (rxn >= RXMAX) fail("receiver overflow");
            else begin
                rx[rxn] = dout;
                rxn     = rxn + 1;
            end
        end
        dout_q   <= dout;
        ce_out_q <= ce_out;
    end

    task drain;                        // everything pushed must have left
        integer prev;                  // and nothing may be pushed during
        begin                          // the quiet window either
            prev = -1;
            while (!(pushes == prev && rxn >= pushes)) begin
                prev = pushes;
                @(negedge clk_bus);
            end
            repeat (60) @(posedge clk_vid);
            if (rxn > pushes) begin
                $display("drain: rxn=%0d pushes=%0d", rxn, pushes);
                fail("more words received than pushed");
            end
        end
    endtask

    integer i, tx0, burst_tx, burst_rx;
    reg [W-1:0] exp;
    initial begin
        repeat (20) @(posedge clk_bus);           // reset: >= 3 slow clocks
        reset = 1'b0;
        repeat (5) @(posedge clk_bus);

        // ---- phase A: 28.125 MHz, enable 1-in-4 --------------------------
        push_en = 1'b1;
        ce_div  = 4;
        tx0 = pushes;
        while (pushes < tx0 + 200) @(posedge clk_bus);
        push_en = 1'b0;
        drain;

        // ---- burst: three words against a stalled read side --------------
        stall = 1'b1;
        repeat (30) @(posedge clk_vid);           // quiesce
        burst_rx = rxn;
        repeat (40) @(posedge clk_bus);
        if (rxn != burst_rx) fail("words popped while stalled");
        burst_tx = pushes;
        repeat (2) @(posedge clk_bus);
        burst_n = 3;                           // three consecutive pushes
        repeat (6) @(posedge clk_bus);
        burst_n = 0;
        if (pushes != burst_tx + 3)
            fail("burst did not push three words");
        repeat (30) @(posedge clk_vid);
        if (rxn != burst_rx) fail("burst words escaped the stalled FIFO");
        stall = 1'b0;
        drain;
        for (i = 0; i < 3; i = i + 1) begin
            exp = W'(burst_tx + i);
            if (rx[burst_rx + i] !== exp) fail("burst word wrong or late");
        end

        // ---- phase B: 24.107142 MHz, enable 1-in-2 ------------------------
        half_bus = 41.4815;
        ce_div   = 2;
        push_en  = 1'b1;
        tx0 = pushes;
        while (pushes < tx0 + 200) @(posedge clk_bus);
        push_en = 1'b0;
        drain;

        if (rxn != pushes) begin
            $display("tb_video_cdc: FAIL received %0d, pushed %0d", rxn,
                     pushes);
            errors = errors + 1;
        end
        for (i = 0; i < rxn; i = i + 1) begin
            exp = W'(i);
            if (rx[i] !== exp) begin
                $display("tb_video_cdc: FAIL rx[%0d] = %0d expected %0d",
                         i, rx[i], i);
                errors = errors + 1;
                if (i > 8) i = rxn;               // one dump is enough
            end
        end
        if (errors == 0) $display("tb_video_cdc: PASS");
        else             $display("tb_video_cdc: FAIL %0d errors", errors);
        $finish;
    end

    initial begin : watchdog
        #6_000_000;                                // 6 ms of simulation
        $display("tb_video_cdc: FAIL watchdog (run stalled)");
        $finish;
    end

endmodule

`default_nettype wire
