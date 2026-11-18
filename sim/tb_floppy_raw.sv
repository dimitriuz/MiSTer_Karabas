// tb_floppy_raw.sv - the drive model with a raw track (stage UDI): the
// revolution is the length the store announced with its ack, and a marked C2
// is the index-mark sync 5224 where a marked A1 stays 4489. A stub store
// answers every request: ready, trk_len = LEN (+define), a track buffer of
// {sync, byte} with a marked C2 at 10 and a marked A1 at 20. The model's
// /INDEX period must be LEN*16 cell ticks; the channel stream (read from the
// DUT's own channel word at every tick) must hold both sync words once.
//   iverilog -g2012 -DLEN=6400 ... ; the script runs 6400, 6250 and 6016.
// Exactly one 5224 (the marked C2) and at least one 4489 (the marked A1) must appear.
`timescale 1ns/1ps
`ifndef LEN
`define LEN 6400
`endif
module tb_floppy_raw;
    localparam integer LEN = `LEN;
    reg clk = 1'b0;
    always #17.7778 clk = ~clk;
    reg reset = 1'b1;

    reg  [8:0]  mem [0:8191];
    wire [12:0] addr_b, addr_a;
    reg  [8:0]  q_b = 9'd0;
    always @(posedge clk) q_b <= mem[addr_b];

    wire        req_tgl;
    wire [8:0]  req;
    reg         ack_tgl = 1'b0;
    reg  [9:0]  ack = 10'd0;
    reg  [12:0] ack_len = 13'd6250;
    wire        rdata, index, tr00, wprt;
    wire        wr_tgl;
    wire [35:0] wr_info;
    wire [9:0]  wr_addr;
    wire [7:0]  wr_data;
    wire        wr_we;

    floppy dut (
        .clk(clk), .reset(reset), .ds80(1'b0), .swap(1'b0),
        .cell_num(16'd4), .cell_den(16'd225),
        .fdc_drive(2'b01), .fdc_motor(1'b1), .fdc_step(1'b0), .fdc_dir(1'b0),
        .fdc_side_n(1'b0), .fdc_wgate(1'b0), .fdc_wdata(1'b0),
        .fdc_rdata(rdata), .fdc_index(index), .fdc_tr00(tr00), .fdc_wprt(wprt),
        .wprt(2'b00),
        .trk_req_tgl(req_tgl), .trk_req(req), .trk_ack_tgl(ack_tgl),
        .trk_ack(ack), .trk_len(ack_len),
        .trk_addr_a(addr_a), .trk_addr_b(addr_b), .trk_q_a(9'd0), .trk_q_b(q_b),
        .wr_tgl(wr_tgl), .wr_info(wr_info), .wr_ack_tgl(1'b0),
        .wr_addr(wr_addr), .wr_data(wr_data), .wr_we(wr_we));

    // the stub store: any request is answered ready, with the length
    reg req_seen = 1'b0;
    integer k;
    initial begin
        for (k = 0; k < 8192; k = k + 1) mem[k] = {1'b0, 8'h4E};   // filler: no sync pattern of its own
        mem[10] = {1'b1, 8'hC2};
        mem[20] = {1'b1, 8'hA1};
    end
    always @(posedge clk) begin
        if (req_tgl !== req_seen) begin
            req_seen <= req_tgl;
            repeat (20) @(posedge clk);
            ack     <= {1'b1, req};
            ack_len <= `LEN;
            @(posedge clk);
            ack_tgl <= ~ack_tgl;
        end
    end

    // /INDEX rising edges, in clk_bus cycles
    integer cyc = 0, last = -1, period = 0, edges = 0;
    reg idx_d = 1'b0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        idx_d <= index;
        if (index && !idx_d) begin
            edges = edges + 1;
            if (last >= 0) period = cyc - last;
            last = cyc;
        end
    end

    // the channel stream, one bit per cell tick, as the DUT's own word
    reg [15:0] win = 16'd0;
    integer n5224 = 0, n4489 = 0, rev_seen = 0;
    always @(posedge clk) begin
        if (dut.tick && dut.stream_on) begin
            win <= {win[14:0], dut.chan_n[15]};
        end
    end
    always @(posedge clk) if (dut.tick && edges >= 3 && edges <= 3) begin
        // count sync words on the third revolution only (the buffer is live)
        if (win == 16'h5224) n5224 = n5224 + 1;
        if (win == 16'h4489 && 1) n4489 = n4489 + 1;
    end

    integer want;
    initial begin
        repeat (8) @(posedge clk);
        reset = 1'b0;
        // five revolutions at most: first at the 6250 filler, then the track
        wait (edges >= 5);
        // the period of a revolution is LEN*16 ticks of 225/4 clocks
        want = (LEN * 16 * 225) / 4;
        if (period < want - 40 || period > want + 40) begin
            $display("tb_floppy_raw: FAIL period %0d clk, want %0d (LEN %0d)", period, want, LEN);
            $finish;
        end
        if (n5224 != 1 || n4489 < 1) begin
            $display("tb_floppy_raw: FAIL syncs: 5224 x%0d, 4489 x%0d", n5224, n4489);
            $finish;
        end
        $display("tb_floppy_raw: PASS LEN=%0d period=%0d syncs 5224=%0d 4489=%0d", LEN, period, n5224, n4489);
        $finish;
    end
    initial begin
        #2_500_000_000;
        $display("tb_floppy_raw: FAIL timeout (edges %0d)", edges);
        $finish;
    end
endmodule
