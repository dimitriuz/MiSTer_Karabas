// tb_conv.sv - tape_src's TAP/TZX to CSW converter, byte for byte.
//
// The converter turns a mounted TAP/TZX into the CSW stream that tape.sv's
// CSW player already loads on the board. The reference is that same file in
// CSW form (zxtap.py writes it), so the check is exact: mount hello.tap, read
// the converter's bytes through the player's rd/rd_en handshake and compare
// with hello.csw; then the same for hello.tzx. No pulse playback here, so the
// run is seconds; tb_tape_play is the integration check.
`timescale 1ns / 1ps
`default_nettype none

module tb_conv;
    reg clk_sys = 1'b0;
    always #10 clk_sys = ~clk_sys;
    reg clk = 1'b0;
    always #17.7778 clk = ~clk;

    reg         img_mounted = 1'b0;
    reg  [63:0] img_size = 64'd0;
    wire [31:0] sd_lba;
    wire        sd_rd;
    wire        sd_ack;
    wire  [8:0] sd_buff_addr;
    wire  [7:0] sd_buff_dout;
    wire        sd_buff_wr;

    wire        tape_ready;
    wire  [1:0] tape_mode;
    wire [24:0] tape_size;
    wire        tape_rd;
    wire [24:0] tape_addr;
    wire  [7:0] tape_din;
    wire        tape_rd_en;

    tape_src u_src (
        .clk_sys(clk_sys), .img_mounted(img_mounted), .img_size(img_size),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
        .sd_buff_wr(sd_buff_wr),
        .clk(clk), .tape_ready(tape_ready), .tape_mode(tape_mode),
        .tape_size(tape_size), .rd(tape_rd), .addr(tape_addr),
        .din(tape_din), .rd_en(tape_rd_en),
        .seek_prev(1'b0), .seek_next(1'b0), .blk_seek(), .stock_tzx(1'b0)
    );

    sd_img_model #(.LAT_CLKS(1000)) sd_model (
        .clk(clk_sys), .lba(sd_lba), .rd(sd_rd), .ack(sd_ack),
        .buff_addr(sd_buff_addr), .buff_dout(sd_buff_dout),
        .buff_wr(sd_buff_wr), .size(img_size[31:0]), .past_end()
    );

    // tape.sv's read handshake, verbatim in structure: rd_req is raised when
    // the consumer has no byte, the byte is taken on the edge after rd_en
    // falls, and read_done is cleared as soon as the byte is consumed here.
    assign tape_addr = 25'd0;
    reg rd_req = 1'b0;
    reg read_done = 1'b0;
    reg old_rden = 1'b0;
    assign tape_rd = rd_req;

    reg  [7:0] got [0:32767];
    integer    n = 0;
    integer    csw_len = 0;

    always @(posedge clk) begin
        old_rden <= tape_rd_en;
        if (read_done) read_done <= 1'b0;   // consumed at once
        if (!tape_rd_en) begin
            if (rd_req) begin
                if (old_rden) begin
                    if (!read_done) begin
                        if (n < 32768) got[n] = tape_din;
                        n = n + 1;
                        read_done <= 1'b1;
                    end
                    rd_req <= 1'b0;
                end
            end else if (!read_done) begin
                rd_req <= 1'b1;
            end
        end
    end

    integer errors = 0;
    integer shown = 0;

    task fail_int(input [8*24-1:0] what, input [31:0] got_v, input [31:0] want);
        begin
            $display("%0s: got %0d want %0d", what, got_v, want);
            errors = errors + 1;
        end
    endtask

    reg [8*64-1:0] fname;

    task compare(input [8*24-1:0] name);
        integer i, bad, f;
        begin
            $sformat(fname, "build/sim/%0s.hex", name);
            f = $fopen(fname, "w");
            for (i = 0; i < n; i = i + 1) $fwrite(f, "%02x\n", got[i]);
            $fclose(f);
            bad = -1;
            for (i = 0; i < csw_len && i < n; i = i + 1)
                if (bad < 0 && got[i] !== csw[i]) bad = i;
            if (n != csw_len) begin
                $display("%0s: %0d bytes, want %0d", name, n, csw_len);
                errors = errors + 1;
            end
            if (bad >= 0) begin
                $display("%0s: first mismatch at %0d: %02x want %02x",
                         name, bad, got[bad], csw[bad]);
                errors = errors + 1;
            end else if (n == csw_len) begin
                $display("%0s: %0d bytes identical", name, n);
            end
        end
    endtask

    task mount(input [31:0] sz, input [8*64-1:0] hexf);
        begin
            $readmemh(hexf, sd_model.mem, 0, sz - 1);
            img_size = sz;
            @(posedge clk_sys);
            img_mounted = 1'b1;
            @(posedge clk_sys);
            img_mounted = 1'b0;
        end
    endtask

    task run_case(input [31:0] sz, input [8*64-1:0] hexf, input [8*24-1:0] name);
        integer guard;
        begin
            mount(sz, hexf);
            @(posedge clk); #1;
            while (tape_ready) @(posedge clk);     // the mount drops it first
            while (!tape_ready) @(posedge clk);
            n = 0;
            guard = 0;
            // the converter emits exactly the CSW file; a bounded wait on the
            // byte count is the timeout (17k bytes at one per few clocks)
            while (n < csw_len && guard < 4000000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            repeat (2000) @(posedge clk);          // no byte after the end
            compare(name);
        end
    endtask

    reg [7:0] csw [0:32767];
    integer i;

    initial begin
        for (i = 0; i < 32768; i = i + 1) csw[i] = 8'hxx;
        $readmemh("build/sim/hello.csw.hex", csw, 0, 17036);
        csw_len = 17037;
        run_case(32'd58, "build/sim/hello.tap.hex", "tap_conv");
        run_case(32'd74, "build/sim/hello.tzx.hex", "tzx_conv");
        if (errors == 0) $display("tb_conv: PASS");
        else $display("tb_conv: FAIL %0d errors", errors);
        $finish;
    end

endmodule

`default_nettype wire