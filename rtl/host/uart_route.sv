//============================================================================
//
//  Karabas Profi for MiSTer - the serial channel router (stage 5).
//
//  One clk_sys (50 MHz) domain. It puts the machine's two serial channels on
//  the HPS UART line (Main_MiSTer's /dev/ttyS1) and takes the line back:
//
//    channel = 0  ESP, the wires. profi.vhd already selects ZiFi or ZXUNO
//             internally and exposes UART_TX / UART_RX / UART_CTS, so this
//             channel is a pass-through at the wire level: no resampling, the
//             baud is whatever the software programmes and the tty speed is
//             whatever Main_MiSTer set for the chosen UART mode.
//    channel = 1  USB, bytes. The ZiFi/EVO USB-RS232 path of kg_mcu_uart
//             (the MCU link's CMD_UART frames) is a byte stream; mcu_emu plays
//             the MCU and hands it here as one-clock strobes. It is framed as
//             8N1 at a fixed CLKS_PER_BIT (434 = 50 MHz / 115200, the standard
//             ZiFi baud). The dll/dlm divisor writes of that path never reach
//             this module, so the tty speed of the mode *is* the speed; a baud
//             the software sets on the ESP wire channel and the fixed USB rate
//             are documented in README.md, not corrected here.
//
//  Clock domains. esp_tx (the machine's UART_TX, clk_bus) and uart_rxd (the
//  HPS line) are asynchronous. Each is a chain of four (rxd) / two (tx)
//  registers, and no logic reads the first stage: the majority-of-3 filter
//  votes over taps 2..4, so the stage that may go metastable feeds only the
//  second register. A level crosses when two of the three voted taps agree, and
//  that costs four clk_sys clocks to esp_rx - three taps into the vote and the
//  vote read by one more register - and rejects a one-clock glitch; a level
//  shorter than that never reaches a channel or starts a frame. esp_rx leaves
//  a clk_sys register toward the machine, whose own input stage is a two-flop
//  synchroniser (uart.v rx_ff, zifi uart_rx). The usb_* byte ports are clk_sys
//  already (the MCU link side), so they need no synchroniser.
//
//  uart_txd = (uart_mode == 3) ? midi_line               // MidiLink, immediate
//             : chan ? tx_line                           // USB bytes, framed
//                    : esp_s2;                            // ESP wires
//  uart_mode is hps_io's OSD "UART mode"; Main_MiSTer sends 3 only for MIDI
//  and mt32_mix drives the MidiLink line. Mode 3 is a level select and not a
//  framed channel, so it takes the line over immediately, mid-byte as well -
//  and while it owns the line nothing is sent out and nothing is received on
//  our two channels (esp_rx idles high, the deserialiser never runs): the Pi
//  must not reach the machine behind the user's back.
//  esp_cts (the machine's UART_CTS output) is accepted at the port and NOT
//  forwarded anywhere: the HPS UART's RTS/CTS are tied low in the top and the
//  core has no path for a CTS into the tty, so flow control stays a software
//  matter. The port exists so the top's wiring is a pass-through.
//
//  Switching the channel (the OSD item, `channel`): the mux follows a latched
//  copy of it (chan), and that copy only moves after the whole port - the
//  machine's TX wire, the HPS line and our own driven level all high, with the
//  deserialiser idle - has sat at its idle level for a full frame
//  (10 * CLKS_PER_BIT clocks). So a byte in flight finishes on the line it
//  started on, and a frame the machine or the Pi is halfway through is not cut
//  in half - for a peer at CLKS_PER_BIT's rate (115200 at 50 MHz) or faster:
//  the longest run a frame can hold at its idle level is nine of its own bits,
//  and at that rate nine of their clocks is less than the ten of ours. A peer
//  slower than that has high runs longer than the whole budget, so the switch
//  can land inside its frame. The serialiser's pop is additionally gated with
//  chan == channel, which kills the one-clock race where the OSD item changes
//  while a byte is being loaded: from that clock on no new byte is started, and
//  the bytes that are already queued wait for the USB channel to own the port
//  again.
//
//  Who may send (the rule, also tested): a usb_tx_wr byte is queued only while
//  the USB channel owns the port (chan = 1) and uart_mode != 3; any other byte
//  is DROPPED at the input. Nothing is shifted out of the FIFO invisibly either
//  - the pop needs the same two conditions - so a byte can never disappear
//  into a line the user cannot see.
//
//  TX backlog, the rule for "no tty reader attached": a usb_tx_wr byte goes
//  into a 16-byte FIFO; when all 16 slots are occupied the incoming byte is
//  DROPPED - the newest byte is lost, nothing stalls, no deadlock. One more
//  byte sits in the shift register, so 17 bytes can be in flight; the machine
//  never waits for this module (its own CPU_WAIT is upstream in zifi), and it
//  keeps strobing whether or not anybody drains the line.
//
//  RX: the deserialiser samples mid-bit, rejects a start bit that is not still
//  low at mid-bit, rejects a frame whose stop bit is low, and after a rejected
//  frame waits for the line to come back high (R_WAIT) before looking for
//  another start bit - a break or a stream of bad frames is never counted and
//  never re-triggers a phantom start in the middle of it. usb_rx_idx is
//  kg_mcu_uart's counter: +1 on every byte accepted. Only the channel that
//  owns the port is fed, and ownership is `usb_own` - the latched `chan`, no
//  MidiLink, and no channel change waiting for an idle line - so while the ESP
//  channel owns it the deserialiser never runs and esp_rx carries the
//  synchronised line, and while the USB channel owns it esp_rx idles high and
//  no byte is delivered; in the clocks a switch is in flight neither side is
//  fed, which is what tb_uart_route's usb_quiet_in_esp case pins.
//  CONSUMER (task 3, the top): this module has no receive strobe - the only
//  sign of a received byte is that usb_rx_data and usb_rx_idx moved in the
//  same clock, and Karabas_Profi.sv turns a change of the counter into the
//  one-clock strobe mcu_emu wants, sampling the byte in that same clock. The
//  byte is therefore never overwritten before it is taken: the next frame
//  cannot finish before CLKS_PER_BIT * 10 clocks after this one, and the top
//  takes it one clock after it appears. The counter is still the record of
//  what the line delivered, so a byte mcu_emu's queue dropped (its own
//  full-and-consume-no-idx rule) is visible here and not there. The two
//  counters are independent otherwise: mcu_emu counts the CMD_UART frames it
//  sends the machine with its own (first frame idx 1).
//
//  Every output resets to its idle level: uart_txd and esp_rx high, tx_line
//  high, the queue empty, usb_rx_data/usb_rx_idx zero. The channel latch
//  (`chan`, see the mux below) resets to 0, so a core that has just been
//  configured owns the line with the ESP wires; MidiLink is not part of that
//  latch at all - `uart_mode == 3` goes straight to the mux, in the clock it
//  appears, which is why no reset of `chan` is needed for MIDI priority.
//
//============================================================================
`default_nettype none

module uart_route #(
    parameter integer CLKS_PER_BIT = 434          // clk_sys 50 MHz / 115200
) (
    input  wire       clk,                        // clk_sys (50 MHz)
    input  wire       reset,                      // core-wide synchronous reset
    input  wire       channel,                    // OSD item: 0 ESP, 1 USB
    input  wire [7:0] uart_mode,                  // hps_io uart_mode (3 = MIDI)
    // the ESP wire channel, to and from the machine (clk_bus at the other end)
    input  wire       esp_tx,                     // machine UART_TX (async)
    input  wire       esp_cts,                    // machine UART_CTS: not forwarded
    output reg        esp_rx,                     // machine UART_RX, idle high
    // the USB byte channel (clk_sys, the MCU link side)
    input  wire [7:0] usb_tx_data,
    input  wire       usb_tx_wr,                  // one-clock strobe
    output reg  [7:0] usb_rx_data,
    output reg  [7:0] usb_rx_idx,                 // +1 per byte received
    // the HPS UART
    input  wire       uart_rxd,                   // UART_RXD (async)
    input  wire       midi_line,                  // mt32_mix's MidiLink line
    output wire       uart_txd                    // UART_TXD, idle high
);

localparam integer DEPTH     = 16;                // TX FIFO bytes
localparam integer PTR_BITS  = 4;                 // DEPTH == 2 ** PTR_BITS
localparam integer HALF_BIT  = (CLKS_PER_BIT + 1) / 2;

localparam [15:0] BIT_LAST    = CLKS_PER_BIT - 1; // clocks per bit
localparam [15:0] HALF_LAST   = HALF_BIT - 1;     // the mid-start-bit point
localparam [15:0] IDLE_SWITCH = 10 * CLKS_PER_BIT;// a frame at the idle level

localparam [1:0] T_IDLE = 2'd0, T_START = 2'd1, T_DATA = 2'd2, T_STOP = 2'd3;
localparam [2:0] R_IDLE = 3'd0, R_MID   = 3'd1, R_DATA = 3'd2,
                 R_STOP = 3'd3, R_WAIT  = 3'd4;

localparam [PTR_BITS:0] DEPTH_W = DEPTH;

reg esp_s1 = 1'b1, esp_s2 = 1'b1;                 // UART_TX: stage 1 -> stage 2
reg rx_s1 = 1'b1, rx_s2 = 1'b1, rx_s3 = 1'b1, rx_s4 = 1'b1;
// the vote is over taps 2..4 only: rx_s1 is never read by anything but rx_s2,
// so a level has to hold two synchroniser clocks to be seen at all - the filter
// rejects a one-clock glitch (tb_uart_route's rx_noise), and anything longer
// than two clocks does reach rxd_f: it is the mid-bit confirmation that throws
// a short low pulse away (rx_bad_frame's fake start bit), not the vote
wire rxd_f = (rx_s4 & rx_s3) | (rx_s4 & rx_s2) | (rx_s3 & rx_s2);

always @(posedge clk) begin
    esp_s1 <= esp_tx;
    esp_s2 <= esp_s1;
    rx_s1  <= uart_rxd;
    rx_s2  <= rx_s1;
    rx_s3  <= rx_s2;
    rx_s4  <= rx_s3;
end

reg [1:0] tx_state;
reg [2:0] rx_state;
wire tx_quiet = (tx_state == T_IDLE);
wire rx_quiet = (rx_state == R_IDLE);
wire midi     = (uart_mode == 8'd3);

// ------------------------------------------------------- the channel latch
// chan is the channel the mux uses; idle_cnt counts the clocks the whole port
// has been at its idle level. The always block is at the end of the module,
// next to tx_line, which is one of the signals it watches.
reg        chan;
reg [15:0] idle_cnt;

// ------------------------------------------------------------- TX: the FIFO
reg [7:0]             txq [0:DEPTH-1];
reg [PTR_BITS-1:0]    tx_wp, tx_rp;
reg [PTR_BITS:0]      tx_cnt;
reg                   tx_line;

// the byte channel may act only while it owns the port: chan is the owned
// channel, and chan == channel means no channel change is pending - so the
// moment the OSD item moves no new byte is started and none is received, and
// a queued byte is never shifted out onto the other channel
wire usb_own = chan && !midi && (chan == channel);
wire tx_full = (tx_cnt >= DEPTH_W);                // the newest byte is dropped
wire tx_push = usb_tx_wr && !tx_full && usb_own;
wire tx_pop  = tx_quiet && (tx_cnt != 0) && usb_own;

always @(posedge clk) begin
    if (reset) begin
        tx_wp  <= {PTR_BITS{1'b0}};
        tx_rp  <= {PTR_BITS{1'b0}};
        tx_cnt <= {(PTR_BITS+1){1'b0}};
    end else begin
        if (tx_push) begin
            txq[tx_wp] <= usb_tx_data;
            tx_wp      <= tx_wp + 1'b1;
        end
        if (tx_pop) begin
            tx_rp <= tx_rp + 1'b1;
        end
        case ({tx_push, tx_pop})
            2'b10:   tx_cnt <= tx_cnt + 1'b1;
            2'b01:   tx_cnt <= tx_cnt - 1'b1;
            default: ;                             // none or both: unchanged
        endcase
    end
end

// --------------------------------------------------- TX: the serialiser
// start 0, eight data bits LSB first, stop 1, CLKS_PER_BIT clocks each.
reg [15:0]        tx_bit;
reg [3:0]         tx_ix;
reg [7:0]         tx_sh;
wire tx_tick = !tx_quiet && (tx_bit == BIT_LAST);

always @(posedge clk) begin
    if (reset) begin
        tx_state <= T_IDLE;
        tx_bit   <= 16'd0;
        tx_ix    <= 4'd0;
        tx_sh    <= 8'h00;
        tx_line  <= 1'b1;                          // idle level
    end else begin
        if (!tx_quiet && !tx_tick) begin
            tx_bit <= tx_bit + 16'd1;
        end
        case (tx_state)
            T_IDLE: if (tx_pop) begin              // the start bit leaves here
                tx_sh    <= txq[tx_rp];
                tx_line  <= 1'b0;
                tx_ix    <= 4'd0;
                tx_bit   <= 16'd0;
                tx_state <= T_START;
            end
            T_START: if (tx_tick) begin
                tx_bit   <= 16'd0;
                tx_line  <= tx_sh[0];
                tx_state <= T_DATA;
            end
            T_DATA: if (tx_tick) begin
                tx_bit <= 16'd0;
                if (tx_ix == 4'd7) begin
                    tx_line  <= 1'b1;              // stop bit
                    tx_state <= T_STOP;
                end else begin
                    tx_line  <= tx_sh[tx_ix + 4'd1];
                    tx_ix    <= tx_ix + 4'd1;
                end
            end
            T_STOP: if (tx_tick) begin
                tx_bit   <= 16'd0;
                tx_line  <= 1'b1;                  // stays at the idle level
                tx_state <= T_IDLE;
            end
            default: tx_state <= T_IDLE;
        endcase
    end
end

// -------------------------------------------------- RX: the deserialiser
// mid-bit sampling, a start bit gone before mid-bit is noise, a frame with a
// low stop bit is dropped, and then the line has to come back high before the
// next start bit is looked for (R_WAIT): a break is never counted.
reg [15:0] rx_bit;
reg [3:0]  rx_ix;
reg [7:0]  rx_sh;
wire rx_tick = (rx_state != R_IDLE) && (rx_bit == BIT_LAST);
wire rx_half = (rx_state == R_MID) && (rx_bit == HALF_LAST);

always @(posedge clk) begin
    if (reset) begin
        rx_state    <= R_IDLE;
        rx_bit      <= 16'd0;
        rx_ix       <= 4'd0;
        rx_sh       <= 8'h00;
        usb_rx_data <= 8'h00;
        usb_rx_idx  <= 8'h00;
    end else begin
        if ((rx_state != R_IDLE) && !rx_tick && !rx_half) begin
            rx_bit <= rx_bit + 16'd1;
        end
        case (rx_state)
            R_IDLE: if (usb_own && !rxd_f) begin   // a start bit on our line
                rx_bit   <= 16'd0;
                rx_state <= R_MID;
            end
            R_MID: if (rx_half) begin              // mid the start bit: confirm
                rx_bit <= 16'd0;
                if (!rxd_f) begin
                    rx_ix    <= 4'd0;
                    rx_sh    <= 8'h00;
                    rx_state <= R_DATA;
                end else begin
                    rx_state <= R_IDLE;            // noise, not a start bit
                end
            end
            R_DATA: if (rx_tick) begin
                rx_bit <= 16'd0;
                rx_sh  <= {rxd_f, rx_sh[7:1]};     // LSB first
                if (rx_ix == 4'd7) begin
                    rx_state <= R_STOP;
                end else begin
                    rx_ix <= rx_ix + 4'd1;
                end
            end
            R_STOP: if (rx_tick) begin
                rx_bit <= 16'd0;
                if (rxd_f) begin                   // a stop bit: count the byte
                    usb_rx_data <= rx_sh;
                    usb_rx_idx  <= usb_rx_idx + 8'd1;
                    rx_state    <= R_IDLE;
                end else begin
                    rx_state    <= R_WAIT;         // bad frame, wait for high
                end
            end
            R_WAIT: if (rxd_f) begin               // the line is idle again
                rx_bit   <= 16'd0;
                rx_state <= R_IDLE;
            end
            default: rx_state <= R_IDLE;
        endcase
    end
end

// ------------------------------------------------------- the channel latch
// The port - the machine's TX wire, the HPS line, our own driven level, both
// engines - has to sit at its idle level for a whole frame before chan may
// follow the OSD item; a frame in flight on either side holds it in place.
wire port_idle = esp_s2 & rxd_f & tx_line & rx_quiet;

always @(posedge clk) begin
    if (reset) begin
        chan     <= 1'b0;
        idle_cnt <= 16'd0;
    end else begin
        if (!port_idle) begin
            idle_cnt <= 16'd0;
        end else if (idle_cnt != IDLE_SWITCH) begin
            idle_cnt <= idle_cnt + 16'd1;
        end
        if (idle_cnt == IDLE_SWITCH && chan != channel) begin
            chan <= channel;
        end
    end
end

// ---------------------------------------------------------------- outputs
// esp_rx: the synchronised, filtered line for the ESP channel, idle high while
// the byte channel or MidiLink owns the port. It leaves a clk_sys register.
always @(posedge clk) begin
    if (reset) begin
        esp_rx <= 1'b1;
    end else begin
        esp_rx <= (chan || midi) ? 1'b1 : rxd_f;
    end
end

// midi_line wins immediately in MIDI mode (mt32_mix's line, a level select);
// otherwise the latched channel picks the framed bytes or the wires. esp_cts
// is deliberately unused here - see the header.
assign uart_txd = midi ? midi_line
                       : (chan ? tx_line : esp_s2);

endmodule

`default_nettype wire
