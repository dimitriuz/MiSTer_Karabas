// mcu_emu.sv - the MiSTer-side counterpart of the Karabas board's RP2040:
// the firmware's half of the SPI link (karabas-go-firmware docs/protocol.md)
// behind upstream's unmodified kg_mcu.
//
// clk is the MiSTer CLK_50M (the hps_io domain), reset the power-on reset
// only: the OSD Reset item and kb_reset travel as switch pulses over the
// link, not through this reset.
//
// Start sequence (protocol.md section 3, without CAPS, the OSD font, the
// build ids and the RTC registers): once the machine signals mem_ready
// (SDRAM controller initialised, synchronised here with two flops), and
// when an hps_io boot.rom download (ioctl_download, index 0) starts, send
// INIT_START, HW_SETUP board = Go, ROMLOADER on; every ioctl byte as the
// ROMBANK frames of the address bytes
// that changed (0..2 = bits 15..8, 23..16, 31..24) plus the ROMDATA frame at
// the byte's boot.rom address, ioctl_wait held while its frames go out and
// from the clock ioctl_download rises to S_STRM - there it drops again
// while no byte is pending, so a source that strobes only on the low can
// start it (a byte strobed in the held window is latched, none is lost);
// ROMLOADER off, all
// 15 switch frames (indices 0-8 and 10-15; 9 is the HDF slot), the RTC
// registers (256 CMD_RTC frames: the time registers from hps_io's BCD RTC,
// 01/03/05/0A/0B/0C/0D, then FF through 0xFF - persistent CMOS is stage 4's
// storage, so this load starts it filled), the cleared
// keyboard (CMD_KBD 0..6 = 0) and INIT_DONE. Bytes of another ioctl_index
// are ignored and never raise ioctl_wait. A second download repeats the
// whole start sequence.
//
// Run loop after INIT_DONE, in priority order per idle slot: a switch value
// that differs from the last one sent (all indices compared every slot),
// the keyboard report on kb_changed (seven CMD_KBD frames; a change arriving
// mid-burst is answered with one fresh complete report of the latest one),
// the mouse report on a toggle of ps2_mouse[24] (four CMD_MOUSE frames; X, Y
// and Z are deltas, so a report arriving while one still waits adds to it,
// saturating at +-127; the wheel is negated to the board MCU's HID sense,
// up positive, where mousedev's ImPS/2 wheel is negative for up), the
// joysticks (four CMD_JOY frames when either
// 13-bit word changes), the RTC time registers (seven CMD_RTC frames every
// RTC_CLKS and right after the first toggle of RTC[64], in BCD or binary as
// register B's DM bit last said; the bytes are bcd_clock's, which loads
// hps_io's RTC on every RTC[64] toggle and ticks it itself in between), the
// GS Reset / NMI / Reset trigger pulses
// (value 1, then 0 after TRIGGER_CLKS), one queued byte of the machine's
// USB-RS232 port (uart_rx_*: one CMD_UART frame each, taken after the RTC
// burst so it can never split a report burst), and one CMD_NOPE poll every
// NOP_CLKS when idle. A report burst is never reordered:
// its frames keep their protocol order even when a higher-priority source
// runs between two of them. Replies the core shifted out
// (rx of each frame) whose command is not NOPE go to last_reply/reply_valid
// for the later stages; an RTC reply for register B (the CPU clearing or
// setting BCD mode) switches the time frames between BCD and binary.
//
// The USB-RS232 byte channel (stage 5, uart_route at the other end): a
// CMD_UART reply (8'hFC) whose addr is 0 is a byte the machine sent, so it
// goes out as uart_tx_data with a one-clock uart_tx_stb; addrs 01 and 02
// (kg_mcu_uart's dll, dlm) and 03 (the tsconf rs232 mode byte) are consumed
// and ignored, the channel runs at the tty's speed. A byte for the machine
// (uart_rx_stb, one clock) is queued with this module's idx counter and sent
// as one CMD_UART frame per byte, only in the run loop and never between two
// frames of a report burst. After reset the queue is empty - a byte pending
// at a reset is dropped with it - and the counter starts again at 1.
//
// Why starting at 1 cannot be mistaken for a byte the machine already read,
// nor skip one, across a reset (checked against upstream, which is not edited
// here):
//   - modules/rtl/mcu/kg_mcu_uart.v:23,39-43 - uart_rx_idx has no reset at
//     all: an initial value of 0 and an assignment from rx_addr on a CMD_UART
//     frame. A core reset (the machine's RESET, the OSD Reset item, a NMI)
//     leaves it where it is.
//   - src/rtl/uart/zifi_usb.vhd:141,254-263 - the watcher,
//     prev_usb_uart_rx_idx, is likewise only an initial value of zero: the
//     process that compares it is sensitive to CLK alone, and RESET - which
//     that file's other processes do use (271, 359) - never touches it. Its RX
//     FIFO is cleared by a CPU command (rs232_fifo_rx_clr_req), not by RESET
//     either.
//   So after any core reset the machine still compares against the last idx it
//   took and this counter keeps running with it: every accepted byte carries an
//   idx different from the previous one (a dropped byte consumes none), so it
//   is always taken; and a byte still queued across a reset is a byte the
//   machine never received, so delivering it afterwards is right and not a
//   phantom. The only thing that zeroes the machine's side is the configuration
//   of the FPGA, and this module's reset (por_reset in the top) is asserted
//   exactly then - so the two start aligned at 0 and 1 and never drift apart.
//   The bench proves the taking, not just the sending: its receive log watches
//   the real upstream kg_mcu_uart's own MCU_UART_RX_IDX/RX_DATA pair, so every
//   frame in tb_mcu_emu.sv (uart_rx_send and the four cases appended after it)
//   is only logged once the machine's own idx comparison has accepted it.
`default_nettype none

module mcu_emu #(
    parameter integer TRIGGER_CLKS = 5000000,  // 100 ms at clk_sys = 50 MHz
    parameter integer NOP_CLKS     = 5000,     // a NOP poll every 100 us when idle
    parameter integer RTC_CLKS     = 25000000, // an RTC refresh every 500 ms
    parameter integer SEC_CLKS     = 50000000  // one RTC second at 50 MHz
) (
    input  wire         clk,
    input  wire         reset,

    // boot.rom download (hps_io ioctl, index 0)
    input  wire         ioctl_download,
    input  wire [15:0]  ioctl_index,
    input  wire         ioctl_wr,
    input  wire [26:0]  ioctl_addr,
    input  wire [7:0]   ioctl_dout,
    output reg          ioctl_wait,

    // OSD
    input  wire [127:0] status,
    input  wire         osd_reset,   // level: the OSD Reset item or the button

    // keyboard (ps2_hid)
    input  wire [55:0]  kb_report,
    input  wire         kb_changed,

    // the other inputs the board's MCU sends: hps_io's RTC (BCD time, bit 64
    // toggles on an HPS update), the PS/2 mouse (bit 24 toggles per report)
    // and the two MiSTer joystick words
    input  wire [64:0]  rtc,
    input  wire [24:0]  ps2_mouse,
    input  wire [15:0]  ps2_mouse_ext,
    input  wire [31:0]  joy0,
    input  wire [31:0]  joy1,

    // the machine's SDRAM controller ready (sdram_nowait through profi;
    // async to clk, synchronised below)
    input  wire         mem_ready,

    // the MiSTer disk mounts have settled (clk domain): the machine must not
    // probe the card or the IDE images while a mount is still landing, so
    // the start is held until this is 1 (see Karabas_Profi.sv's settle
    // counter). Not a memory condition: it only delays the start sequence.
    input  wire         mounts_settled,

    // link to profi
    output wire         spi_cs_n,
    output wire         spi_sck,
    output wire         spi_mosi,
    input  wire         spi_miso,

    // the machine's USB-RS232 byte channel (stage 5): uart_rx_* is one byte
    // for the machine, uart_tx_* a byte the machine sent; both are one-clock
    // strobes in clk
    input  wire [7:0] uart_rx_data,
    input  wire       uart_rx_stb,
    output reg  [7:0] uart_tx_data,
    output reg        uart_tx_stb,

    output reg  [23:0]  last_reply,  // for later stages
    output reg          reply_valid
);

localparam [7:0] C_KBD     = 8'h01,
                 C_MOUSE   = 8'h02,
                 C_JOY     = 8'h03,
                 C_SW      = 8'h05,
                 C_BANK    = 8'h06,
                 C_DATA    = 8'h07,
                 C_LOADER  = 8'h08,
                 C_HWSET   = 8'hF9,
                 C_RTC     = 8'hFA,
                 C_ISTART  = 8'hFD,
                 C_IDONE   = 8'hFE,
                 C_NOPE    = 8'hFF,
                 C_UART    = 8'hFC;   // kg_mcu_cmds.vh CMD_UART

`include "osd_items.svh"

