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
//  HPS line) are asynchronous and are two-flop synchronised in; uart_rxd
//  additionally goes through a majority-of-3 filter over the three taps, so a
//  one-clock glitch never reaches a channel or starts a frame: a level only
//  crosses when two of the three taps agree. esp_rx leaves a clk_sys register
//  toward the machine. The usb_* byte ports are clk_sys already (the MCU link
//  side), so they need no synchroniser.
//
//  uart_txd = (uart_mode == 3) ? midi_line               // MidiLink, immediate
//             : chan ? tx_line                           // USB bytes, framed
//                    : esp_s2;                            // ESP wires
//  uart_mode is hps_io's OSD "UART mode"; Main_MiSTer sends 3 only for MIDI
//  and mt32_mix drives the MidiLink line. Mode 3 is a level select and not a
//  framed channel, so it takes the line over immediately, mid-byte as well.
//  esp_cts (the machine's UART_CTS output) is accepted at the port and NOT
//  forwarded anywhere: the HPS UART's RTS/CTS are tied low in the top and the
//  core has no path for a CTS into the tty, so flow control stays a software
//  matter. The port exists so the top's wiring is a pass-through.
//
//  Switching the channel (the OSD item, `channel`) mid-byte: the mux follows a
//  latched copy of it (chan), and that copy only changes while nothing is on
//  either line - the serialiser is idle, the deserialiser is idle and esp_tx
//  is at its idle level. A byte being shifted out therefore finishes on the
//  line it started on, and a low esp_tx (the machine mid-frame) keeps the line
//  until it returns high; a frame is never cut in half.
//
//  TX backlog, the rule for "no tty reader attached": a usb_tx_wr byte goes
//  into a 16-byte FIFO; when all 16 slots are occupied the incoming byte is
//  DROPPED - the newest byte is lost, nothing stalls, no deadlock. One more
//  byte sits in the shift register, so 17 bytes can be in flight; the machine
//  never waits for this module (its own CPU_WAIT is upstream in zifi), and it
//  keeps strobing whether or not anybody drains the line.
//
//  RX: the deserialiser samples mid-bit, rejects a start bit that is not still
//  low at mid-bit, and rejects a frame whose stop bit is low (the frame is
//  dropped and counted as nothing). usb_rx_idx is kg_mcu_uart's counter: +1 on
//  every byte accepted. Only the selected channel is fed - with channel = 0 the
//  deserialiser never runs and esp_rx carries the raw synchronised line, with
//  channel = 1 esp_rx idles high and no byte is delivered.
//
//  Every output resets to its idle level: uart_txd and esp_rx high, tx_line
//  high, the queue empty, usb_rx_data/usb_rx_idx zero.
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

localparam [15:0] BIT_LAST   = CLKS_PER_BIT - 1;  // clocks per bit
localparam [15:0] HALF_LAST  = HALF_BIT - 1;      // the mid-start-bit point

localparam [1:0] T_IDLE = 2'd0, T_START = 2'd1, T_DATA = 2'd2, T_STOP = 2'd3;
localparam [1:0] R_IDLE = 2'd0, R_MID   = 2'd1, R_DATA = 2'd2, R_STOP = 2'd3;

localparam [PTR_BITS:0] DEPTH_W  = DEPTH;
reg esp_s1 = 1'b1, esp_s2 = 1'b1;                 // UART_TX, two flops
reg rx_s1 = 1'b1, rx_s2 = 1'b1, rx_s3 = 1'b1;     // UART_RXD, taps of the filter
wire rxd_f = (rx_s3 & rx_s2) | (rx_s3 & rx_s1) | (rx_s2 & rx_s1);

always @(posedge clk) begin
    esp_s1 <= esp_tx;
    esp_s2 <= esp_s1;
    rx_s1  <= uart_rxd;
    rx_s2  <= rx_s1;
    rx_s3  <= rx_s2;
end

// ------------------------------------------------------- the channel latch
// chan is the channel the mux uses. It only moves at a quiescent point: both
// engines idle and the ESP wire at its idle level.
reg       chan;
reg [1:0] tx_state, rx_state;
wire tx_quiet = (tx_state == T_IDLE);
wire rx_quiet = (rx_state == R_IDLE);

always @(posedge clk) begin
    if (reset) begin
        chan <= 1'b0;
    end else if (tx_quiet && rx_quiet && esp_s2) begin
        chan <= channel;
    end
end

// ------------------------------------------------------------- TX: the FIFO
reg [7:0]             txq [0:DEPTH-1];
reg [PTR_BITS-1:0]      tx_wp, tx_rp;
reg [PTR_BITS:0]        tx_cnt;
wire tx_full = (tx_cnt >= DEPTH_W);               // the newest byte is dropped
wire tx_push = usb_tx_wr && !tx_full;
wire tx_pop  = tx_quiet && chan && (tx_cnt != 0);

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
reg               tx_line;
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
// low stop bit is dropped without counting it.
reg [15:0] rx_bit;
reg [3:0]  rx_ix;
reg [7:0]  rx_sh;
wire rx_tick = !rx_quiet && (rx_bit == BIT_LAST);
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
        if (!rx_quiet && !rx_tick && !rx_half) begin
            rx_bit <= rx_bit + 16'd1;
        end
        case (rx_state)
            R_IDLE: if (chan && !rxd_f) begin      // a start bit on the line
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
                rx_bit   <= 16'd0;
                rx_state <= R_IDLE;
                if (rxd_f) begin                   // a stop bit: count the byte
                    usb_rx_data <= rx_sh;
                    usb_rx_idx  <= usb_rx_idx + 8'd1;
                end
            end
            default: rx_state <= R_IDLE;
        endcase
    end
end

// ---------------------------------------------------------------- outputs
// esp_rx: the synchronised, filtered line for the ESP channel, idle high for
// the USB channel. It leaves a clk_sys register toward the machine.
always @(posedge clk) begin
    if (reset) begin
        esp_rx <= 1'b1;
    end else begin
        esp_rx <= chan ? 1'b1 : rxd_f;
    end
end

// midi_line wins immediately in MIDI mode (mt32_mix's line, a level select);
// otherwise the latched channel picks the framed bytes or the wires. esp_cts
// is deliberately unused here - see the header.
assign uart_txd = (uart_mode == 8'd3) ? midi_line
                                      : (chan ? tx_line : esp_s2);

endmodule

`default_nettype wire
