// tb_fdd_ams.sv - the whole floppy chain against a real protected disk.
//
// A real FDI is downloaded through rtl/disk/fdd_src.sv into rtl/disk/fdd_store.sv
// (DDR model behind rtl/mem/ddr_arb.sv), the drive model rtl/disk/floppy.sv reads its
// tracks, and the upstream VG93 (hrdy_fdc + fdd_glue + vg93_*) is driven from the CPU
// side with the exact sequence of port writes and commands that PicoSpeccy's WD1793
// logged while it booted the disk (sim/data/ams_loader.trace; tools/ams_cmds.py turns
// it into the fixtures). Every RDSEC is read the way the disk's own loader does it:
// poll #FF, take a byte on DRQ (bit 6), stop on INTRQ (bit 7), read the status at once.
// The bytes must be the file's own, the status 00.
//
// Parameters as in tb_floppy: DS80, TURBO (CPU at 3.5 MHz when 0), CELL_NUM/CELL_DEN.
// Last line: `tb_fdd_ams: PASS` or `tb_fdd_ams: FAIL <reason>`.
`timescale 1ns / 1ps

module tb_fdd_ams;

parameter DS80  = 0;
parameter TURBO = 0;
parameter [15:0] CELL_NUM = 16'd4;
parameter [15:0] CELL_DEN = 16'd225;
parameter integer CMD_MS  = 1500;     // what one command may take

// ---------------- clocks ----------------
real BHALF = DS80 ? 20.741 : 17.778;
reg bclk = 1'b0;                      // clk_bus: the CPU, the VG93, the drive
always #(BHALF) bclk = ~bclk;
reg gclk = 1'b0;                      // gs_clk: the store (a different clock on purpose)
always #17.3 gclk = ~gclk;
reg sclk = 1'b0;                      // clk_sys: fdd_src
always #10 sclk = ~sclk;

integer nsteps = 0, nidx = 0;
reg stp_d = 1'b0, idx_d = 1'b0;
always @(posedge bclk) begin stp_d <= FDC_STEP; idx_d <= FDC_INDEX; if (FDC_STEP && !stp_d) nsteps = nsteps + 1; if (FDC_INDEX && !idx_d) nidx = nidx + 1; end
integer edges_per_ms = DS80 ? 24107 : 28125;
integer edges = 0;
always @(posedge bclk) edges = edges + 1;

reg reset = 1'b1;
integer errors = 0;

// ---------------- DDR side ----------------
wire        f_req, f_rd, f_we, f_busy, f_dout_ready;
wire [28:0] f_addr;
wire [63:0] f_din, f_dout;
wire  [7:0] f_be;
wire        ddr_rd, ddr_we, ddr_busy, ddr_dout_ready;
wire [28:0] ddr_addr;
wire [63:0] ddr_din, ddr_dout;
wire  [7:0] ddr_be, ddr_burstcnt;

ddr_arb arb (
    .clk(gclk), .reset(reset),
    .g_req(1'b0), .g_addr(29'd0), .g_din(64'd0), .g_be(8'd0), .g_rd(1'b0), .g_we(1'b0),
    .g_busy(), .g_dout(), .g_dout_ready(),
    .f_req(f_req), .f_addr(f_addr), .f_din(f_din), .f_be(f_be), .f_rd(f_rd), .f_we(f_we),
    .f_busy(f_busy), .f_dout(f_dout), .f_dout_ready(f_dout_ready),
    .ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_addr(ddr_addr), .ddr_din(ddr_din),
    .ddr_be(ddr_be), .ddr_burstcnt(ddr_burstcnt),
    .ddr_busy(ddr_busy), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready)
);

ddram_model #(.LAT(4), .BUSY_PCT(20), .FAIL_TAG("tb_fdd_ams")) model (
    .clk(gclk), .force_busy(1'b0), .burstcnt(ddr_burstcnt), .addr(ddr_addr),
    .rd(ddr_rd), .din(ddr_din), .be(ddr_be), .we(ddr_we),
    .dout(ddr_dout), .dout_ready(ddr_dout_ready), .busy(ddr_busy)
);

// ---------------- store, source, drive ----------------
wire        fill_tgl, fill_ack_tgl, drn_tgl, drn_ack_tgl;
wire [31:0] fill_word;
wire  [8:0] drn_addr_b;
wire  [7:0] drn_q_b;
wire [11:0] drn_info;

wire        trk_req_tgl, trk_ack_tgl, wr_tgl, wr_ack_tgl, wr_we;
wire  [8:0] trk_req, trk_q_b;
wire  [9:0] trk_ack;
wire [12:0] trk_len, trk_addr_a, trk_addr_b;
wire [35:0] wr_info;
wire  [9:0] wr_addr;
wire  [7:0] wr_data;
wire  [8:0] trk_q_a = 9'd0;

fdd_store store (
    .clk(gclk), .reset(reset), .clk_bus(bclk), .clk_sys(sclk),
    .f_req(f_req), .f_addr(f_addr), .f_din(f_din), .f_be(f_be), .f_rd(f_rd), .f_we(f_we),
    .f_busy(f_busy), .f_dout(f_dout), .f_dout_ready(f_dout_ready),
    .fill_tgl(fill_tgl), .fill_word(fill_word), .fill_ack_tgl(fill_ack_tgl),
    .trk_req_tgl(trk_req_tgl), .trk_req(trk_req),
    .trk_ack_tgl(trk_ack_tgl), .trk_ack(trk_ack), .trk_len(trk_len),
    .trk_addr_b(trk_addr_b), .trk_q_b(trk_q_b),
    .wr_addr(wr_addr), .wr_data(wr_data), .wr_we(wr_we),
    .wr_info(wr_info), .wr_tgl(wr_tgl), .wr_ack_tgl(wr_ack_tgl),
    .drn_addr_b(drn_addr_b), .drn_q_b(drn_q_b), .drn_tgl(drn_tgl), .drn_info(drn_info),
    .drn_ack_tgl(drn_ack_tgl)
);

reg         io_download = 1'b0;
reg  [15:0] io_index    = 16'd0;
reg         io_wr       = 1'b0;
reg   [7:0] io_dout     = 8'd0;
wire        io_wait;
wire  [1:0] src_wprt;

fdd_src src (
    .clk_sys(sclk), .reset_sys(reset),
    .img_mounted(2'b00), .img_size(64'd0), .img_readonly(1'b0),
    .sd_rd(), .sd_wr(), .sd_lba(), .sd_ack(2'b00),
    .sd_buff_addr(), .sd_buff_dout(), .sd_buff_din(), .sd_buff_wr(),
    .status(128'd0),
    .ioctl_download(io_download), .ioctl_index(io_index),
    .ioctl_wr(io_wr), .ioctl_addr(27'd0), .ioctl_dout(io_dout), .ioctl_wait(io_wait),
    .wprt(src_wprt),
    .fill_tgl(fill_tgl), .fill_word(fill_word), .fill_ack_tgl(fill_ack_tgl),
    .drn_addr_b(drn_addr_b), .drn_q_b(drn_q_b), .drn_tgl(drn_tgl), .drn_info(drn_info),
    .drn_ack_tgl(drn_ack_tgl)
);

wire [1:0] FDC_DS;
wire FDC_SIDE1, FDC_WG, FDC_WR_DATA, FDC_STEP, FDC_DIR, FDC_MOTOR;
wire FDC_RDATA, FDC_INDEX, FDC_TR00, FDC_WPRT;

floppy drive (
    .clk(bclk), .reset(reset), .ds80(DS80 != 0), .swap(1'b0),
    .cell_num(CELL_NUM), .cell_den(CELL_DEN),
    .fdc_drive(FDC_DS), .fdc_motor(FDC_MOTOR), .fdc_step(FDC_STEP), .fdc_dir(FDC_DIR),
    .fdc_side_n(FDC_SIDE1), .fdc_wgate(FDC_WG), .fdc_wdata(FDC_WR_DATA),
    .fdc_rdata(FDC_RDATA), .fdc_index(FDC_INDEX), .fdc_tr00(FDC_TR00), .fdc_wprt(FDC_WPRT),
    .wprt(src_wprt),
    .trk_req_tgl(trk_req_tgl), .trk_req(trk_req),
    .trk_ack_tgl(trk_ack_tgl), .trk_ack(trk_ack), .trk_len(trk_len),
    .trk_addr_a(trk_addr_a), .trk_addr_b(trk_addr_b),
    .trk_q_a(trk_q_a), .trk_q_b(trk_q_b),
    .wr_tgl(wr_tgl), .wr_info(wr_info), .wr_ack_tgl(wr_ack_tgl),
    .wr_addr(wr_addr), .wr_data(wr_data), .wr_we(wr_we)
);

// ---------------- the CPU side and the VG93 ----------------
reg [15:0] a = 16'hFFFF;
reg [7:0]  d = 8'hFF;
reg wr_n = 1'b1, rd_n = 1'b1, iorq_n = 1'b1, cs_n = 1'b1, csff_n = 1'b1;
wire oe_n, busy;
wire [7:0] dout;
reg [2:0] ecnt = 3'd0;
always @(posedge bclk) ecnt <= ecnt + 3'd1;
wire ena_cpu = TURBO ? 1'b1 : (ecnt == 3'd7);

hrdy_fdc fdc (
    .clk(bclk), .ds80(DS80 != 0), .reset(reset), .ena_cpu(ena_cpu),
    .a(a), .d(d), .wr_n(wr_n), .rd_n(rd_n), .iorq_n(iorq_n),
    .cs_n(cs_n), .csff_n(csff_n), .oe_n(oe_n), .dout(dout), .busy(busy),
    .FDC_SIDE1(FDC_SIDE1), .FDC_RDATA(FDC_RDATA), .FDC_WPRT(FDC_WPRT), .FDC_TR00(FDC_TR00),
    .FDC_INDEX(FDC_INDEX), .FDC_WG(FDC_WG), .FDC_WR_DATA(FDC_WR_DATA), .FDC_STEP(FDC_STEP),
    .FDC_DIR(FDC_DIR), .FDC_MOTOR(FDC_MOTOR), .FDC_DS(FDC_DS)
);

task io_wr_t(input ff, input [1:0] r, input [7:0] v);
begin
    @(posedge bclk);
    a = {9'h000, r, 5'b11111}; d = v;
    iorq_n = 1'b0; cs_n = ff; csff_n = !ff;
    @(posedge bclk); wr_n = 1'b0;
    repeat (10) @(posedge bclk);
    while (busy) @(posedge bclk);
    wr_n = 1'b1;
    @(posedge bclk); iorq_n = 1'b1; cs_n = 1'b1; csff_n = 1'b1;
    repeat (3) @(posedge bclk);
end
endtask

task io_rd_t(input ff, input [1:0] r, output [7:0] v);
begin
    @(posedge bclk);
    a = {9'h000, r, 5'b11111};
    iorq_n = 1'b0; cs_n = ff; csff_n = !ff;
    @(posedge bclk); rd_n = 1'b0;
    repeat (10) @(posedge bclk);
    while (busy) @(posedge bclk);
    v = dout;
    rd_n = 1'b1;
    @(posedge bclk); iorq_n = 1'b1; cs_n = 1'b1; csff_n = 1'b1;
    repeat (3) @(posedge bclk);
end
endtask

// ---------------- fixtures ----------------
reg [7:0]  dlmem  [0:131071];
reg [31:0] cmdmem [0:4095];
reg [7:0]  expmem [0:65535];
reg [7:0]  rcv    [0:8191];
integer dl_n, ne;

task download;
    integer k, w;
begin
    io_index = 16'd1; io_download = 1'b1;
    repeat (8) @(posedge sclk);
    for (k = 0; k < dl_n; k = k + 1) begin
        w = 0;
        while (io_wait === 1'b1 && w < 4000000) begin @(posedge sclk); #1; w = w + 1; end
        if (w >= 4000000) begin $display("FAIL the ioctl wait never fell at byte %0d", k); errors = errors + 1; k = dl_n; end
        if ((k % 4096) == 0) $display("tb_fdd_ams: download byte %0d at %0d ms", k, edges / edges_per_ms);
        io_dout = dlmem[k]; io_wr = 1'b1;
        @(posedge sclk); #1;
        io_wr = 1'b0;
    end
    io_download = 1'b0;
    w = 0;
    while (io_wait === 1'b1 && w < 4000000) begin @(posedge sclk); #1; w = w + 1; end
end
endtask

// ---------------- the replay ----------------
integer i, got, k, bad, firstbad, guard, budget;
integer nread = 0, nread_ok = 0, ncmd = 0, ncmd_bad = 0;
reg [31:0] w0, w1;
always @(FDC_MOTOR or FDC_DS) $display("   [%0d ms] motor %b DS %b", edges / edges_per_ms, FDC_MOTOR, FDC_DS);
reg [7:0] op, cmd, trk, sec, dat, s, v, stat, st2;
integer idx;

initial begin
    $readmemh("dl.hex", dlmem);
    $readmemh("cmds.hex", cmdmem);
    $readmemh("exp.hex", expmem);
    dl_n = 0;
    while (dl_n < 131072 && dlmem[dl_n] !== 8'hxx) dl_n = dl_n + 1;
    ne = 0;
    while (ne < 2048 && cmdmem[2 * ne] !== 32'hxxxxxxxx) ne = ne + 1;
    $display("tb_fdd_ams: %0d FDI bytes, %0d trace entries", dl_n, ne);
    if (dl_n == 0 || ne == 0) begin $display("tb_fdd_ams: FAIL no fixtures"); $finish; end

    repeat (20) @(posedge bclk);
    reset = 1'b0;
    repeat (50) @(posedge bclk);
    download;
    $display("tb_fdd_ams: download done at %0d ms", edges / edges_per_ms);
    repeat (2000) @(posedge bclk);

    for (i = 0; i < ne; i = i + 1) begin
        w0 = cmdmem[2 * i]; w1 = cmdmem[2 * i + 1];
        $display("tb_fdd_ams: entry %0d op %0d cmd %h at %0d ms", i, w0[31:24], w0[23:16], edges / edges_per_ms);
        op = w0[31:24]; cmd = w0[23:16]; trk = w0[15:8]; sec = w0[7:0];
        dat = w1[31:24]; idx = w1[15:0];
        if (op == 8'd1) begin
            io_wr_t(1'b1, 2'd0, cmd);
        end
        else begin
            ncmd = ncmd + 1;
            io_wr_t(1'b0, 2'd1, trk);
            io_wr_t(1'b0, 2'd2, sec);
            io_wr_t(1'b0, 2'd3, dat);
            io_rd_t(1'b0, 2'd0, st2);                 // a quiet chip
            io_wr_t(1'b0, 2'd0, cmd);
            if (i < 6) begin io_rd_t(1'b0, 2'd0, st2); io_rd_t(1'b1, 2'd0, s); $display("   after cmd %h: status %h #FF %h motor %b DS %b TR00 %b", cmd, st2, s, FDC_MOTOR, FDC_DS, FDC_TR00); end
            budget = edges + CMD_MS * edges_per_ms;
            got = 0; s = 8'h00; guard = 0;
            while (!s[7] && edges < budget) begin
                io_rd_t(1'b1, 2'd0, s);
                if (s[6] && (op == 8'd3 || cmd[7:4] == 4'hC)) begin
                    io_rd_t(1'b0, 2'd3, v);
                    if (got < 8192) rcv[got] = v;
                    got = got + 1;
                end
            end
            io_rd_t(1'b0, 2'd0, stat);                // the status straight after INTRQ
            if (!s[7]) begin
                $display("FAIL entry %0d cmd %h trk %0d sec %0d: no INTRQ in %0d ms (#FF %h, %0d bytes)",
                         i, cmd, trk, sec, CMD_MS, s, got);
                $display("   drive: DS %b motor %b TR00 %b WPRT %b steps %0d index pulses %0d", FDC_DS, FDC_MOTOR, FDC_TR00, FDC_WPRT, nsteps, nidx);
                errors = errors + 1; ncmd_bad = ncmd_bad + 1;
                $display("tb_fdd_ams: FAIL stopped at the first failure"); $finish;
            end
            else if (op == 8'd3) begin
                nread = nread + 1;
                bad = 0; firstbad = -1;
                for (k = 0; k < got && k < 1024; k = k + 1)
                    if (rcv[k] !== expmem[idx * 1024 + k]) begin
                        if (firstbad < 0) firstbad = k;
                        bad = bad + 1;
                    end
                if (got != 1024 || bad != 0 || stat !== 8'h00) begin
                    $display("FAIL entry %0d RDSEC trk %0d sec %0d (read #%0d): %0d bytes, %0d wrong (first at %0d), status %h",
                             i, trk, sec, idx, got, bad, firstbad, stat);
                    errors = errors + 1; ncmd_bad = ncmd_bad + 1;
                end
                else nread_ok = nread_ok + 1;
            end
            else if (stat[4] || stat[3]) begin   // seek error / CRC; READY and WPRT are the drive's, not errors
                $display("FAIL entry %0d cmd %h trk %0d sec %0d: status %h (%0d bytes)",
                         i, cmd, trk, sec, stat, got);
                errors = errors + 1; ncmd_bad = ncmd_bad + 1;
            end
        end
    end
    $display("tb_fdd_ams: %0d commands, %0d failed; %0d sector reads, %0d exact; %0d ms of disk time",
             ncmd, ncmd_bad, nread, nread_ok, edges / edges_per_ms);
    if (errors == 0) $display("tb_fdd_ams: PASS");
    else $display("tb_fdd_ams: FAIL %0d errors", errors);
    $finish;
end

initial begin
    #(40000000000.0);
    $display("tb_fdd_ams: FAIL watchdog");
    $finish;
end

endmodule