localparam [2:0] S_WAIT = 3'd0, S_SEQ = 3'd1, S_STRM = 3'd2,
                 S_SWALL = 3'd3, S_RTC = 3'd4, S_KB = 3'd5, S_RUN = 3'd6;

localparam [4:0] A_NONE = 5'd0, A_START = 5'd1, A_SEQ = 5'd2,
                 A_BANK = 5'd3, A_DATA  = 5'd4, A_LOADER_OFF = 5'd5,
                 A_SW   = 5'd6, A_KB0   = 5'd7, A_KB = 5'd8,
                 A_DONE = 5'd9, A_TRIG_ON = 5'd10, A_TRIG_OFF = 5'd11,
                 A_NOP  = 5'd12, A_RTCS = 5'd13, A_MOUSE = 5'd14,
                 A_JOY  = 5'd15, A_RTCT = 5'd16, A_UART = 5'd17;

reg [2:0] st;

// ---------------- the SPI sender ----------------

reg         tx_start;
reg  [23:0] tx_word;
wire        tx_busy;
wire [23:0] rx_word;
wire        rx_valid;

mcu_spi_master #(
    .DIV (4),    // SCK = clk_sys / 4 = 12.5 MHz (the firmware drives 16)
    .GAP (32)    // CS high >= 640 ns between frames
) u_spi (
    .clk       (clk),
    .reset     (reset),
    .tx        (tx_word),
    .start     (tx_start),
    .busy      (tx_busy),
    .rx        (rx_word),
    .rx_valid  (rx_valid),
    .spi_cs_n  (spi_cs_n),
    .spi_sck   (spi_sck),
    .spi_mosi  (spi_mosi),
    .spi_miso  (spi_miso)
);

