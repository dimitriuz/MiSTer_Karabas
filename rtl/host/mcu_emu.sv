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
// 14 switch frames (indices 0-8 and 10-14; 9 is the HDF slot), the cleared
// keyboard (CMD_KBD 0..6 = 0) and INIT_DONE. Bytes of another ioctl_index
// are ignored and never raise ioctl_wait. A second download repeats the
// whole start sequence.
//
// Run loop after INIT_DONE, in priority order per idle slot: a switch value
// that differs from the last one sent (all indices compared every slot),
// the keyboard report on kb_changed (seven CMD_KBD frames; a change arriving
// mid-burst is answered with one fresh complete report of the latest one),
// the GS Reset / NMI / Reset trigger pulses (value 1, then 0 after
// TRIGGER_CLKS), and one
// CMD_NOPE poll every NOP_CLKS when idle. Replies the core shifted out
// (rx of each frame) whose command is not NOPE go to last_reply/reply_valid
// for the later stages.
`default_nettype none

module mcu_emu #(
    parameter integer TRIGGER_CLKS = 5000000,  // 100 ms at clk_sys = 50 MHz
    parameter integer NOP_CLKS     = 5000      // a NOP poll every 100 us when idle
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

    // the machine's SDRAM controller ready (sdram_nowait through profi;
    // async to clk, synchronised below)
    input  wire         mem_ready,

    // link to profi
    output wire         spi_cs_n,
    output wire         spi_sck,
    output wire         spi_mosi,
    input  wire         spi_miso,

    output reg  [23:0]  last_reply,  // for later stages
    output reg          reply_valid
);

localparam [7:0] C_KBD     = 8'h01,
                 C_SW      = 8'h05,
                 C_BANK    = 8'h06,
                 C_DATA    = 8'h07,
                 C_LOADER  = 8'h08,
                 C_HWSET   = 8'hF9,
                 C_ISTART  = 8'hFD,
                 C_IDONE   = 8'hFE,
                 C_NOPE    = 8'hFF;

`include "osd_items.svh"

localparam [2:0] S_WAIT = 3'd0, S_SEQ = 3'd1, S_STRM = 3'd2,
                 S_SWALL = 3'd3, S_KB = 3'd4, S_RUN = 3'd5;

localparam [3:0] A_NONE = 4'd0, A_START = 4'd1, A_SEQ = 4'd2,
                 A_BANK = 4'd3, A_DATA  = 4'd4, A_LOADER_OFF = 4'd5,
                 A_SW   = 4'd6, A_KB0   = 4'd7, A_KB = 4'd8,
                 A_DONE = 4'd9, A_TRIG_ON = 4'd10, A_TRIG_OFF = 4'd11,
                 A_NOP  = 4'd12;

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
wire mr_ok = mr_sync[1];

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

reg [7:0] sent_val [0:14];   // last CMD_SWITCHES value sent per index
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

// ---------------- the frame arbiter ----------------

integer cv, tv;                  // the arbiter's loop indices
integer iv;                      // the clocked block's loop index
integer sw_target, trig_target;

reg        fire;
reg [23:0] fword;
reg [3:0]  faction;
reg [1:0]  bank_pick;

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
                    for (cv = 0; cv <= 14; cv = cv + 1)
                        if (cv != 9 && osd_value(cv, status) != sent_val[cv])
                            sw_target = cv;
                    if (sw_target >= 0) begin
                        fword   = {C_SW, sw_target[7:0],
                                   osd_value(sw_target, status)};
                        faction = A_SW;
                    end else if (kb_pend) begin
                        // 2. the keyboard report, seven frames
                        fword   = {C_KBD, {5'd0, kb_i}, kb_snap[kb_i * 8 +: 8]};
                        faction = A_KB;
                    end else begin
                        // 3. the triggers: a pending press first, then the
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
                                // 4. a NOP poll when the link was idle
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
        bank_sent[0] <= 8'hFF;
        bank_sent[1] <= 8'hFF;
        bank_sent[2] <= 8'hFF;
        for (iv = 0; iv <= 14; iv = iv + 1)
            sent_val[iv] <= 8'h00;
    end else begin
        tx_start    <= 1'b0;
        reply_valid <= 1'b0;
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
                        if (sw_i == 4'd14) begin
                            st   <= S_KB;
                            kb_i <= 3'd0;
                        end else if (sw_i == 4'd8)
                            sw_i <= 4'd10;
                        else
                            sw_i <= sw_i + 4'd1;
                    end
                end
                A_KB0: kb_i <= (kb_i == 3'd6) ? 3'd7 : kb_i + 3'd1;
                A_KB:  kb_i <= (kb_i == 3'd6) ? 3'd0 : kb_i + 3'd1;
                A_DONE: begin
                    st    <= S_RUN;
                    kb_i  <= 3'd0;   // S_KB left 7; a RUN report starts at 0
                    nop_t <= 32'd0;
                end
                A_TRIG_ON: begin
                    trig_pend[trig_target] <= 1'b0;
                    trig_arm[trig_target]  <= 1'b1;
                    trig_t[trig_target]    <= 32'd0;
                end
                A_TRIG_OFF: trig_arm[trig_target] <= 1'b0;
                A_NOP: ;
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

        // the reply of this frame (protocol.md section 2); NOPE is padding
        if (rx_valid && rx_word[23:16] != C_NOPE) begin
            last_reply  <= rx_word;
            reply_valid <= 1'b1;
        end
    end
end

endmodule
