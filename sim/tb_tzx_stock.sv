// Logs every audio_out interval (in ce ticks, ce every clock) of the Karabas
// tape chain with the diagnostic stock TZX engine selected (tape_src
// stock_tzx = 1): tape_src serves the raw file to tape.sv's own TZX engine,
// tzxplayer.vhd, with the OSD knobs pilot_sel / pause_keep. The edges go to
// the file named by +OUT; sim/run_tb_tzx_stock.sh judges them.
//   +FILE=<hex> +SIZE=<bytes> +SEL=<0..3> +KEEP=<0|1> +MAXE=<edges> +OUT=<file> +STOCK=<0|1> +TLIM=<ns>
`timescale 1ns / 1ps
`default_nettype none
module tb_tzx_stock;
    reg clk_sys = 0; always #10 clk_sys = ~clk_sys;
    reg clk = 0;     always #17.7778 clk = ~clk;
    wire ce = 1'b1;
    reg img_mounted = 0; reg [63:0] img_size = 0;
    wire [31:0] sd_lba; wire sd_rd, sd_ack; wire [8:0] sd_buff_addr;
    wire [7:0] sd_buff_dout; wire sd_buff_wr;
    wire tape_ready; wire [1:0] tape_mode; wire [24:0] tape_size, tape_addr;
    wire tape_rd, tape_rd_en, blk_seek; wire [7:0] tape_din;
    reg pause = 0, stock = 1; reg [1:0] sel = 0; reg keep = 0;
    wire audio_out;

    tape_src u_tape_src (.clk_sys(clk_sys), .img_mounted(img_mounted), .img_size(img_size),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack), .sd_buff_addr(sd_buff_addr),
        .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr), .clk(clk),
        .tape_ready(tape_ready), .tape_mode(tape_mode), .tape_size(tape_size),
        .rd(tape_rd), .addr(tape_addr), .din(tape_din), .rd_en(tape_rd_en),
        .seek_prev(1'b0), .seek_next(1'b0), .blk_seek(blk_seek), .stock_tzx(stock));
    sd_img_model #(.LAT_CLKS(1000)) sd_model (.clk(clk_sys), .lba(sd_lba), .rd(sd_rd),
        .ack(sd_ack), .buff_addr(sd_buff_addr), .buff_dout(sd_buff_dout),
        .buff_wr(sd_buff_wr), .size(img_size[31:0]), .past_end());
    tape u_tape (.clk_sys(clk), .ce(ce), .mode48k(1'b0), .turbo(1'b0), .byte_wait(1'b0),
        .byte_ready(), .dout(), .pause(pause), .prev(1'b0), .next(1'b0), .active(),
        .available(), .tape_ready(tape_ready), .tape_mode(tape_mode), .tape_size(tape_size),
        .stdload(1'b0), .req_hdr(1'b0), .blk_seek(1'b0),
        .tzx_pilot_sel(sel), .tzx_pause_keep(keep),
        .audio_out(audio_out), .rd_en(tape_rd_en), .rd(tape_rd), .addr(tape_addr),
        .din(tape_din));

    integer tick = 0, nedge = 0, maxe, fd, sz, v;
    integer tlim = 60000000;   // ns, +TLIM
    reg audio_d = 1; reg [8*128-1:0] fname, oname;
    always @(posedge clk) if (ce) begin
        tick = tick + 1;
        if ((audio_out === 1'b0 || audio_out === 1'b1) &&
            (audio_d === 1'b0 || audio_d === 1'b1) && (audio_out !== audio_d)) begin
            $fdisplay(fd, "%0d %0d", audio_out, tick - 1);
            nedge = nedge + 1; tick = 0;
            if (nedge >= maxe) begin
                $fclose(fd); $display("mode %0d done %0d edges", tape_mode, nedge); $finish;
            end
        end
        audio_d = audio_out;
    end
    initial begin
        u_tape.tzx_ack = 1'b0;   // no reset value in tape.sv; the hardware powers up 0
        if (!$value$plusargs("FILE=%s", fname)) $finish;
        if (!$value$plusargs("OUT=%s", oname)) $finish;
        if (!$value$plusargs("SIZE=%d", sz)) $finish;
        if (!$value$plusargs("MAXE=%d", maxe)) maxe = 100000;
        if ($value$plusargs("SEL=%d", v)) sel = v;
        if ($value$plusargs("KEEP=%d", v)) keep = v;
        if ($value$plusargs("STOCK=%d", v)) stock = v;
        if ($value$plusargs("TLIM=%d", v)) tlim = v;
        fd = $fopen(oname, "w");
        $readmemh(fname, sd_model.mem, 0, sz - 1);
        img_size = sz; @(posedge clk_sys); img_mounted = 1; @(posedge clk_sys); img_mounted = 0;
        @(posedge clk); #1; while (tape_ready) begin @(posedge clk); #1; end
        while (!tape_ready) begin @(posedge clk); #1; end
        repeat (4) @(posedge clk);
        pause = 1; repeat (16) @(posedge clk); pause = 0;
        #(tlim);
        $display("mode %0d time limit after %0d edges", tape_mode, nedge);
        $fclose(fd); $finish;
    end
endmodule