reg waiting;   // a frame went out, its rx_valid has not come back

// ---------------- the mem_ready gate ----------------

// mem_ready is async (clk_mem domain); two flops into clk. The start
// sequence does not begin before it is 1: while it is 0 the arbiter fires
// nothing, and the ioctl_wait raise below still holds the download back.
reg [1:0] mr_sync;
always @(posedge clk)
    mr_sync <= reset ? 2'b00 : {mr_sync[0], mem_ready};
wire mr_ok = mr_sync[1] & mounts_settled;

// ---------------- boot.rom stream ----------------

reg [1:0]  seq_i;            // 0: HW_SETUP, 1: ROMLOADER on
reg [31:0] cur_a;            // boot.rom address of the byte in flight
reg [7:0]  cur_d;
reg        byte_pend;
reg [7:0]  bank_sent [0:2];  // frame 06 i data last sent for byte i

// the boot.rom map (Global Constraints): gs105b.rom moves to 0x80000000
wire [31:0] o32   = {5'd0, ioctl_addr};
wire [31:0] rom_a = (o32 < 32'h00050000) ? (32'h00100000 + o32)
                                         : (32'h80000000 + (o32 - 32'h00050000));
wire [7:0] bank0 = cur_a[15:8];
wire [7:0] bank1 = cur_a[23:16];
wire [7:0] bank2 = cur_a[31:24];

// ---------------- OSD switches, keyboard, triggers ----------------

reg [7:0] sent_val [0:15];   // last CMD_SWITCHES value sent per index
reg [3:0] sw_i;              // start sequence: the index being sent

reg        kb_pend;              // a report burst is in flight
reg        kb_again;             // the report changed during the burst
reg [55:0] kb_hold, kb_snap;     // newest report; the frozen burst content
reg [2:0]  kb_i;

// bit 0: Reset (frame index 14), 1: GS Reset (12), 2: NMI (13)
wire [2:0] trig_bit = {status[20], status[19], osd_reset};
reg [2:0]  trig_prev, trig_pend, trig_arm;
reg [31:0] trig_t [0:2];

reg [31:0] nop_t;

// trigger bit t -> the CMD_SWITCHES index of the trigger
function [7:0] trig_index;
    input integer tt;
    begin
        trig_index = (tt == 0) ? 8'd14 : (8'd11 + tt[7:0]);  // 1 -> 12, 2 -> 13
    end
endfunction

// ---------------- mouse, joysticks and RTC ----------------

// mouse: a report's deltas accumulate while it waits for the link, and the
// burst reads the latched values, so a new report never blends into one
// already going out. Y is negated because PS/2 has up positive and the
// board MCU's USB HID has down positive. The wheel is negated too:
// mousedev's ImPS/2 wheel is negative for up while the board MCU's USB HID
// wheel is positive for up, and profi adds the delta as it is.
wire signed [10:0] ms_dx = {{3{ps2_mouse[4]}}, ps2_mouse[15:8]};
wire signed [10:0] ms_dy = -{{3{ps2_mouse[5]}}, ps2_mouse[23:16]};
wire signed [10:0] ms_dz = -{{3{ps2_mouse_ext[7]}}, ps2_mouse_ext[7:0]};
reg signed [10:0]  acc_dx, acc_dy, acc_dz;
reg [2:0]  acc_btn;              // newest buttons of the pending report
reg        acc_any;              // a report waits for the link
reg        ms_prev;              // ps2_mouse[24] as last sampled
reg        ms_go;                // the four frames are going out
reg [1:0]  ms_i;
reg [7:0]  ms_ly, ms_lz;         // the burst's Y, Z (latched at its start)
reg [2:0]  ms_lb;                // the burst's buttons

