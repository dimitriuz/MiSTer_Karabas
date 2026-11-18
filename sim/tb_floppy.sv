// Testbench for rtl/disk/floppy.sv: the stage 4c drive model against the real
// controller. The customer is the upstream VG93 exactly as profi.vhd wires it
// (hrdy_fdc + fdd_glue + vg93_*, no rewrites, ENABLE_FDD), and the model is
// the machine's only view of a disk: the CPU-side tasks (io_wr/io_rd), the
// reference track builder (build_track: one MFM sector - 40/12 gaps, 3xA1
// sync, FE ID C=0 H=0 R=1 N=1, 22/12 gaps, 3xA1, FB, 256 bytes, CRC) and the
// flux decoder of the written stream are those of
// upstream/karabas-go-core-profi/src/sim/tb_hrdy_fdc.v; the track is padded
// with 0x4E to the 6250 bytes of a revolution.
//
// Parameters: DS80 (clk_bus 24.107 MHz instead of 28.125), TURBO (ena_cpu
// every clock = x8, or every 8th = 3.5 MHz) and the cell cadence
// CELL_NUM/CELL_DEN, which is how the speed of the disk reaches the model:
// the tick rate is clk_bus * CELL_NUM / CELL_DEN, one tick being half an MFM
// cell of the flux (nominal 500 kHz).
//
// The store side is a bench model of fdd_store (Task 4): it answers every
// track request with {ready, echo} and switches the buffer it serves to the
// requested {drive, side}, it copies the write buffer out through its port B
// on wr_tgl and answers with wr_ack_tgl. The four 8192x9 track buffers and
// the 1024x8 write buffer are sim/models/altsyncram_model.sv instances,
// preloaded through port A exactly as the store will fill them.
//
// Cases (each prints `PASS <case>` or `FAIL <case> ...`):
//   restore          track 0: RESTORE (0x08) ends without a step and TR00=1;
//                    Seek 3 (the target in DATA #7F, CMD=0x10) steps 3 times in;
//                    RESTORE again steps 3 times about 3 ms apart (TurboFDC:
//                    twice the step rate of CLK 1 MHz), the head ends at track 0 and
//                    the status has busy=0, TR00=1.
//   poll             the TR-DOS #3FD5 loop: 64 reads of #FF with 47 T between.
//                    Turbo: the period stays that of the 3.5 MHz CPU, within
//                    3 % of (47+5)*8 clk_bus clocks; at 3.5 MHz: no WAIT.
//   read_sector      sector 1: 256 bytes by DRQ equal the reference track,
//                    status 0.
//   write_sector     256 bytes 0xFF-i*3 by DRQ, status 0; the store model
//                    captures the sector and wr_info carries drive A, side 0,
//                    track 0, C=0 H=0 R=1 N=1; the flux decoder reads back the
//                    FB mark, the bytes and the CRC it was sent.
//   read_after_write the model patches the buffer from the captured sector
//                    (with a recomputed CRC, as the store will) and the next
//                    read returns the new bytes.
//   drive_b          #FF bits 1:0 = 01 (hrdy_fdc: 00 -> FDC_DS[0] = drive A, 01
//                    -> FDC_DS[1] = drive B, anything else selects neither):
//                    B's buffer reads back. With swap=1 selecting A reads B's
//                    buffer and selecting B reads A's.
//   side1            #FF bit 4 = 0 (FDC_SIDE1 high): side 1's buffer reads
//                    back, the ID of which also has H=0 (the TRD convention).
//   wprt             wprt=1: the write ends with the write-protect status bit
//                    and the store model sees no wr_tgl.
//   bad_crc          one ID CRC byte of the track is corrupted: the read ends
//                    RNF, nothing is transferred, nothing is written.
//   track_not_ready  the store answers ready=0 for the track the head moves to
//                    (a STEP with SEEK, 0x18, so the head load bit keeps HLD up):
//                    the stream is filler - a read ends RNF while the index keeps
//                    pulsing. An answer with ready=1 whose echo is NOT the request
//                    must leave it filler; re-asked and answered with a matching
//                    echo, the sector comes back on the next revolution. The
//                    re-ask only happens while a command holds the head loaded, so
//                    the wrong-echo answer and the check for it live inside one
//                    one full-budget read: re-ask (<=200 ms), the index at which a drive
//                    that had taken it would arm (<=200 ms more), and a sector's
//                    worth of flux after that.
//   side_flip        the side flips just after an index and the store does not answer:
//                    the read straight after it must get nothing (record-not-found),
//                    never the sector of the side that was left; once the store has
//                    answered, side 1 reads. A drive that drops its stream only at the
//                    next cell tick (not at once) fails this.
//   no_select        two states with both select lines down. Motor down (between
//                    commands, a SEEK steps with FDC_DS == 00): the step moves the held
//                    drive, never A, and no request names a drive nobody chose. Motor
//                    up with #FF bits 1:0 = 1x (drive C/D, which this machine does not
//                    have): no stream (no index, no flux), no step moves a head, no
//                    request.
//   pend_drop        with the store's answer withheld, a second written field is
//                    dropped rather than overwriting the one that is waiting;
//                    after the answer a new field is offered again.
//   no_motor         /MR low: HLD drops, the motor stops: no index, no flux.
//
// Three things the chip insists on, all invisible in the model and all easy to get
// wrong. (1) The motor is the chip's own head-load output (.READY(motor) in
// hrdy_fdc), so a read issued while the head is unloaded ends at once, not-ready;
// do_read/do_write therefore start with a RESTORE with the head-load bit (spin_up).
// (2) A type I command *without* that bit drops HLD when it ends, so everything
// issued after a plain 0x10 SEEK ends at once, not-ready - the moves in these cases
// are 0x18/0x28, which carry the load. (3) INTRQ is cleared only by an access to the
// status / command register (vg93_status.v:14) and may rise again as the last
// microword of the same command ends, so clear_intrq takes it until it stays taken;
// status bit 7 is not-ready rather than busy, and bit 0 is the one that is BUSY.
// Three checks look inside the model (u_drive.active, u_drive.trk_a/trk_b): what is
// under test is a property the flux cannot show at that moment - a stream that must
// not have armed, a head that must not have moved while nobody was selected - and a
// hierarchical reference is what tb_tape_play.sv already uses for the same reason.
//
// Every wait is an edge count, never a $time difference (the only $realtime
// use is the flux decoder's cell measurement, as upstream). The last line is
// `tb_floppy: PASS` or `tb_floppy: FAIL <reason>`; run it with
// sim/run_tb_floppy.sh (+CASE=<n> and RUNS="..." select a case, a combination).
`timescale 1ns / 1ps

module tb_floppy;

parameter DS80  = 0;
parameter TURBO = 1;
parameter [15:0] CELL_NUM = 16'd4;
parameter [15:0] CELL_DEN = 16'd225;

localparam integer GAP         = 20;    // idle clk between the accesses of a transfer loop
// The patience of one command attempt. A read whose sector never appears is not
// answered until the chip has searched the track six times (measured: the status
// says record-not-found 1199 ms after the command, with the disk turning at
// 200 ms a turn), so an attempt has to outlast the search. -P
// tb_floppy.ATTEMPT_MS=... overrides it.
parameter integer ATTEMPT_MS  = 1300;   // what one command attempt may take (a turn is 200 ms)
localparam integer TRIES       = 3;     // read retries, as DOS retries

// +CASE=<n> runs one case only, for debugging (a full run is tens of minutes):
// 1 restore, 2 poll, 3 read_sector, 4 write_sector, 5 read_after_write,
// 6 drive_b, 7 side1, 8 wprt, 9 bad_crc, 10 track_not_ready (and the echo of an
// answer), 12 side_flip, 13 no_select, 14 pend_drop, 11 no_motor (last in the
// file: it takes the motor away). Every case starts from the preloaded tracks, so
// any one of them runs alone; the cases that leave a mark (read_after_write
// patches buffer 0, the writes of pend_drop) carry their own premise.
integer only_case = 0;
function bit run(input integer c);
    run = (only_case == 0) || (only_case == c);
endfunction
real CLK_HALF = DS80 ? 20.741 : 17.778;   // 24.107 / 28.125 MHz
reg clk = 1'b0;
always #(CLK_HALF) clk = ~clk;
parameter integer WATCHDOG = 300000000;   // clk of the whole run, for the hang watchdog

integer edges_per_ms = DS80 ? 24107 : 28125;   // clk ticks of a millisecond
integer edges = 0;                              // clk ticks since the start

// ---------------- checks ----------------
integer errors = 0, case_errors = 0, shown = 0, case_t0 = 0;

task fail_int(input [8*22-1:0] cs, input [8*36-1:0] what,
              input [63:0] got, input [63:0] want);
begin
    if (got !== want) begin
        if (shown < 8) $display("FAIL %0s %0s got %0d want %0d", cs, what, got, want);
        shown = shown + 1;
        errors = errors + 1;
    end
end
endtask

task case_begin;
begin case_errors = errors; shown = 0; case_t0 = edges; end
endtask

task case_end(input [8*22-1:0] cs);
begin
    if (errors == case_errors) $display("PASS %0s (%0d ms)", cs, (edges - case_t0) / edges_per_ms);
    else $display("FAIL %0s (%0d checks failed)", cs, errors - case_errors);
end
endtask

// ---------------- CPU bus (as profi decodes it) ----------------
reg reset = 1'b1;
reg [15:0] a = 16'hFFFF;
reg [7:0]  d = 8'hFF;
reg wr_n = 1'b1, rd_n = 1'b1, iorq_n = 1'b1;
reg cs_n = 1'b1, csff_n = 1'b1;
wire oe_n, busy;
wire [7:0] dout;

reg [2:0] ecnt = 3'd0;
always @(posedge clk) ecnt <= ecnt + 3'd1;
wire ena_cpu = TURBO ? 1'b1 : (ecnt == 3'd7);
integer waits = 0;                  // clocks of WAIT seen by the CPU

// ---------------- the drive pins ----------------
wire [1:0] FDC_DS;
wire FDC_SIDE1, FDC_WG, FDC_WR_DATA, FDC_STEP, FDC_DIR, FDC_MOTOR;
wire FDC_RDATA, FDC_INDEX, FDC_TR00, FDC_WPRT;

reg  [1:0] wprt = 2'b00;            // OSD read-only per drive
reg        swap = 1'b0;             // port #028B bit 3

// the track buffers: {drive, side} -> an 8192x9 altsyncram, port A written by
// the store model (here), port B read by the drive
reg  [12:0] ram_addr_a = 13'd0;
reg  [8:0]  ram_data_a = 9'd0;
reg  [3:0]  ram_we     = 4'd0;
wire [8:0]  ram_q      [0:3];
wire [12:0] trk_addr_a, trk_addr_b;
wire [8:0]  trk_q_a, trk_q_b;

// the written sector buffer: port A written by the drive, port B read here
reg  [9:0]  wram_addr_b = 10'd0;
wire [7:0]  wram_q_b;
wire [9:0]  wr_addr;
wire [7:0]  wr_data;
wire        wr_we;

reg         trk_req_tgl;
reg  [8:0]  trk_req;
reg         trk_ack_tgl = 1'b0;
reg  [9:0]  trk_ack     = 10'd0;
reg  [12:0] trk_len     = 13'd6250;
reg         wr_tgl;
reg  [35:0] wr_info;
reg         wr_ack_tgl  = 1'b0;

floppy u_drive (
    .clk(clk), .reset(reset), .ds80(DS80 != 0), .swap(swap),
    .cell_num(CELL_NUM), .cell_den(CELL_DEN),
    .fdc_drive(FDC_DS), .fdc_motor(FDC_MOTOR), .fdc_step(FDC_STEP), .fdc_dir(FDC_DIR),
    .fdc_side_n(FDC_SIDE1), .fdc_wgate(FDC_WG), .fdc_wdata(FDC_WR_DATA),
    .fdc_rdata(FDC_RDATA), .fdc_index(FDC_INDEX), .fdc_tr00(FDC_TR00), .fdc_wprt(FDC_WPRT),
    .wprt(wprt),
    .trk_req_tgl(trk_req_tgl), .trk_req(trk_req),
    .trk_ack_tgl(trk_ack_tgl), .trk_ack(trk_ack), .trk_len(trk_len),
    .trk_addr_a(trk_addr_a), .trk_addr_b(trk_addr_b),
    .trk_q_a(trk_q_a), .trk_q_b(trk_q_b),
    .wr_tgl(wr_tgl), .wr_info(wr_info), .wr_ack_tgl(wr_ack_tgl),
    .wr_addr(wr_addr), .wr_data(wr_data), .wr_we(wr_we)
);

generate
    genvar gi;
    for (gi = 0; gi < 4; gi = gi + 1) begin : TRAMS
        altsyncram #(.numwords_a(8192), .widthad_a(13), .width_a(9),
                     .numwords_b(8192), .widthad_b(13), .width_b(9)) u_tram (
            .clock0(clk), .clock1(clk),
            .address_a(ram_addr_a), .data_a(ram_data_a), .wren_a(ram_we[gi]), .q_a(),
            .address_b(trk_addr_b), .data_b(9'd0), .wren_b(1'b0), .q_b(ram_q[gi]),
            .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
            .byteena_a(1'b1), .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
            .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
        );
    end
endgenerate

altsyncram #(.numwords_a(1024), .widthad_a(10), .width_a(8),
             .numwords_b(1024), .widthad_b(10), .width_b(8)) u_wram (
    .clock0(clk), .clock1(clk),
    .address_a(wr_addr), .data_a(wr_data), .wren_a(wr_we), .q_a(),
    .address_b(wram_addr_b), .data_b(8'd0), .wren_b(1'b0), .q_b(wram_q_b),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(1'b1), .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
);

hrdy_fdc u_fdc (
    .clk(clk), .ds80(DS80 != 0), .reset(reset), .ena_cpu(ena_cpu),
    .a(a), .d(d), .wr_n(wr_n), .rd_n(rd_n), .iorq_n(iorq_n),
    .cs_n(cs_n), .csff_n(csff_n), .oe_n(oe_n), .dout(dout), .busy(busy),
    .FDC_SIDE1(FDC_SIDE1), .FDC_RDATA(FDC_RDATA), .FDC_WPRT(FDC_WPRT), .FDC_TR00(FDC_TR00),
    .FDC_INDEX(FDC_INDEX), .FDC_WG(FDC_WG), .FDC_WR_DATA(FDC_WR_DATA), .FDC_STEP(FDC_STEP),
    .FDC_DIR(FDC_DIR), .FDC_MOTOR(FDC_MOTOR), .FDC_DS(FDC_DS)
);

// ---------------- what the drive shows the controller ----------------
integer idx_pulses = 0, flux_pulses = 0;
integer steps = 0, step_edges = 0, step_t0 = 0, step_t1 = 0, step_dir = 0;
integer steps_nods = 0;                // step pulses seen with FDC_DS == 00 and the motor down
integer steps_cd   = 0;                // ... and with the motor up (drive C or D selected)
integer cd0 = 0;
integer nods0 = 0;
integer trk0 = 0;
integer reqa0 = 0;
reg step_d = 1'b0, idx_d = 1'b0, flux_d = 1'b0;

always @(posedge clk) begin
    edges = edges + 1;
    step_edges = step_edges + 1;
    if (FDC_STEP && !step_d) begin
        steps     = steps + 1;
        step_t0   = step_t1;
        step_t1   = step_edges;
        step_dir  = FDC_DIR;
        if (FDC_DS == 2'b00) begin
            if (FDC_MOTOR) steps_cd = steps_cd + 1;
            else           steps_nods = steps_nods + 1;
        end
    end
    step_d <= FDC_STEP;
    if (FDC_INDEX && !idx_d)   idx_pulses  = idx_pulses + 1;
    if (FDC_RDATA && !flux_d)  flux_pulses = flux_pulses + 1;
    idx_d  <= FDC_INDEX;
    flux_d <= FDC_RDATA;
end

// ---------------- the reference tracks ----------------
// buffer 0 = drive A side 0, 1 = A side 1, 2 = B side 0, 3 = B side 1; every
// one of them is sector 1 of track 0, ID C=0 H=0 R=1 N=1 (TRD: H is 0 on both
// sides), only the data pattern differs.
localparam integer TBYTES = 359;     // the built track, the revolution is padded to 6250

function [7:0] pat;
    input integer b; input integer i;
    begin
        case (b)
            0:       pat = ((i *   7 + 8'h35) ^ (i >>  3)) & 8'hFF;
            1:       pat = ((i *  13 + 8'h5A) ^ (i >>  2)) & 8'hFF;
            2:       pat = ((i *   5 + 8'hC3) ^ (i >>  4)) & 8'hFF;
            default: pat = ((i *  11 + 8'h0F) ^ (i >>  1)) & 8'hFF;
        endcase
    end
endfunction

function [15:0] crc_byte(input [15:0] crc, input [7:0] b);
    integer i;
    begin
        crc_byte = crc ^ {b, 8'h00};
        for (i = 0; i < 8; i = i + 1)
            crc_byte = crc_byte[15] ? {crc_byte[14:0], 1'b0} ^ 16'h1021 : {crc_byte[14:0], 1'b0};
    end
endfunction

integer tlen = 0, data_off = 0;
integer id_crc_off = 0;              // the ID field's CRC bytes
reg [7:0] tbytes [0:1023];
reg       tsync  [0:1023];
reg [7:0] sector  [0:255];           // the data of the track last built
reg [7:0] patchbuf[0:1023];          // bytes for patch_track
integer patchlen = 0;

task build_track(input integer b);
    integer i;
    reg [15:0] crc;
    begin
        for (i = 0; i < 256; i = i + 1) sector[i] = pat(b, i);
        tlen = 0;
        for (i = 0; i < 40; i = i + 1) begin tbytes[tlen] = 8'h4E; tsync[tlen] = 1'b0; tlen = tlen + 1; end
        for (i = 0; i < 12; i = i + 1) begin tbytes[tlen] = 8'h00; tsync[tlen] = 1'b0; tlen = tlen + 1; end
        crc = 16'hFFFF;
        for (i = 0; i < 3; i = i + 1) begin tbytes[tlen] = 8'hA1; tsync[tlen] = 1'b1; tlen = tlen + 1; crc = crc_byte(crc, 8'hA1); end
        tbytes[tlen] = 8'hFE; tsync[tlen] = 1'b0; tlen = tlen + 1; crc = crc_byte(crc, 8'hFE);
        tbytes[tlen] = 8'h00; tsync[tlen] = 1'b0; tlen = tlen + 1; crc = crc_byte(crc, 8'h00);   // C
        tbytes[tlen] = 8'h00; tsync[tlen] = 1'b0; tlen = tlen + 1; crc = crc_byte(crc, 8'h00);   // H
        tbytes[tlen] = 8'h01; tsync[tlen] = 1'b0; tlen = tlen + 1; crc = crc_byte(crc, 8'h01);   // R
        tbytes[tlen] = 8'h01; tsync[tlen] = 1'b0; tlen = tlen + 1; crc = crc_byte(crc, 8'h01);   // N: 256
        id_crc_off = tlen;
        tbytes[tlen] = crc[15:8]; tsync[tlen] = 1'b0; tlen = tlen + 1;
        tbytes[tlen] = crc[7:0];  tsync[tlen] = 1'b0; tlen = tlen + 1;
        for (i = 0; i < 22; i = i + 1) begin tbytes[tlen] = 8'h4E; tsync[tlen] = 1'b0; tlen = tlen + 1; end
        for (i = 0; i < 12; i = i + 1) begin tbytes[tlen] = 8'h00; tsync[tlen] = 1'b0; tlen = tlen + 1; end
        crc = 16'hFFFF;
        for (i = 0; i < 3; i = i + 1) begin tbytes[tlen] = 8'hA1; tsync[tlen] = 1'b1; tlen = tlen + 1; crc = crc_byte(crc, 8'hA1); end
        tbytes[tlen] = 8'hFB; tsync[tlen] = 1'b0; tlen = tlen + 1; crc = crc_byte(crc, 8'hFB);
        data_off = tlen;
        for (i = 0; i < 256; i = i + 1) begin
            tbytes[tlen] = sector[i]; tsync[tlen] = 1'b0; tlen = tlen + 1; crc = crc_byte(crc, sector[i]);
        end
        tbytes[tlen] = crc[15:8]; tsync[tlen] = 1'b0; tlen = tlen + 1;
        tbytes[tlen] = crc[7:0];  tsync[tlen] = 1'b0; tlen = tlen + 1;
        for (i = 0; i < 60; i = i + 1) begin tbytes[tlen] = 8'h4E; tsync[tlen] = 1'b0; tlen = tlen + 1; end
    end
endtask

// one byte of a buffer through the store's port A, as fdd_store writes it
task ram_write(input integer b, input integer off, input [8:0] v);
begin
    ram_addr_a = off[12:0];
    ram_data_a = v;
    ram_we     = 4'd0;
    ram_we[b]  = 1'b1;
    @(posedge clk);
    ram_we     = 4'd0;
end
endtask

task preload(input integer b);
    integer i;
begin
    for (i = 0; i < 6250; i = i + 1)
        ram_write(b, i, (i < tlen) ? {tsync[i], tbytes[i]} : {1'b0, 8'h4E});
end
endtask

// patch [0:patchlen) of patchbuf into buffer b at off, the way the store
// patches a written sector (data and the CRC that follows it)
task patch_track(input integer b, input integer off);
    integer i;
begin
    for (i = 0; i < patchlen; i = i + 1) ram_write(b, off + i, {1'b0, patchbuf[i]});
end
endtask

// ---------------- the store model ----------------
reg        store_rdy   = 1'b1;        // what the model answers ready with
reg        ack_bad     = 1'b0;        // answer with an echo that is not the request
reg        ack_stall   = 1'b0;        // the store has a request and does not answer yet
reg        no_index    = 1'b0;        // do_read: issue now, do not wait for index
integer    attempt_ms  = ATTEMPT_MS;  // do_read: the patience of one attempt
reg        store_drv   = 1'b0;        // the buffer served on port B
reg        store_side  = 1'b0;
// Both views of the drive's toggles start unknown, like the toggles themselves;
// a receiver that starts at 0 watches the drive settle from x and calls that a
// handshake (see the first look below).
reg        req_seen    = 1'bx;
reg        ack_go      = 1'b0;
reg [3:0]  ack_wait    = 4'd0;
reg [8:0]  req_lat     = 9'd0;
reg [8:0]  rq_last     = 9'd0;
integer    req_count   = 0;
integer    req_a       = 0;            // requests whose payload names drive A

assign trk_q_b = ram_q[{store_drv, store_side}];
assign trk_q_a = ram_q[0];            // the drive mirrors its address on port A only

always @(posedge clk) begin
    if (req_seen === 1'bx)
        req_seen <= trk_req_tgl;         // the first look only records what the drive
    else if (trk_req_tgl !== req_seen) begin   // settled to: a toggle is not counted
        req_seen  <= trk_req_tgl;
        req_lat   <= trk_req;
        rq_last   <= trk_req;
        req_count <= req_count + 1;
        if (!trk_req[8]) req_a <= req_a + 1;
        ack_go    <= 1'b1;
        ack_wait  <= 4'd6;
    end
    else if (ack_go && !ack_stall) begin
        ack_wait <= ack_wait - 4'd1;
        if (ack_wait == 4'd1) begin
            ack_go    <= 1'b0;
            // The buffer served on port B changes when the answer goes out, not
            // when the request arrives: the store builds ONE buffer per drive
            // and side in place, so until it has answered for the new track its
            // buffers still hold the bytes of the old one. A drive that kept
            // reading them would hand the controller the other side's sector
            // with a status of "no error", which is the bug this models out.
            if (store_rdy) begin
                store_drv  <= req_lat[8];
                store_side <= req_lat[7];
            end
            trk_ack   <= {store_rdy, ack_bad ? ~req_lat : req_lat};
            trk_ack_tgl <= ~trk_ack_tgl;
        end
    end
end

// the captured write: wr_info and the buffer, copied out through port B
reg        cap_seen   = 1'bx;            // unknown, as req_seen
reg        cap_busy   = 1'b0;
reg  [1:0] cap_phase = 2'd0;
reg        cap_done   = 1'b0;
reg [35:0] wr_got     = 36'd0;
integer    cap_i      = 0, cap_n = 0, wr_count = 0;
reg [7:0]  cap        [0:1023];
reg        wr_ack_hold = 1'b0;
reg        wr_ack_stall = 1'b0;       // the store is made to wait with its answer

always @(posedge clk) begin
    if (cap_seen === 1'bx)
        cap_seen <= wr_tgl;              // as above: the first look only records
    else if (wr_tgl !== cap_seen) begin
        cap_seen  <= wr_tgl;
        wr_got    <= wr_info;
        cap_i     <= 0;
        cap_n     <= 128 << wr_info[2:0];
        cap_busy  <= 1'b1;
        cap_phase <= 2'd0;
        cap_done  <= 1'b0;
        wr_count  <= wr_count + 1;
        wram_addr_b <= 10'd0;
    end
    else if (cap_busy) begin
        // Port B of the buffer registers its address, so a byte costs three
        // clocks: present the address, let it reach the memory, take q_b.
        cap_phase <= cap_phase + 2'd1;
        case (cap_phase)
            2'd0: wram_addr_b <= cap_i[9:0];
            2'd2: begin
                cap[cap_i] <= wram_q_b;
                if (cap_i + 1 >= cap_n) begin
                    cap_busy    <= 1'b0;
                    cap_done    <= 1'b1;
                    wr_ack_hold <= 1'b1;
                end
                else cap_i <= cap_i + 1;
            end
            default: ;
        endcase
    end
    // the store answers the write once it has the sector
    if (wr_ack_hold && !wr_ack_stall) begin   // a case can make the store wait
        wr_ack_hold   <= 1'b0;
        wr_ack_tgl    <= ~wr_ack_tgl;
    end
end

// ---------------- the written flux, decoded independently ----------------
// (upstream tb_hrdy_fdc's decoder: cells of 2 us, 3x sync 4489, the mark, the
// bytes and the two CRC bytes)
reg [7:0] wgot [0:257];
integer wcount = 0, wstate = 0, wbits = 0;
reg [47:0] wsr = 48'd0;
realtime wprev = 0;
reg wfirst = 1'b1;
reg [7:0] wmark = 8'h00;

function [7:0] mfm_data(input [15:0] w);
    mfm_data = {w[14], w[12], w[10], w[8], w[6], w[4], w[2], w[0]};
endfunction

always @(negedge FDC_WG) wfirst = 1'b1;

always @(posedge FDC_WR_DATA) if (FDC_WG) begin : wdec
    integer n, i;
    if (wfirst) begin
        wfirst = 1'b0; wstate = 0;
        n = 1;
    end else
        n = ($realtime - wprev) / 2000.0;   // cells since the last transition
    wprev = $realtime;
    for (i = 0; i < n; i = i + 1) begin
        wsr = {wsr[46:0], i == n - 1};
        if (wstate == 0) begin
            if (wsr == {16'h4489, 16'h4489, 16'h4489}) begin wstate = 1; wbits = 0; end
        end else begin
            wbits = wbits + 1;
            if (wbits == 16) begin
                wbits = 0;
                if (wstate == 1) begin wmark = mfm_data(wsr[15:0]); wstate = 2; wcount = 0; end
                else if (wstate == 2 && wcount < 258) begin
                    wgot[wcount] = mfm_data(wsr[15:0]);
                    wcount = wcount + 1;
                end
            end
        end
    end
end

task flux_reset;
begin
    wcount = 0; wstate = 0; wbits = 0; wsr = 48'd0; wfirst = 1'b1; wmark = 8'h00;
end
endtask

// ---------------- the CPU side (upstream tb_hrdy_fdc) ----------------
task io_wr(input ff, input [1:0] r, input [7:0] v);
begin
    @(posedge clk);
    a = {9'h000, r, 5'b11111}; d = v;
    iorq_n = 1'b0; cs_n = ff; csff_n = !ff;
    @(posedge clk); wr_n = 1'b0;
    repeat (10) begin @(posedge clk); if (busy) waits = waits + 1; end
    while (busy) begin @(posedge clk); waits = waits + 1; end   // WAIT
    wr_n = 1'b1;
    @(posedge clk); iorq_n = 1'b1; cs_n = 1'b1; csff_n = 1'b1;
    repeat (3) @(posedge clk);
end
endtask

task io_rd(input ff, input [1:0] r, output [7:0] v);
begin
    @(posedge clk);
    a = {9'h000, r, 5'b11111};
    iorq_n = 1'b0; cs_n = ff; csff_n = !ff;
    @(posedge clk); rd_n = 1'b0;
    repeat (10) begin @(posedge clk); if (busy) waits = waits + 1; end
    while (busy) begin @(posedge clk); waits = waits + 1; end   // WAIT
    v = dout;
    rd_n = 1'b1;
    @(posedge clk); iorq_n = 1'b1; cs_n = 1'b1; csff_n = 1'b1;
    repeat (3) @(posedge clk);
end
endtask

reg [7:0] st;
// INTRQ rises at the end of a command and is cleared by an access to the status /
// command register (vg93_status.v:14); a peek at #FF shows the pin and clears nothing.
// One access is not always enough either, because the pin may rise again as the last
// microword of the same command ends. Take it until it stays taken.
task clear_intrq;
    reg [7:0] s2;
    integer n;
begin
    n = 0;
    while (n < 8) begin
        io_rd(0, 0, s2);
        io_rd(1, 0, s2);
        if (!s2[7]) n = n + 1;
        else n = 0;
        repeat (40) @(posedge clk);
    end
end
endtask

task wait_intrq(input integer ms);
    integer budget;
begin
    st = 8'h00;
    budget = edges + ms * edges_per_ms;
    while (!st[7] && edges < budget) io_rd(1, 0, st);
    if (!st[7]) begin $display("tb_floppy: no INTRQ in %0d ms", ms); errors = errors + 1; end
    // Take the request, or the next command issued on top of it ends after 0 ms
    // with the status of the one that has just finished.
    clear_intrq;
end
endtask

// Commands start at the index: the reference track's ID is 1.7 ms after it, so
// a command issued there is served in milliseconds instead of waiting for the
// disk to come round (a DOS does not care which millisecond it starts in; the
// simulation cares very much).
task wait_index(input integer ms);
    integer target, budget;
begin
    target = idx_pulses + 1;
    budget = edges + ms * edges_per_ms;
    while (idx_pulses < target && edges < budget) @(posedge clk);
end
endtask

// The chip's READY is its own head-load output (hrdy_fdc ties .READY(motor)), so
// no read or write does anything until a head-loading command has started the
// motor: a read issued before that ends at once with the not-ready bit of the
// status. RESTORE is what a DOS issues first, and the precondition of every
// command below - a case run alone with +CASE= has not given one yet.
reg spun_up = 1'b0;
task spin_up;
begin
    if (!spun_up) begin
        io_wr(0, 0, 8'h08);                    // RESTORE: HLD -> the motor starts
        wait_intrq(100);
        spun_up = 1'b1;
    end
end
endtask

// ---------------- the commands, with the retries a DOS does ----------------
integer roK, rn, rbad;
reg [7:0] rstat;
reg [7:0] wbuf [0:255];
integer wg_n;
reg [7:0] wg_stat;

// Buffer 0 stops being pat(0,.) once read_after_write has patched it with the
// sector the machine wrote: from then on the reference of a read of buffer 0 is
// what the store captured.
reg cap_valid = 1'b0;

// the first bytes of a failing attempt, for the log
reg [7:0] dbg_got [0:7];
reg [7:0] dbg_exp [0:7];

// Read Sector r of buffer b, up to TRIES attempts. A drive that has just been
// told a track is ready switches to it at the next index, so a first attempt
// over filler is normal.
task do_read(input [7:0] r, input integer b, input integer tries,
             output integer ok, output integer n, output integer bad, output [7:0] stat);
    integer t, got, bd, t0e;
    reg [7:0] v, s, exp;
    integer budget;
begin
    ok = 0; n = 0; bad = 0; stat = 8'hFF;
    for (t = 0; t < tries && !ok; t = t + 1) begin
        spin_up;
        // A read that is meant to catch the drive mid-revolution (the side flip
        // case) must not first walk to the index - and neither can one issued
        // while the head is off the track: the drive only turns while the chip's
        // head-load line is up, so with the motor down no index is coming and the
        // walk would burn its whole budget for nothing.
        if (!no_index && FDC_MOTOR) wait_index(attempt_ms);
        io_wr(0, 2, r);
        clear_intrq;                       // a quiet chip, then the command
        io_wr(0, 0, 8'h80);
        got = 0; bd = 0; s = 8'h00;
        t0e = edges;
        budget = edges + attempt_ms * edges_per_ms;
        while (!s[7] && edges < budget) begin
            io_rd(1, 0, s);
            repeat (GAP) @(posedge clk);
            if (s[6]) begin
                io_rd(0, 3, v);
                repeat (GAP) @(posedge clk);
                exp = (cap_valid && b == 0) ? cap[got] : pat(b, got);
                if (got < 256 && v !== exp) bd = bd + 1;
                if (got < 8) begin dbg_got[got] = v; dbg_exp[got] = exp; end
                got = got + 1;
            end
        end
        // INTRQ is the lagging pin of the pair (REG_INTRQ is held in the second
        // half of a microword, errata 5), so the status read straight after it
        // can still show BUSY: read it until it does not, as a DOS polling
        // #3FD5 and then #3FFD does.
        io_rd(0, 0, stat);
        while (stat[0] && edges < budget + 20 * edges_per_ms) begin
            repeat (200) @(posedge clk);
            io_rd(0, 0, stat);
        end
        n = got; bad = bd;
        ok = (got == 256 && bd == 0 && stat == 8'h00);
        if (!ok) begin                 // #FF bit 7 = INTRQ: 0 here means it never came
            $display("tb_floppy:   read try %0d: %0d bytes (%0d wrong), #FF %h, status %h, %0d ms",
                     t, got, bd, s, stat, (edges - t0e) / edges_per_ms);
            $display("tb_floppy:     got %h %h %h %h want %h %h %h %h",
                     dbg_got[0], dbg_got[1], dbg_got[2], dbg_got[3],
                     dbg_exp[0], dbg_exp[1], dbg_exp[2], dbg_exp[3]);
        end
    end
end
endtask

// Write Sector r: the 256 bytes of wbuf by DRQ
task do_write(input [7:0] r, output integer n, output [7:0] stat);
    reg [7:0] s;
    integer got, budget;
begin
    spin_up;
    // as in do_read: the disk only turns under a loaded head, so with the
    // head-load line down there is no index to walk to.
    if (FDC_MOTOR) wait_index(ATTEMPT_MS);
    io_wr(0, 2, r);
    clear_intrq;                           // a quiet chip, then the command
    io_wr(0, 0, 8'hA0);
    got = 0; s = 8'h00;
    budget = edges + ATTEMPT_MS * edges_per_ms;
    while (!s[7] && edges < budget) begin
        io_rd(1, 0, s);
        repeat (GAP) @(posedge clk);
        if (s[6]) begin
            io_wr(0, 3, got < 256 ? wbuf[got] : 8'h00);
            repeat (GAP) @(posedge clk);
            got = got + 1;
        end
    end
    io_rd(0, 0, stat);
    while (stat[0] && edges < budget + 20 * edges_per_ms) begin      // as in do_read
        repeat (200) @(posedge clk);
        io_rd(0, 0, stat);
    end
    n = got;
end
endtask

// ---------------- the tests ----------------
integer i, t0, t1, sp;
integer idx0, flux0, req0, wr0;
reg [7:0] v;
reg [15:0] crc;

initial begin : test
    $display("tb_floppy: DS80=%0d TURBO=%0d cell=%0d/%0d", DS80, TURBO, CELL_NUM, CELL_DEN);
    if (!$value$plusargs("CASE=%d", only_case)) only_case = 0;
    if (only_case != 0) $display("tb_floppy: only case %0d", only_case);

    // ---- the four tracks, before the drive is let go ----
    for (i = 0; i < 4; i = i + 1) begin
        build_track(i);
        preload(i);
    end
    build_track(0);                        // sector[] = buffer 0 again

    repeat (20) @(posedge clk);
    reset = 1'b0;
    io_wr(1, 0, 8'h00);                    // #FF: /MR low
    repeat (50) @(posedge clk);
    io_wr(1, 0, 8'h3C);                    // #FF: drive A, /MR high, HLT, side 0

    // ---- restore ----
    if (run(1)) begin                    // restore
    case_begin;
    // What the drive shows before any command: no write handshake of any kind
    // (a toggle line the store compares with 0 would show up here as a phantom
    // write), and a request for {drive A, side 0, track 0}.
    fail_int("restore", "writes before any write", wr_count, 0);
    fail_int("restore", "the request at boot", rq_last, 0);
    steps = 0; step_t0 = 0; step_t1 = 0;
    io_wr(0, 0, 8'h08);                    // RESTORE: the head is already at 0
    wait_intrq(100);
    io_rd(0, 0, v);
    $display("tb_floppy: restore at 0: %0d steps, status %h", steps, v);
    fail_int("restore", "steps from track 0", steps, 0);
    fail_int("restore", "status busy", v[0], 0);
    fail_int("restore", "status TR00", v[2], 1);
    // Seek 3: the VG93 takes the target of a SEEK from the DATA register
    steps = 0;
    io_wr(0, 3, 8'd3);                     // #7F: the track to seek to
    io_wr(0, 0, 8'h10);                    // SEEK
    wait_intrq(100);
    $display("tb_floppy: seek 3: %0d steps, dir %0d, request %b", steps, step_dir, rq_last);
    fail_int("restore", "seek steps", steps, 3);
    fail_int("restore", "seek direction (1 = up)", step_dir, 1);
    fail_int("restore", "track requested by the seek", rq_last[6:0], 3);
    // and back
    steps = 0; step_t0 = 0; step_t1 = 0;
    io_wr(0, 0, 8'h08);
    wait_intrq(100);
    io_rd(0, 0, v);
    sp = step_t1 - step_t0;                // clk between the last two steps
    $display("tb_floppy: restore: %0d steps, %0d clk between steps (want about %0d), track %0d, status %h",
             steps, sp, 3 * edges_per_ms, rq_last[6:0], v);
    fail_int("restore", "steps", steps, 3);
    if (sp < (29 * edges_per_ms / 10) || sp > (31 * edges_per_ms / 10)) begin
        $display("FAIL restore step period %0d clk is not 3 ms (want %0d..%0d)",
                 sp, 29 * edges_per_ms / 10, 31 * edges_per_ms / 10);
        errors = errors + 1;
    end
    fail_int("restore", "track after the restore", rq_last[6:0], 0);
    fail_int("restore", "status busy", v[0], 0);
    fail_int("restore", "status TR00", v[2], 1);
    case_end("restore");
    end

    // ---- poll: the loop of TR-DOS at #3FD5, 51 T: IN A,(#FF) + 47 T ----
    if (run(2)) begin                    // poll
    case_begin;
    waits = 0;
    t0 = edges;
    for (i = 0; i < 64; i = i + 1) begin
        io_rd(1, 0, v);
        repeat (TURBO ? 47 : 47 * 8) @(posedge clk);
    end
    t1 = edges - t0;
    sp = t1 / 64;                          // clk_bus clocks per turn of the loop
    $display("tb_floppy: poll: %0d clocks per turn (want %0d), %0d clocks of WAIT",
             sp, (47 + 5) * 8, waits);
    if (TURBO) begin
        if (sp < ((47 + 5) * 8 * 97) / 100 || sp > ((47 + 5) * 8 * 103) / 100) begin
            $display("FAIL poll turn %0d is not within 3%% of %0d", sp, (47 + 5) * 8);
            errors = errors + 1;
        end
    end
    else if (waits != 0) fail_int("poll", "WAIT clocks at 3.5 MHz", waits, 0);
    case_end("poll");
    end

    // ---- read sector 1 ----
    if (run(3)) begin                    // read_sector
    case_begin;
    do_read(8'h01, 0, TRIES, roK, rn, rbad, rstat);
    $display("tb_floppy: read sector: %0d bytes, %0d wrong, status %h, ok %0d", rn, rbad, rstat, roK);
    fail_int("read_sector", "bytes", rn, 256);
    fail_int("read_sector", "bytes wrong", rbad, 0);
    fail_int("read_sector", "status", rstat, 8'h00);
    case_end("read_sector");
    end

    // ---- write sector 1 ----
    if (run(4)) begin                    // write_sector
    case_begin;
    flux_reset;
    for (i = 0; i < 256; i = i + 1) wbuf[i] = 8'hFF - i * 3;
    wr0 = wr_count;
    do_write(8'h01, wg_n, wg_stat);
    $display("tb_floppy: write sector: %0d bytes by DRQ, status %h, writes seen %0d",
             wg_n, wg_stat, wr_count - wr0);
    fail_int("write_sector", "bytes", wg_n, 256);
    fail_int("write_sector", "status", wg_stat, 8'h00);
    fail_int("write_sector", "wr_tgl", wr_count - wr0, 1);
    begin : wchk
        integer budget;
        budget = edges + 50 * edges_per_ms;
        while (!cap_done && edges < budget) @(posedge clk);
    end
    fail_int("write_sector", "the store captured the sector", cap_done, 1);
    if (cap_done) begin
        for (i = 0; i < 256; i = i + 1)
            if (cap[i] !== wbuf[i]) fail_int("write_sector", "captured byte", cap[i], wbuf[i]);
        // {drive, side, track, C, H, R, N}
        fail_int("write_sector", "wr_info drive",  wr_got[35],    0);
        fail_int("write_sector", "wr_info side",   wr_got[34],    0);
        fail_int("write_sector", "wr_info track",  wr_got[33:27], 0);
        fail_int("write_sector", "wr_info C",      wr_got[26:19], 0);
        fail_int("write_sector", "wr_info H",      wr_got[18:11], 0);
        fail_int("write_sector", "wr_info R",      wr_got[10:3],  1);
        fail_int("write_sector", "wr_info N",      wr_got[2:0],   1);
        // the flux itself, decoded independently
        $display("tb_floppy: written flux: mark %h, %0d words", wmark, wcount);
        fail_int("write_sector", "mark of the written field", wmark, 8'hFB);
        fail_int("write_sector", "words of the written field", wcount, 258);
        for (i = 0; i < 256; i = i + 1)
            if (wgot[i] !== wbuf[i]) fail_int("write_sector", "flux byte", wgot[i], wbuf[i]);
        crc = 16'hFFFF;
        crc = crc_byte(crc, 8'hA1); crc = crc_byte(crc, 8'hA1);
        crc = crc_byte(crc, 8'hA1); crc = crc_byte(crc, 8'hFB);
        for (i = 0; i < 256; i = i + 1) crc = crc_byte(crc, wbuf[i]);
        fail_int("write_sector", "flux CRC hi", {wgot[256], wgot[257]}, crc);
    end

    // A second field, this one with an even CRC low byte: the last channel cell
    // of that byte is a zero, so the model has to count cells with no WD pulse
    // after the last pulse of the field to close the byte at all.
    begin : even_write
        integer k;
        for (k = 0; k < 256; k = k + 1) begin
            for (i = 0; i < 256; i = i + 1) wbuf[i] = 8'h33 + i[7:0] + k[7:0];
            crc = 16'hFFFF;
            crc = crc_byte(crc, 8'hA1);
            crc = crc_byte(crc, 8'hA1);
            crc = crc_byte(crc, 8'hA1);
            crc = crc_byte(crc, 8'hFB);
            for (i = 0; i < 256; i = i + 1) crc = crc_byte(crc, wbuf[i]);
            if (!crc[0]) k = 256;                 // the CRC's low byte is even
        end
        wr0 = wr_count;
        do_write(8'h01, wg_n, wg_stat);
        $display("tb_floppy: write 2 (from %h): %0d bytes, status %h, writes seen %0d, crc %h",
                 wbuf[0], wg_n, wg_stat, wr_count - wr0, crc);
        fail_int("write_sector", "even CRC: bytes", wg_n, 256);
        fail_int("write_sector", "even CRC: status", wg_stat, 8'h00);
        fail_int("write_sector", "even CRC: wr_tgl", wr_count - wr0, 1);
        begin : wchk2
            integer budget;
            budget = edges + 50 * edges_per_ms;
            while (!cap_done && edges < budget) @(posedge clk);
        end
        fail_int("write_sector", "even CRC: captured", cap_done, 1);
        if (cap_done) begin
            for (i = 0; i < 256; i = i + 1)
                if (cap[i] !== wbuf[i]) fail_int("write_sector", "even CRC byte", cap[i], wbuf[i]);
        end
    end
    case_end("write_sector");
    end

    // ---- read after write: the store patches the buffer, as Task 4 will ----
    if (run(5)) begin                    // read_after_write
    case_begin;
    if (wr_count == 0) begin             // run alone: the write of case 4 is the premise
        for (i = 0; i < 256; i = i + 1) wbuf[i] = 8'hFF - i * 3;
        do_write(8'h01, wg_n, wg_stat);
        begin : wprem
            integer budget;
            budget = edges + 50 * edges_per_ms;
            while (!cap_done && edges < budget) @(posedge clk);
        end
        fail_int("read_after_write", "the premise write was captured", cap_done, 1);
    end
    begin : patch
        integer budget;
        // the sector's data and its CRC, recomputed over A1 A1 A1 FB + data
        for (i = 0; i < 256; i = i + 1) patchbuf[i] = cap[i];
        crc = 16'hFFFF;
        crc = crc_byte(crc, 8'hA1); crc = crc_byte(crc, 8'hA1);
        crc = crc_byte(crc, 8'hA1); crc = crc_byte(crc, 8'hFB);
        for (i = 0; i < 256; i = i + 1) crc = crc_byte(crc, cap[i]);
        patchbuf[256] = crc[15:8];
        patchbuf[257] = crc[7:0];
        patchlen = 258;
        budget = edges + 10 * edges_per_ms;
        patch_track(0, data_off);
        while (edges < budget) @(posedge clk);          // let the patch settle
    end
    cap_valid = 1'b1;                    // buffer 0 now holds what the machine wrote
    do_read(8'h01, 0, TRIES, roK, rn, rbad, rstat);
    $display("tb_floppy: read after write: %0d bytes, %0d wrong, status %h, ok %0d",
             rn, rbad, rstat, roK);
    fail_int("read_after_write", "bytes", rn, 256);
    fail_int("read_after_write", "bytes wrong", rbad, 0);
    fail_int("read_after_write", "status", rstat, 8'h00);
    case_end("read_after_write");
    end

    // ---- drive B, and the swap ----
    if (run(6)) begin                    // drive_b and swap
    case_begin;
    io_wr(1, 0, 8'h3D);                    // #FF bits 1:0 = 01: drive B
    io_wr(0, 0, 8'h08);                    // RESTORE loads the head of B
    wait_intrq(100);
    do_read(8'h01, 2, TRIES, roK, rn, rbad, rstat);
    $display("tb_floppy: drive B: %0d bytes, %0d wrong, status %h, ok %0d", rn, rbad, rstat, roK);
    fail_int("drive_b", "B: bytes", rn, 256);
    fail_int("drive_b", "B: bytes wrong", rbad, 0);
    fail_int("drive_b", "B: status", rstat, 8'h00);
    swap = 1'b1;
    io_wr(1, 0, 8'h3C);                    // select A: with the swap that is B
    io_wr(0, 0, 8'h08);
    wait_intrq(100);
    do_read(8'h01, 2, TRIES, roK, rn, rbad, rstat);
    $display("tb_floppy: swap, A selected: %0d bytes, %0d wrong, ok %0d", rn, rbad, roK);
    fail_int("drive_b", "swap: A reads B: bytes", rn, 256);
    fail_int("drive_b", "swap: A reads B: wrong", rbad, 0);
    io_wr(1, 0, 8'h3D);                    // select B: with the swap that is A
    io_wr(0, 0, 8'h08);
    wait_intrq(100);
    do_read(8'h01, 0, TRIES, roK, rn, rbad, rstat);
    $display("tb_floppy: swap, B selected: %0d bytes, %0d wrong, ok %0d", rn, rbad, roK);
    fail_int("drive_b", "swap: B reads A: bytes", rn, 256);
    fail_int("drive_b", "swap: B reads A: wrong", rbad, 0);
    swap = 1'b0;
    io_wr(1, 0, 8'h3C);                    // back to drive A, side 0
    io_wr(0, 0, 8'h08);
    wait_intrq(100);
    case_end("drive_b");
    end

    // ---- side 1 ----
    if (run(7)) begin                    // side1
    case_begin;
    io_wr(1, 0, 8'h2C);                    // #FF bit 4 = 0: FDC_SIDE1 high
    do_read(8'h01, 1, TRIES, roK, rn, rbad, rstat);
    $display("tb_floppy: side 1: %0d bytes, %0d wrong, status %h, ok %0d", rn, rbad, rstat, roK);
    fail_int("side1", "side 1: bytes", rn, 256);
    fail_int("side1", "side 1: bytes wrong", rbad, 0);
    fail_int("side1", "side 1: status", rstat, 8'h00);
    io_wr(1, 0, 8'h3C);                    // side 0 again
    case_end("side1");
    end

    // ---- write protect ----
    if (run(8)) begin                    // wprt
    case_begin;
    for (i = 0; i < 256; i = i + 1) wbuf[i] = 8'h11 * i;
    wprt[0] = 1'b1;
    wr0 = wr_count;
    do_write(8'h01, wg_n, wg_stat);
    $display("tb_floppy: wprt: status %h (write-protect bit 6), writes seen %0d",
             wg_stat, wr_count - wr0);
    fail_int("wprt", "write-protect status bit", wg_stat[6], 1);
    fail_int("wprt", "no write captured", wr_count - wr0, 0);
    wprt[0] = 1'b0;
    case_end("wprt");
    end

    // ---- a corrupt ID CRC ----
    if (run(9)) begin                    // bad_crc
    case_begin;
    patchlen = 1;
    patchbuf[0] = tbytes[id_crc_off] ^ 8'hFF;
    patch_track(0, id_crc_off);            // the ID's CRC no longer matches
    wr0 = wr_count;
    do_read(8'h01, 0, 1, roK, rn, rbad, rstat);   // one attempt: it must fail on its own
    $display("tb_floppy: bad_crc: status %h (RNF bit 4), %0d bytes", rstat, rn);
    fail_int("bad_crc", "the read fails", roK, 0);
    fail_int("bad_crc", "RNF", rstat[4], 1);
    fail_int("bad_crc", "CRC error (the ID was read and did not check)", rstat[3], 1);
    fail_int("bad_crc", "no data", rn, 0);
    fail_int("bad_crc", "no write", wr_count - wr0, 0);
    patchbuf[0] = tbytes[id_crc_off];
    patch_track(0, id_crc_off);            // and restore the track
    case_end("bad_crc");
    end

    // ---- the store has nothing ready, and an answer with the wrong echo ----
    if (run(10)) begin                   // track_not_ready
    case_begin;
    // Nothing here moves the selection or the side: what makes the request new is a
    // track, and that track is what the store then refuses. One command does the move:
    // STEP with SEEK (0x18) takes its target from #7F *and* carries the head-load bit.
    // That bit is load-bearing here: HLD is the chip's own READY (hrdy_fdc ties
    // .READY(motor)), a 0x10 SEEK without it leaves HLD down when it ends, and every
    // command issued after that ends at once, not-ready - which is what this case did
    // before, three reads of 0 ms and a status of 80.
    do_read(8'h01, 0, TRIES, roK, rn, rbad, rstat);
    fail_int("track_not_ready", "the track reads before the request", roK, 1);
    store_rdy = 1'b0;
    io_wr(0, 3, 8'd1);                     // #7F: the track to seek to
    io_wr(0, 0, 8'h18);                    // STEP with SEEK, head load included
    wait_intrq(100);
    wait_index(300);                       // the payload is asked for at an index
    fail_int("track_not_ready", "the pending request is track 1", rq_last[6:0], 1);
    fail_int("track_not_ready", "and it is still drive A, side 0", rq_last[8:7], 2'b00);
    idx0 = idx_pulses;
    do_read(8'h01, 0, 1, roK, rn, rbad, rstat);
    $display("tb_floppy: not ready: status %h (RNF bit 4), %0d bytes, %0d index pulses",
             rstat, rn, idx_pulses - idx0);
    fail_int("track_not_ready", "the read fails", roK, 0);
    fail_int("track_not_ready", "RNF", rstat[4], 1);
    fail_int("track_not_ready", "no CRC error (nothing was ever read)", rstat[3], 0);
    fail_int("track_not_ready", "index still pulses", (idx_pulses - idx0) >= 2, 1);
    // ready=1 in an answer that is not for this request. The request goes out at an
    // index, and an index only passes while the chip holds the head loaded, so the
    // re-ask, the bad answer and the index at which a drive that had taken it would
    // arm all happen inside one read command. The read is given its full budget: a
    // read of filler ends by itself after the six-turn search, and a budget cut short
    // would abandon a command that is still running and let the next do_read issue its
    // command on top of it.
    store_rdy = 1'b1;
    ack_bad   = 1'b1;
    no_index  = 1'b1;
    do_read(8'h01, 0, 1, roK, rn, rbad, rstat);
    no_index  = 1'b0;
    $display("tb_floppy: a bad echo: %0d bytes, status %h", rn, rstat);
    fail_int("track_not_ready", "a wrong echo does not switch the stream", rn, 0);
    // What the wrong echo has to leave behind is a drive that is still reading
    // filler: `active` low, the flux the 4Eh idle pattern, and no buffer handed
    // over (checked above by the byte count of the read that just ran).
    fail_int("track_not_ready", "and the drive is not streaming", u_drive.active, 1'b0);
    // The same request, answered properly: the next index takes the track and the
    // read after it is the sector. The SEEK left the chip's TRACK register (#3F, port 1)
    // at 1, and that register is what an ID's C is compared with; the buffer the store
    // serves for drive A side 0 carries C=0. So the track register goes back to 0 first.
    // (#7F is the data register, which the SEEK used as its target; writing it does not
    // change the compare.) The head stays where it is. With the register left at 1 every
    // search after the switch ends record-not-found, which is the chip being right about
    // a sector the buffer does not hold.
    io_wr(0, 1, 8'd0);
    ack_bad = 1'b0;
    do_read(8'h01, 0, TRIES, roK, rn, rbad, rstat);
    $display("tb_floppy: not ready: answered for the right request: %0d bytes, %0d wrong, ok %0d",
             rn, rbad, roK);
    fail_int("track_not_ready", "ready for the right request: bytes", rn, 256);
    fail_int("track_not_ready", "ready for the right request: wrong", rbad, 0);
    io_wr(0, 3, 8'd0);                     // back to track 0 for the cases below
    io_wr(0, 0, 8'h18);                    // again with the head load, so HLD stays up
    wait_intrq(100);
    spun_up = 1'b0;                        // the next case's first command has to
    case_end("track_not_ready");
    end

    // ---- the side flips while the disk is under the head ----
    if (run(12)) begin                   // side_flip
    case_begin;
    // Side 0 reads. Then the side flips and the store does NOT answer (ack_stall):
    // the real store rebuilds ONE buffer per drive in place, so until it has
    // answered, port B still serves the bytes of the side that was left - which
    // here is a good sector with a good CRC and H=0 in its ID, i.e. a read that
    // ends "no error" with the other side's data. The read is issued mid-revolution
    // (no_index, straight after the flip) and one try only: what may come back is nothing, never that sector.
    io_wr(1, 0, 8'h3C);                    // drive A, side 0
    do_read(8'h01, 0, TRIES, roK, rn, rbad, rstat);
    fail_int("side_flip", "side 0 reads first", roK, 1);
    ack_stall = 1'b1;
    // The flip comes right after an index: the sector is then still ahead of the
    // head for the rest of the turn, which is the window a drive that kept reading
    // its old buffer would serve it in (a flip after the sector has passed would be
    // saved by the next index, with or without the fix).
    wait_index(300);
    io_wr(1, 0, 8'h2C);                    // side 1: the request goes out, no answer
    no_index = 1'b1;
    do_read(8'h01, 1, 1, roK, rn, rbad, rstat);
    no_index = 1'b0;
    $display("tb_floppy: side flip, store silent: %0d bytes, %0d wrong, status %h, ok %0d", rn, rbad, rstat, roK);
    fail_int("side_flip", "no byte of the side that was left", rn, 0);
    fail_int("side_flip", "the read ends record-not-found", rstat[4], 1);
    ack_stall = 1'b0;                      // the store answers: side 1 is served
    repeat (100) @(posedge clk);
    do_read(8'h01, 1, TRIES, roK, rn, rbad, rstat);
    $display("tb_floppy: side flip, answered: %0d bytes, %0d wrong, status %h, ok %0d", rn, rbad, rstat, roK);
    fail_int("side_flip", "after the answer side 1 reads", roK, 1);
    fail_int("side_flip", "and it is side 1's data", rbad, 0);
    io_wr(1, 0, 8'h3C);                    // side 0 for what follows
    case_end("side_flip");
    end

    // ---- steps and reports with nobody selected ----
    if (run(13)) begin                   // no_select
    case_begin;
    // hrdy_fdc decodes #FF bits 1:0 as 00 -> A and 01 -> B and gates both lines
    // with the motor (its head-load output), so the lines are down in two states:
    //  (a) motor down: between commands. A SEEK without head load steps in this
    //      state (measured: its pulses come with FDC_DS == 00), and the step belongs
    //      to the held drive, never to A.
    //  (b) motor up, bits 1:0 = 1x: drive C or D, which this machine does not have.
    //      Nothing streams and no head moves.
    spun_up = 1'b0;
    io_wr(1, 0, 8'h3D);                    // drive B
    do_read(8'h01, 2, TRIES, roK, rn, rbad, rstat);   // B's buffer reads back
    fail_int("no_select", "B reads first", roK, 1);
    spun_up = 1'b1;                        // the read loaded B's head
    io_wr(0, 3, 8'd5);                     // #7F: the track to seek to
    io_wr(0, 0, 8'h10);                    // SEEK without head load: HLD drops at its end
    wait_intrq(100);
    fail_int("no_select", "the head is unloaded after a SEEK without head load", FDC_MOTOR, 0);
    // (a) the next SEEK steps with the motor and both select lines down
    nods0 = steps_nods;
    trk0  = u_drive.trk_b;
    reqa0 = req_a;
    io_wr(0, 3, 8'd8);
    io_wr(0, 0, 8'h10);
    wait_intrq(100);
    $display("tb_floppy: no select (motor down): %0d step pulses, B at %0d (was %0d), A at %0d, %0d requests for A",
             steps_nods - nods0, u_drive.trk_b, trk0, u_drive.trk_a, req_a - reqa0);
    fail_int("no_select", "the steps really arrived with the select lines down", steps_nods - nods0, 3);
    fail_int("no_select", "the held drive took them", u_drive.trk_b - trk0, 3);
    fail_int("no_select", "the step never lands on drive A", u_drive.trk_a, 0);
    fail_int("no_select", "no request named the drive nobody chose", req_a - reqa0, 0);
    // (b) head load (target = where B is, no step), then drive C
    io_wr(0, 3, 8'd8);
    io_wr(0, 0, 8'h18);
    wait_intrq(100);
    fail_int("no_select", "the head is loaded", FDC_MOTOR, 1);
    io_wr(1, 0, 8'h3E);                    // bits 1:0 = 10: drive C
    repeat (50) @(posedge clk);
    cd0   = steps_cd;
    trk0  = u_drive.trk_b;
    idx0  = idx_pulses;
    flux0 = flux_pulses;
    req0  = req_count;
    repeat (3) begin
        io_wr(0, 0, 8'h28);                // STEP, head load included
        wait_intrq(100);
    end
    repeat (250 * edges_per_ms) @(posedge clk);   // more than a turn of the disk
    $display("tb_floppy: no select (drive C): %0d step pulses, B at %0d (was %0d), A at %0d, %0d index, %0d flux, %0d requests",
             steps_cd - cd0, u_drive.trk_b, trk0, u_drive.trk_a, idx_pulses - idx0,
             flux_pulses - flux0, req_count - req0);
    fail_int("no_select", "the steps really arrived with drive C selected", steps_cd - cd0, 3);
    fail_int("no_select", "B's head did not move", u_drive.trk_b, trk0);
    fail_int("no_select", "A's head did not move", u_drive.trk_a, 0);
    fail_int("no_select", "nothing streams: no index", idx_pulses - idx0, 0);
    fail_int("no_select", "nothing streams: no flux", flux_pulses - flux0, 0);
    fail_int("no_select", "no request", req_count - req0, 0);
    io_wr(1, 0, 8'h3D);                    // select B again
    idx0 = idx_pulses;
    wait_index(300);
    fail_int("no_select", "B turns again", idx_pulses - idx0 >= 1, 1);
    fail_int("no_select", "B kept its head position", u_drive.trk_b, trk0);
    io_wr(0, 3, 8'd0);                     // B back to track 0 (the chip's own register
    io_wr(0, 0, 8'h18);                    // is at 11 after the three steps: it clamps)
    wait_intrq(100);
    fail_int("no_select", "B is back at track 0", u_drive.trk_b, 0);
    io_wr(1, 0, 8'h3C);                    // and A selected for what follows
    spun_up = 1'b0;                        // whose first command loads the head
    case_end("no_select");
    end

    // ---- a second field while one waits for its answer ----
    if (run(14)) begin                   // pend_drop
    case_begin;
    wr_ack_stall = 1'b1;                   // the store keeps the answer to itself
    for (i = 0; i < 256; i = i + 1) wbuf[i] = 8'h11 + i[7:0];
    wr0 = wr_count;
    do_write(8'h01, wg_n, wg_stat);
    fail_int("pend_drop", "the first field is offered", wr_count - wr0, 1);
    for (i = 0; i < 256; i = i + 1) wbuf[i] = 8'h12 + i[7:0];
    do_write(8'h01, wg_n, wg_stat);
    fail_int("pend_drop", "a field with one pending is dropped", wr_count - wr0, 1);
    wr_ack_stall = 1'b0;                   // the store answers
    repeat (10) @(posedge clk);
    for (i = 0; i < 256; i = i + 1) wbuf[i] = 8'h13 + i[7:0];
    do_write(8'h01, wg_n, wg_stat);
    fail_int("pend_drop", "after the answer a new field is offered", wr_count - wr0, 2);
    case_end("pend_drop");
    end

    // ---- motor off ----
    if (run(11)) begin                   // no_motor
    case_begin;
    io_wr(1, 0, 8'h00);                    // /MR low: HLD drops, the motor stops
    repeat (500) @(posedge clk);
    idx0 = idx_pulses; flux0 = flux_pulses; req0 = req_count;
    repeat (20 * edges_per_ms) @(posedge clk);   // 20 ms: a tenth of a turn
    $display("tb_floppy: no motor: %0d index, %0d flux pulses in 20 ms",
             idx_pulses - idx0, flux_pulses - flux0);
    fail_int("no_motor", "no index", idx_pulses - idx0, 0);
    fail_int("no_motor", "no flux", flux_pulses - flux0, 0);
    case_end("no_motor");
    end

    $display("tb_floppy: DS80=%0d TURBO=%0d cell=%0d/%0d: %0d errors, %0d writes, %0d requests",
             DS80, TURBO, CELL_NUM, CELL_DEN, errors, wr_count, req_count);
    if (errors == 0) $display("tb_floppy: PASS");
    else             $display("tb_floppy: FAIL %0d checks failed", errors);
    $finish;
end

// edge-counted watchdog (no $time arithmetic: unreliable in deep Icarus runs)
integer watchdog;
initial begin
    watchdog = 0;
    forever begin
        @(posedge clk);
        watchdog = watchdog + 1;
        if (watchdog > WATCHDOG) begin
            $display("tb_floppy: FAIL global timeout");
            $finish;
        end
    end
end

endmodule