// saturate an accumulated delta to the byte the firmware stores
function signed [10:0] clamp7;
    input signed [10:0] v;
    begin
        clamp7 = (v > 11'sd127)  ? 11'sd127 :
                 (v < -11'sd127) ? -11'sd127 : v;
    end
endfunction

// the Karabas 13-bit joystick word of a MiSTer joystick_n: bit 0 connected,
// 1 up, 2 down, 3 left, 4 right, 5 start, 6 A, 7 B, 8 C, 9 X, 10 Y, 11 Z,
// 12 mode (MiSTer: 0 right, 1 left, 2 down, 3 up, 4 A .. 9 Z, 10 Start,
// 11 Mode)
function [12:0] joy_word;
    input [31:0] j;
    begin
        joy_word = {j[11], j[9], j[8], j[7], j[6], j[5], j[4],
                    j[10], j[0], j[1], j[2], j[3], 1'b1};
    end
endfunction

wire [12:0] joy_w0 = joy_word(joy0);
wire [12:0] joy_w1 = joy_word(joy1);
reg [12:0] joy_sent0, joy_sent1; // the words last sent
reg [12:0] jb_l, jb_r;           // the burst's words
reg        jy_go;
reg [1:0]  jy_i;

// RTC: hps_io's BCD time bytes, loaded into bcd_clock and ticked there
// between the HPS updates. Some of them are converted when the machine
// cleared BCD mode.
wire [55:0] clk_now;

bcd_clock #(
    .SEC_CLKS (SEC_CLKS)
) u_bcd_clock (
    .clk   (clk),
    .reset (reset),
    .rtc   (rtc),
    .now   (clk_now)
);

wire [7:0] rt_s  = clk_now[7:0];
wire [7:0] rt_m  = clk_now[15:8];
wire [7:0] rt_h  = clk_now[23:16];
wire [7:0] rt_d  = clk_now[31:24];
wire [7:0] rt_mo = clk_now[39:32];
wire [7:0] rt_y  = clk_now[47:40];
wire [7:0] rt_wd = clk_now[55:48];

function [7:0] rt_norm;
    input [7:0] b;
    input       bcd;
    begin
        rt_norm = bcd ? b : ({4'd0, b[3:0]} + {4'd0, b[7:4]} * 8'd10);
    end
endfunction

// the seven time registers in burst order: sec, min, hour, weekday, date,
// month, year
wire [55:0] rt_now = {rt_norm(rt_y, is_bcd),  rt_norm(rt_mo, is_bcd),
                      rt_norm(rt_d, is_bcd),  rt_norm(rt_wd, is_bcd),
                      rt_norm(rt_h, is_bcd),  rt_norm(rt_m, is_bcd),
                      rt_norm(rt_s, is_bcd)};

// time byte k -> its MC146818A register (00, 02, 04, 06, 07, 08, 09)
function [7:0] rt_taddr;
    input [2:0] k;
    begin
        rt_taddr = (k < 3'd3) ? {4'd0, k, 1'b0} : ({5'd0, k} + 8'd3);
    end
endfunction

// the control registers of the start sequence (01..0D)
function [7:0] rt_reg_addr;
    input [7:0] k;
    begin
        case (k)
            8'd7:  rt_reg_addr = 8'h01;
            8'd8:  rt_reg_addr = 8'h03;
            8'd9:  rt_reg_addr = 8'h05;
            8'd10: rt_reg_addr = 8'h0A;
            8'd11: rt_reg_addr = 8'h0B;
            8'd12: rt_reg_addr = 8'h0C;
            default: rt_reg_addr = 8'h0D;
        endcase
    end
endfunction

function [7:0] rt_reg_data;
    input [7:0] k;
    input       bcd;
    begin
        case (k)
            8'd10: rt_reg_data = 8'h26;                 // century 20
            8'd11: rt_reg_data = bcd ? 8'h02 : 8'h06;   // DM, 24 h
            8'd13: rt_reg_data = 8'h80;                 // valid RAM/time
            default: rt_reg_data = 8'h00;
        endcase
    end
endfunction

reg [55:0] rt_time;              // the time bytes of the burst in flight
reg [2:0]  rt_i;
reg        rt_go;
reg        rt_pend;
reg [31:0] rt_t;                 // the RTC_CLKS counter of the run loop
reg        rt64_prev;
reg        rt_first;             // the first RTC[64] toggle still to come
reg        is_bcd;               // register B's DM bit: 1 = BCD
reg [7:0]  rtc_si;               // start sequence: the RTC frame index

// The arbiter's decision of one clock: which frame fires, with what word, from
// which source. Declared above the byte queue because the queue's push has to
// see its pop, and the pop is the arbiter firing a CMD_UART frame.
reg        fire;
reg [23:0] fword;
reg [4:0]  faction;

// ---------------- the USB-RS232 byte queue ----------------

// uart_rx_stb is one clock and the link owns the slot most of the time (a
// frame is ~132 clk, and a report burst holds it for seven of them), so the
// byte is latched here with the idx it has to carry and goes out when a slot
// is free. Eight entries: at 115200 baud that is 0.7 ms of backlog, and a
// frame is nine times shorter than one byte, so the queue cannot empty while
// bytes are arriving. A byte that finds it full is DROPPED - the newest, as
// uart_route's TX rule - and consumes no idx, unless a pop fires in this very
// clock (ur_push below), so every frame that does go out carries an idx
// different from the previous one, which is all kg_mcu_uart watches.
reg [15:0] ur_ram [0:7];      // {idx, byte}
reg [3:0]  ur_cnt;            // entries in the queue
reg [2:0]  ur_wr, ur_rd;
reg [7:0]  ur_idx;            // the idx the next accepted byte gets (1 first)
wire       ur_full   = (ur_cnt == 4'd8);
wire       ur_empty  = (ur_cnt == 4'd0);
// this edge takes the head byte out of the USB queue: the frame the arbiter
// picked is carrying it
wire ur_pop = fire && (faction == A_UART);
// A full queue still takes a byte when this very clock pops the head: the
// frame being fired reads ur_ram[ur_rd] combinationally, so it carries the old
// byte, and the write lands in the slot that just emptied (full means
// ur_wr == ur_rd) in time for the arbiter's next decision. Refusing the byte
// there loses one on every full-with-pop clock of a saturated link;
// uart_rx_push_with_freeing_pop in tb_mcu_emu.sv watches exactly that byte.
wire       ur_push   = uart_rx_stb && (!ur_full || ur_pop);
wire [7:0] ur_head   = ur_ram[ur_rd][15:8];    // the frame's idx
wire [7:0] ur_head_d = ur_ram[ur_rd][7:0];     // the frame's byte

// ---------------- the frame arbiter ----------------

integer cv, tv;                  // the arbiter's loop indices
integer iv;                      // the clocked block's loop index
integer sw_target, trig_target;

reg [1:0]  bank_pick;

// this edge fires the mouse report's first frame: a report sampled on the
// same edge starts from an empty accumulator, not from the deltas that are
// already on their way
wire ms_take = fire && faction == A_MOUSE && ms_i == 2'd0;

always @(*) begin
    fire        = 1'b0;
    fword       = {C_NOPE, 8'h00, 8'h00};
    faction     = A_NONE;
    bank_pick   = 2'd0;
    sw_target   = -1;
    trig_target = -1;
    if (!waiting && !reset) begin
        case (st)
            S_WAIT:
                if (mr_ok && ioctl_download && ioctl_index == 16'd0) begin
                    fword   = {C_ISTART, 8'h00, 8'h00};
                    faction = A_START;
                end
            S_SEQ: begin
                fword   = (seq_i == 2'd0) ? {C_HWSET, 8'h00, 8'h01}
                                          : {C_LOADER, 8'h00, 8'h01};
                faction = A_SEQ;
            end
            S_STRM:
                if (byte_pend) begin
                    if (bank0 != bank_sent[0]) begin
                        fword = {C_BANK, 8'h00, bank0}; faction = A_BANK;
                    end else if (bank1 != bank_sent[1]) begin
                        fword = {C_BANK, 8'h01, bank1}; faction = A_BANK;
                        bank_pick = 2'd1;
                    end else if (bank2 != bank_sent[2]) begin
                        fword = {C_BANK, 8'h02, bank2}; faction = A_BANK;
                        bank_pick = 2'd2;
                    end else begin
                        fword = {C_DATA, cur_a[7:0], cur_d}; faction = A_DATA;
                    end
                end else if (!ioctl_download) begin
                    fword   = {C_LOADER, 8'h00, 8'h00};
                    faction = A_LOADER_OFF;
                end
            S_SWALL: begin
                sw_target = sw_i;
                fword     = {C_SW, {4'd0, sw_i}, osd_value(sw_i, status)};
                faction   = A_SW;
            end
            S_RTC: begin
                // the 256 RTC frames of the start sequence: time registers,
                // the control registers, then FF through 0xFF
                if (rtc_si < 8'd7)
                    fword = {C_RTC, rt_taddr(rtc_si[2:0]),
                             rt_time[rtc_si[2:0] * 8 +: 8]};
                else if (rtc_si < 8'd14)
                    fword = {C_RTC, rt_reg_addr(rtc_si),
                             rt_reg_data(rtc_si, is_bcd)};
                else
                    fword = {C_RTC, rtc_si, 8'hFF};
                faction = A_RTCS;
            end
            S_KB:
                if (kb_i <= 3'd6) begin
                    fword   = {C_KBD, {5'd0, kb_i}, 8'h00};
                    faction = A_KB0;
                end else begin
                    fword   = {C_IDONE, 8'h00, 8'h00};
                    faction = A_DONE;
                end
            S_RUN: begin
                if (mr_ok && ioctl_download && ioctl_index == 16'd0) begin
                    // a second download: repeat the start sequence
                    fword   = {C_ISTART, 8'h00, 8'h00};
                    faction = A_START;
                end else begin
                    // 1. a switch value that differs from the last sent
                    //    (0-8, 10-11, 15; 9 is the HDF slot, 12-14 the
                    //    triggers, whose value is always 0)
                    for (cv = 0; cv <= 15; cv = cv + 1)
                        if (cv != 9 && cv != 12 && cv != 13 && cv != 14 &&
                            osd_value(cv, status) != sent_val[cv])
                            sw_target = cv;
                    if (sw_target >= 0) begin
                        fword   = {C_SW, sw_target[7:0],
                                   osd_value(sw_target, status)};
                        faction = A_SW;
                    end else if (kb_pend) begin
                        // 2. the keyboard report, seven frames
                        fword   = {C_KBD, {5'd0, kb_i}, kb_snap[kb_i * 8 +: 8]};
                        faction = A_KB;
                    end else if (acc_any || ms_go) begin
                        // 3. the mouse report: X, Y, Z, then the buttons
                        //    that end it; X of the burst is the pending sum
                        fword   = {C_MOUSE, {6'd0, ms_i},
                                   (ms_i == 2'd0) ? acc_dx[7:0] :
                                   (ms_i == 2'd1) ? ms_ly :
                                   (ms_i == 2'd2) ? ms_lz :
                                                    {5'd0, ms_lb}};
                        faction = A_MOUSE;
                    end else if (jy_go || joy_w0 != joy_sent0 ||
                                 joy_w1 != joy_sent1) begin
                        // 4. the joysticks, when either word changed
                        fword   = {C_JOY, {6'd0, jy_i},
                                   (jy_i == 2'd0) ? joy_w0[7:0] :
                                   (jy_i == 2'd1) ? {3'd0, jb_l[12:8]} :
                                   (jy_i == 2'd2) ? jb_r[7:0] :
                                                    {3'd0, jb_r[12:8]}};
                        faction = A_JOY;
                    end else if (rt_pend || rt_go) begin
                        // 5. the RTC time registers
                        fword   = {C_RTC, rt_taddr(rt_i),
                                   (rt_i == 3'd0) ? rt_now[7:0]
                                                  : rt_time[rt_i * 8 +: 8]};
                        faction = A_RTCT;
                    end else if (!ur_empty) begin
                        // 6. a byte for the machine's USB serial port, one
                        //    CMD_UART (cmd, idx, data) frame; it waits behind
                        //    every report source, so it can never split one
                        fword   = {C_UART, ur_head, ur_head_d};
                        faction = A_UART;
                    end else begin
                        // 7. the triggers: a pending press first, then the
                        //    zero of a timer that expired
                        for (tv = 0; tv <= 2; tv = tv + 1)
                            if (trig_pend[tv]) trig_target = tv;
                        if (trig_target >= 0) begin
                            fword   = {C_SW, trig_index(trig_target), 8'h01};
                            faction = A_TRIG_ON;
                        end else begin
                            for (tv = 0; tv <= 2; tv = tv + 1)
                                if (trig_arm[tv] && trig_t[tv] >= TRIGGER_CLKS)
                                    trig_target = tv;
                            if (trig_target >= 0) begin
                                fword   = {C_SW, trig_index(trig_target), 8'h00};
                                faction = A_TRIG_OFF;
                            end else if (nop_t >= NOP_CLKS) begin
                                // 8. a NOP poll when the link was idle
                                fword   = {C_NOPE, 8'h00, 8'h00};
                                faction = A_NOP;
                            end
                        end
                    end
                end
            end
            default: ;
        endcase
        fire = faction != A_NONE;
    end
end

// ---------------- the sequencer ----------------

initial begin
    st      = S_WAIT;
    waiting = 1'b0;
end

always @(posedge clk) begin
    if (reset) begin
        st          <= S_WAIT;
        waiting     <= 1'b0;
        tx_start    <= 1'b0;
        tx_word     <= 24'd0;
        ioctl_wait  <= 1'b0;
        byte_pend   <= 1'b0;
        cur_a       <= 32'd0;
        cur_d       <= 8'd0;
        seq_i       <= 2'd0;
        sw_i        <= 4'd0;
        kb_i        <= 3'd0;
        kb_pend     <= 1'b0;
        kb_again    <= 1'b0;
        kb_snap     <= 56'd0;
        kb_hold     <= 56'd0;
        trig_prev   <= 3'd0;
        trig_pend   <= 3'd0;
        trig_arm    <= 3'd0;
        trig_t[0]   <= 32'd0;
        trig_t[1]   <= 32'd0;
        trig_t[2]   <= 32'd0;
        nop_t       <= 32'd0;
        reply_valid <= 1'b0;
        last_reply  <= 24'd0;
        acc_dx      <= 11'sd0;
        acc_dy      <= 11'sd0;
        acc_dz      <= 11'sd0;
        acc_btn     <= 3'd0;
        acc_any     <= 1'b0;
        ms_prev     <= ps2_mouse[24];
        ms_go       <= 1'b0;
        ms_i        <= 2'd0;
        ms_ly       <= 8'd0;
        ms_lz       <= 8'd0;
        ms_lb       <= 3'd0;
        jb_l        <= 13'd0;
        jb_r        <= 13'd0;
        joy_sent0   <= 13'h0001;   // the idle word: bit 0 connected
        joy_sent1   <= 13'h0001;
        jy_go       <= 1'b0;
        jy_i        <= 2'd0;
        rt_time     <= 56'd0;
        rt_i        <= 3'd0;
        rt_go       <= 1'b0;
        rt_pend     <= 1'b0;
        rt_t        <= 32'd0;
        rt64_prev   <= rtc[64];
        rt_first    <= 1'b1;
        is_bcd      <= 1'b1;
        rtc_si      <= 8'd0;
        bank_sent[0] <= 8'hFF;
        bank_sent[1] <= 8'hFF;
        bank_sent[2] <= 8'hFF;
        uart_tx_data <= 8'd0;
        uart_tx_stb  <= 1'b0;
        ur_cnt       <= 4'd0;
        ur_wr        <= 3'd0;
        ur_rd        <= 3'd0;
        ur_idx       <= 8'd1;   // kg_mcu_uart's own idx starts at 0
        for (iv = 0; iv <= 15; iv = iv + 1)
            sent_val[iv] <= 8'h00;
    end else begin
        tx_start    <= 1'b0;
        reply_valid <= 1'b0;
        uart_tx_stb <= 1'b0;
        if (rx_valid)
            waiting <= 1'b0;

        // (byte capture moved below the fire block: a strobe clocked with
        // A_START must survive its byte_pend clear)

        // fire the frame the arbiter picked and take the next one
        if (fire) begin
            tx_start <= 1'b1;
            tx_word  <= fword;
            waiting  <= 1'b1;
            case (faction)
                A_START: begin
                    st           <= S_SEQ;
                    seq_i        <= 2'd0;
                    ioctl_wait   <= 1'b0;
                    bank_sent[0] <= 8'hFF;
                    bank_sent[1] <= 8'hFF;
                    bank_sent[2] <= 8'hFF;
                end
                A_SEQ:
                    if (seq_i == 2'd1) st <= S_STRM;
                    else               seq_i <= seq_i + 2'd1;
                A_BANK: bank_sent[bank_pick] <= fword[7:0];
                A_DATA: begin
                    byte_pend  <= 1'b0;
                    ioctl_wait <= 1'b0;
                end
                A_LOADER_OFF: begin
                    st   <= S_SWALL;
                    sw_i <= 4'd0;
                end
                A_SW: begin
                    sent_val[sw_target] <= fword[7:0];
                    if (st == S_SWALL) begin
                        if (sw_i == 4'd15) begin
                            st      <= S_RTC;
                            rtc_si  <= 8'd0;
                            rt_time <= rt_now;
                        end else if (sw_i == 4'd8)
                            sw_i <= 4'd10;
                        else
                            sw_i <= sw_i + 4'd1;
                    end
                end
                A_RTCS:
                    if (rtc_si == 8'd255) begin
                        st   <= S_KB;
                        kb_i <= 3'd0;
                    end else
                        rtc_si <= rtc_si + 8'd1;
                A_KB0: kb_i <= (kb_i == 3'd6) ? 3'd7 : kb_i + 3'd1;
                A_KB:  kb_i <= (kb_i == 3'd6) ? 3'd0 : kb_i + 3'd1;
                A_DONE: begin
                    st    <= S_RUN;
                    kb_i  <= 3'd0;   // S_KB left 7; a RUN report starts at 0
                    nop_t <= 32'd0;
                    rt_t  <= 32'd0;
                end
                A_MOUSE: begin
                    if (ms_i == 2'd0) begin
                        ms_ly <= acc_dy[7:0];
                        ms_lz <= acc_dz[7:0];
                        ms_lb <= acc_btn;
                        acc_dx <= 11'sd0;
                        acc_dy <= 11'sd0;
                        acc_dz <= 11'sd0;
                        acc_any <= 1'b0;
                        ms_i   <= 2'd1;
                        ms_go  <= 1'b1;
                    end else if (ms_i == 2'd3) begin
                        ms_i  <= 2'd0;
                        ms_go <= 1'b0;
                    end else
                        ms_i <= ms_i + 2'd1;
                end
                A_JOY: begin
                    if (jy_i == 2'd0) begin
                        jb_l      <= joy_w0;
                        jb_r      <= joy_w1;
                        joy_sent0 <= joy_w0;
                        joy_sent1 <= joy_w1;
                        jy_i      <= 2'd1;
                        jy_go     <= 1'b1;
                    end else if (jy_i == 2'd3) begin
                        jy_i  <= 2'd0;
                        jy_go <= 1'b0;
                    end else
                        jy_i <= jy_i + 2'd1;
                end
                A_RTCT: begin
                    if (rt_i == 3'd0) begin
                        rt_time <= rt_now;
                        rt_pend <= 1'b0;
                        rt_go   <= 1'b1;
                        rt_i    <= 3'd1;
                        rt_t    <= 32'd0;
                    end else if (rt_i == 3'd6) begin
                        rt_i  <= 3'd0;
                        rt_go <= 1'b0;
                    end else
                        rt_i <= rt_i + 3'd1;
                end
                A_TRIG_ON: begin
                    trig_pend[trig_target] <= 1'b0;
                    trig_arm[trig_target]  <= 1'b1;
                    trig_t[trig_target]    <= 32'd0;
                end
                A_TRIG_OFF: trig_arm[trig_target] <= 1'b0;
                A_NOP: ;
                A_UART:  ;   // the byte left the queue with the ur_pop edge
                default: ;
            endcase
        end

        // ioctl_wait stays raised through the whole start sequence (a
        // source that starts only on the low holds its first byte until
        // then), and drops again once S_STRM waits with nothing pending -
        // the release the first strobe follows; before the capture block,
        // so a byte strobed on this clock keeps the wait raised
        if (ioctl_download && ioctl_index == 16'd0 &&
            (st == S_WAIT || st == S_RUN || st == S_SEQ))
            ioctl_wait <= 1'b1;
        if (st == S_STRM && !byte_pend)
            ioctl_wait <= 1'b0;

        // a byte of the download: every strobe is owned (the one clocked
        // with A_START included - this write overrides both clears above;
        // !byte_pend skips only a strobe whose frames were not sent yet,
        // which cannot happen while ioctl_wait was held for it)
        if (ioctl_download && ioctl_wr && ioctl_index == 16'd0 && !byte_pend) begin
            cur_a      <= rom_a;
            cur_d      <= ioctl_dout;
            byte_pend  <= 1'b1;
            ioctl_wait <= 1'b1;
        end

        // a byte for the machine: the byte and its idx are latched together
        // in this clock, whatever the link is doing (a frame in flight, a
        // report burst going out); the entry leaves the queue with the clock
        // its frame was fired, so the head never changes under a frame
        if (ur_push) begin
            ur_ram[ur_wr] <= {ur_idx, uart_rx_data};
            ur_wr         <= (ur_wr == 3'd7) ? 3'd0 : ur_wr + 3'd1;
            ur_idx        <= ur_idx + 8'd1;
        end
        if (ur_pop)
            ur_rd <= (ur_rd == 3'd7) ? 3'd0 : ur_rd + 3'd1;
        if (ur_push && !ur_pop)
            ur_cnt <= ur_cnt + 4'd1;
        else if (ur_pop && !ur_push)
            ur_cnt <= ur_cnt - 4'd1;

        // input sampling, after the fire block so that a kb_changed clocked
        // together with the report's last frame arms a new report, and a
        // trigger's rising edge clocked with its 01 frame keeps it pending
        trig_prev <= trig_bit;
        for (iv = 0; iv <= 2; iv = iv + 1) begin
            if (trig_bit[iv] && !trig_prev[iv])
                trig_pend[iv] <= 1'b1;
            if (trig_arm[iv] && trig_t[iv] != TRIGGER_CLKS)
                trig_t[iv] <= trig_t[iv] + 32'd1;
        end
        // the report burst: kb_snap is its frozen content; a kb_changed
        // arriving while it is in flight only updates kb_hold and arms one
        // fresh complete report of the latest snapshot after it ends
        if (kb_again && !kb_pend) begin
            kb_pend  <= 1'b1;
            kb_snap  <= kb_hold;
            kb_again <= 1'b0;
        end
        if (kb_pend && fire && faction == A_KB && kb_i == 3'd6)
            kb_pend <= 1'b0;
        if (kb_changed) begin
            kb_hold  <= kb_report;
            kb_again <= 1'b1;
        end
        if (st == S_RUN)
            nop_t <= fire ? 32'd0 : nop_t + 32'd1;

        // mouse: a toggle is one report; its X, Y, Z add to a report that
        // has not gone out yet (the buttons are the newest), so two quick
        // moves are delivered as their sum rather than overwriting it
        if (ps2_mouse[24] != ms_prev) begin
            acc_dx  <= ms_take ? clamp7(ms_dx) : clamp7(acc_dx + ms_dx);
            acc_dy  <= ms_take ? clamp7(ms_dy) : clamp7(acc_dy + ms_dy);
            acc_dz  <= ms_take ? clamp7(ms_dz) : clamp7(acc_dz + ms_dz);
            acc_btn <= ps2_mouse[2:0];
            acc_any <= 1'b1;
        end
        ms_prev <= ps2_mouse[24];

        // RTC: the time frames every RTC_CLKS in the run loop, and one
        // refresh right after the first toggle of RTC[64] (an HPS update)
        if (rtc[64] != rt64_prev && rt_first) begin
            rt_pend  <= 1'b1;
            rt_first <= 1'b0;
        end
        rt64_prev <= rtc[64];
        if (st == S_RUN) begin
            if (rt_t >= RTC_CLKS - 1) begin
                rt_t <= 32'd0;
                if (!rt_go) rt_pend <= 1'b1;
            end else
                rt_t <= rt_t + 32'd1;
        end

        // the reply of this frame (protocol.md section 2); NOPE is padding
        if (rx_valid && rx_word[23:16] != C_NOPE) begin
            last_reply  <= rx_word;
            reply_valid <= 1'b1;
            // the CPU setting register B's DM bit: 1 = binary, 0 = BCD
            if (rx_word[23:16] == C_RTC && rx_word[15:8] == 8'h0B)
                is_bcd <= ~rx_word[2];
            // kg_mcu_uart's reply: addr 0 is a byte the machine sent. The
            // dll and dlm writes (01, 02) and the tsconf rs232 mode byte (03)
            // are consumed here and dropped - the channel runs at the tty's
            // speed, so the divisor has no user (uart_route documents the
            // same). A CMD_UART reply updates last_reply/reply_valid exactly
            // as every other reply does today: no tb_mcu_emu case needed
            // them excluded (the reply-path case's word is a CMD_KBD reply),
            // and a consumer of last_reply sees the whole frame either way.
            if (rx_word[23:16] == C_UART && rx_word[15:8] == 8'h00) begin
                uart_tx_stb  <= 1'b1;
                uart_tx_data <= rx_word[7:0];
            end
        end
    end
end

endmodule
