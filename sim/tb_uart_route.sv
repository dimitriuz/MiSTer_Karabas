// Testbench for rtl/host/uart_route.sv, the stage 5 serial channel router:
// the ESP wire channel, the USB byte channel (8N1 at CLKS_PER_BIT clocks per
// bit) and the MidiLink priority.
//
// The clock is clk_sys, nominally 50 MHz (clk_half = 10 ns). USB timing is
// measured in clock counts (CPB = CLKS_PER_BIT) because the module counts
// those; every frame the bench *drives* goes out at a real-time bit period
// (BIT_NS = CPB * 20 ns, plus a per-frame error and a sub-clock phase offset),
// so the deserialiser is exercised against a peer with its own clock. Case
// uart_loop runs the real ZXUNO uart (upstream/.../uart/uart.v) on an
// unrelated 28 MHz / 24 MHz clock and loops a byte through
// uart_tx -> esp_tx -> uart_txd -> uart_rxd -> esp_rx -> uart_rx.
//
// MidiLink takes the line immediately, even mid-byte. The deserialiser is not
// reset by it: a byte it was already assembling is finished and counted when
// the mode comes back, so a takeover in the middle of a machine->HPS frame
// costs at most one stale byte, which is what the hardware would have seen too.
//
// Sampling discipline: every task that reads a DUT output does it after
// `@(posedge clk); #1;` (the settled post-edge value) and every wait is a
// count of clock edges - no $time arithmetic anywhere, and the global
// watchdog counts edges too.
//
// The clock-independence evidence is not only `skewed_clock`: every frame the
// bench *drives* leaves at a real bit period (BIT_NS plus a per-frame error,
// with a sub-clock phase offset), so a deserialiser that counted core clocks
// against a peer on another clock would garble rx_bit_rate, rx_break and
// uart_loop as well.
//
// Cases (each prints `<case>: ok` or `FAIL ...`):
//   esp_passthrough  channel 0: a level on esp_tx is on uart_txd exactly two
//                    clocks later (the two-flop synchroniser, no more, no
//                    less) and holds; a level on uart_rxd reaches esp_rx
//                    exactly RX_DEPTH (4) clocks later - three taps into the
//                    vote and the register that reads it - which `rxd_drive`
//                    pins at that number, not a range; all transitions of a
//                    pattern arrive; a whole frame on the line feeds no byte.
//   usb_tx_byte      channel 1: silence until a strobe arrives, then one 8N1
//                    frame - the mid-bit decode of 0x55, and the low runs of
//                    0x00 (9 bits) and 0xFF (the start bit) pin CLKS_PER_BIT.
//   usb_rx_byte      a frame becomes usb_rx_data with usb_rx_idx incremented
//                    once per byte, and esp_rx stays idle for the whole frame.
//   rx_bad_frame     a frame with a low stop bit is dropped, a start bit gone
//                    before mid-bit is rejected, and a good frame still lands.
//   rx_break         a 19-bit break counts nothing, esp_rx is not held by it,
//                    and the next good frame arrives.
//   rx_bit_rate      frames at +3 %, -3 % and with sub-clock phase offsets.
//   midi_priority    starts in mode 0 and flips to MIDI half a byte into a USB
//                    frame: the line is midi_line from that instant, neither
//                    direction reaches the machine while MIDI owns the port,
//                    three queued bytes are neither sent nor lost, and a byte
//                    pushed while MIDI owns the port is dropped at the input.
//   rx_gone_in_midi  with MIDI on the line, traffic on uart_rxd feeds neither
//                    usb_rx nor esp_rx; it stops counting the instant mode 0
//                    comes back.
//   idle_other_modes every mode but 3, both channels: uart_txd and esp_rx idle
//                    high with midi_line toggling, usb_rx_idx frozen.
//   switch_mid_byte  a byte in flight finishes on the line it started on, the
//                    mux follows the new channel only after a whole idle frame,
//                    and a low esp_tx keeps the line for the same reason.
//   switch_with_backlog  flipping the channel mid-stream keeps the queued bytes
//                    in the FIFO: none is shifted out onto the other channel,
//                    and they come out in order when USB owns the port again.
//   switch_esp_frame the machine holds its TX wire low, the user flips to USB:
//                    the wire keeps the line, a byte pushed meanwhile is lost,
//                    and only after the idle frame does the channel take effect.
//   switch_rxd_frame flipping to USB in the middle of a frame the machine is
//                    receiving does not cut it and is not counted as a byte.
//                    (The rule: a frame that has *started* finishes on the
//                    line it started on - for a peer at 115200 or faster,
//                    whose nine high bits are shorter than the ten-bit switch
//                    budget; a slower peer's high runs are longer than the
//                    whole budget, and its frame can be cut. And a line that
//                    never returns to its idle level - a peer holding the line
//                    low, a break, a machine that stops mid-frame - parks the
//                    switch for as long as it holds. Both are deliberate: the
//                    alternative is to cut a frame in the middle.)
//   rxd_low_parks_switch
//                    what parks the pending switch is the line: 24 low pulses
//                    on uart_rxd each reset the idle counter, the latch does
//                    not move, and the switch lands one budget after the line
//                    stops lying. (The receiver takes no part: arming the flip
//                    makes usb_own false, so nothing is sampled any more.)
//   rxd_frame_parks_flip
//                    a flip armed inside a real 0xFE frame waits for the
//                    deserialiser and not only for the line: that frame holds
//                    its idle level for 3472 clocks on its own, and the latch
//                    still moves only a frame after the stop bit.
//   push_before_flip usb_tx_wr one clock before the OSD item moves, the port
//                    idle-saturated: the byte is not popped onto a channel
//                    that is losing the port, it waits, and comes out when the
//                    channel comes back.
//   tx_backlog       40 strobes into a 16-byte FIFO: 17 bytes go out in order,
//                    the rest are dropped (newest lost), the line idles and a
//                    later byte still frames (no deadlock).
//   rx_noise         a one-clock glitch on uart_rxd, at varying phases, is
//                    rejected by the majority-of-3 filter: esp_rx never blips,
//                    no frame starts, and the next good frame still arrives.
//                    One clock is all this filter rejects: a low of two
//                    synchroniser clocks or more does reach rxd_f, and what
//                    keeps such a pulse from becoming a byte is the mid-bit
//                    confirmation, which rx_bad_frame tests by itself.
//   usb_quiet_in_esp bytes pushed while the ESP channel owns the port are lost
//                    at the input: they never frame, not even later.
//   uart_loop        the ZXUNO uart (upstream/.../uart/uart.v) on its own
//                    28 MHz and 24 MHz clocks against the router on 50 MHz: in
//                    channel 1 its frame becomes usb_rx_data and a pushed byte
//                    comes back as a frame its own receiver decodes; in
//                    channel 0 its frame only crosses as levels on esp_rx, is
//                    not decoded, and a pushed byte never moves uart_txd.
//   skewed_clock     the ESP path, a USB byte out and a byte in again with the
//                    clk_sys period at +2 % and at -2 %.
//
// The last line printed is `tb_uart_route: PASS` or `tb_uart_route: FAIL
// <reason>`; run via sim/run_tb_uart_route.sh (iverilog -g2012).
`timescale 1ns / 1ps

module tb_uart_route;

    localparam integer CPB = 434;                  // the module default
    localparam integer IDLE_BUDGET = 10 * CPB + 64;
    localparam integer RX_DEPTH = 4;               // flop + vote(2..4) + flop
    localparam real BIT_NS = 8680.0;               // CPB * 20 ns = 115200 baud

    // ---------------- clocks ----------------
    reg  clk = 1'b0;
    real clk_half = 10.0;                          // 10.0 -> 50 MHz
    always #(clk_half) clk = ~clk;      // skewed_clock moves the period

    reg  clk_pi = 1'b0;                            // the Pi's own clk_bus
    real clk_pi_half = 1000.0 / 56.0;              // 28 MHz
    always #(clk_pi_half) clk_pi = ~clk_pi;

    // ---------------- the ZXUNO uart, and the loopback plug ----------------
    reg         esp_tx_drv  = 1'b1;
    reg         rxd_drv     = 1'b1;
    // the loop plug between the HPS transmit and receive: the Pi's own TX is
    // never connected to uart_rxd, so a wire-channel exchange stays one-way
    reg         pi_loop     = 1'b0;
    reg         pi_to_rxd   = 1'b0;
    wire        esp_tx      = pi_loop   ? pi_tx    : esp_tx_drv;
    wire        uart_rxd    = pi_to_rxd ? pi_tx    :   // the Pi drives the HPS
                               pi_loop ? uart_txd : rxd_drv;

    reg         pi_ds80     = 1'b0;
    reg  [ 7:0] pi_txdata   = 8'h00;
    reg         pi_txbegin  = 1'b0;
    reg         pi_data_read = 1'b0;
    wire        pi_tx;
    wire        pi_txbusy;
    wire [ 7:0] pi_rxdata;
    wire        pi_rxrecv;
    wire        pi_rts;

    uart #(.CLK(28000000)) pi (
        .clk_bus(clk_pi), .ds80(pi_ds80), .enabled(1'b1),
        .txdata(pi_txdata), .txbegin(pi_txbegin), .txbusy(pi_txbusy),
        .rxdata(pi_rxdata), .rxrecv(pi_rxrecv), .data_read(pi_data_read),
        .rx(esp_rx), .tx(pi_tx), .rts(pi_rts)
    );

    // A receiver on the Pi clock, on the line the router drives: the one-sided
    // check that a frame from the machine arrives unchanged (channel 0).
    wire       pw_rxrecv;
    wire [7:0] pw_rxdata;
    reg        pw_read = 1'b1;
    uart_rx #(.CLK(28000000)) pi_wire_rx (
        .clk_bus(clk_pi), .ds80(pi_ds80), .enabled(1'b1),
        .rxdata(pw_rxdata), .rxrecv(pw_rxrecv), .data_read(pw_read),
        .rx(uart_txd), .rts()
    );

    // ---------------- DUT ----------------
    reg          reset      = 1'b1;
    reg          channel    = 1'b0;
    reg   [ 7:0] uart_mode  = 8'd0;
    reg          esp_cts    = 1'b1;
    wire         esp_rx;
    reg   [ 7:0] usb_tx_data = 8'h00;
    reg          usb_tx_wr  = 1'b0;
    wire  [ 7:0] usb_rx_data;
    wire  [ 7:0] usb_rx_idx;
    reg          midi_line  = 1'b1;
    wire         uart_txd;

    uart_route #(.CLKS_PER_BIT(CPB)) dut (
        .clk(clk), .reset(reset),
        .channel(channel), .uart_mode(uart_mode),
        .esp_tx(esp_tx), .esp_cts(esp_cts), .esp_rx(esp_rx),
        .usb_tx_data(usb_tx_data), .usb_tx_wr(usb_tx_wr),
        .usb_rx_data(usb_rx_data), .usb_rx_idx(usb_rx_idx),
        .uart_rxd(uart_rxd), .midi_line(midi_line), .uart_txd(uart_txd)
    );

    // every transition of the routed line, whatever the reason
    integer txd_edges = 0;
    always @(uart_txd) txd_edges = txd_edges + 1;

    // ---------------- helpers ----------------
    integer errors = 0;
    integer case_errors;
    // the run block's own counters, never the locals of a task
    integer ci, cj, cn;
    integer k;                           // run-block counters
    integer g;
    integer ferr;
    integer got_len;
    integer idx_before;
    reg [7:0] got_byte;
    reg [7:0] send_byte;
    reg [7:0] idx_expect;
    integer   e_sp;
    integer   mn;
    reg       sp_last = 1'b1;
    reg [7:0] got_hps;
    integer   ferr_b;
    real      bit_now;

    task bfail;
        input [8*28-1:0] name;
        input [8*48-1:0] what;
        input integer got;
        input integer want;
        begin
            $display("FAIL %0s %0s got %0b want %0b", name, what, got, want);
            errors = errors + 1;
        end
    endtask

    task ifail;
        input [8*28-1:0] name;
        input [8*48-1:0] what;
        input integer got;
        input integer want;
        begin
            $display("FAIL %0s %0s got %0d want %0d", name, what, got, want);
            errors = errors + 1;
        end
    endtask

    task tfail;
        input [8*28-1:0] name;
        input [8*48-1:0] what;
        begin
            $display("FAIL %0s %0s", name, what);
            errors = errors + 1;
        end
    endtask

    // one settled clock sample of the outputs (the caller is at posedge+1)
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task watch_level;
        input        want;
        input integer n;                     // local to the task
        input [8*28-1:0] name;
        input [8*24-1:0] what;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                tick;
                if (uart_txd !== want) bfail(name, what, uart_txd, want);
            end
        end
    endtask

    // reset, and the idle levels that come with it
    task do_reset;
        begin
            @(negedge clk);
            reset      = 1'b1;
            channel    = 1'b0;
            uart_mode  = 8'd0;
            esp_tx_drv = 1'b1;
            rxd_drv    = 1'b1;
            esp_cts    = 1'b1;
            midi_line  = 1'b1;
            usb_tx_wr  = 1'b0;
            repeat (4) @(posedge clk);
            #1;
            if (uart_txd !== 1'b1) bfail("reset", "uart_txd idle", uart_txd, 1'b1);
            if (esp_rx   !== 1'b1) bfail("reset", "esp_rx idle", esp_rx, 1'b1);
            if (usb_rx_idx !== 0)  ifail("reset", "usb_rx_idx", usb_rx_idx, 0);
            @(negedge clk);
            reset = 1'b0;
            repeat (3) @(posedge clk);
            #1;
            if (uart_txd !== 1'b1) bfail("reset", "uart_txd idle post", uart_txd, 1'b1);
            if (esp_rx   !== 1'b1) bfail("reset", "esp_rx idle post", esp_rx, 1'b1);
        end
    endtask

    // the OSD item: it takes effect only after the port sat idle for a frame
    task set_channel;
        input ch;
        begin
            @(negedge clk);
            channel = ch;
            repeat (11 * CPB) tick;
        end
    endtask

    // ---- the ESP wire path ----
    // Drive esp_tx to `lvl`: the line must still carry `old` one clock later
    // (two synchroniser stages) and `lvl` two clocks later, and hold it.
    task esp_drive;
        input        lvl;
        input        old;
        input integer hold;
        integer k;
        begin
            @(negedge clk);
            esp_tx_drv = lvl;
            tick;
            if (uart_txd !== old) bfail("esp_tx_wire", "still old 1 clk after", uart_txd, old);
            tick;
            if (uart_txd !== lvl) bfail("esp_tx_wire", "new 2 clk after", uart_txd, lvl);
            for (k = 2; k < hold; k = k + 1) begin
                tick;
                if (uart_txd !== lvl) bfail("esp_tx_wire", "held", uart_txd, lvl);
            end
        end
    endtask

    // Drive uart_rxd to `lvl` and pin the depth of the receiving chain: the
    // level is registered once (rx_s1), the vote runs over the three taps after
    // it, and esp_rx is a register on top of the vote - four clk_sys clocks,
    // not three (a vote over the first three taps would show up here as three),
    // and never fewer. The count is deterministic: every stimulus change is at
    // a negedge and the chain is pure registers.
    task rxd_drive;
        input        lvl;
        input integer hold;
        input [8*28-1:0] name;
        integer seen;
        integer kk;
        begin
            @(negedge clk);
            rxd_drv = lvl;
            seen = 0;
            for (kk = 1; kk <= 6; kk = kk + 1) begin
                tick;
                if (esp_rx === lvl && seen == 0) seen = kk;
            end
            if (seen == 0) tfail(name, "esp_rx never followed uart_rxd");
            else if (seen != RX_DEPTH)
                ifail(name, "esp_rx synchroniser depth", seen, RX_DEPTH);
            for (kk = 0; kk < hold; kk = kk + 1) begin
                tick;
                if (esp_rx !== lvl) bfail(name, "esp_rx held", esp_rx, lvl);
            end
        end
    endtask

    // ---- the USB byte path ----
    task usb_send;
        input [7:0] b;
        begin
            @(negedge clk);
            usb_tx_data = b;
            usb_tx_wr   = 1'b1;
            @(negedge clk);                    // one clk_sys clock of strobe
            usb_tx_wr   = 1'b0;
        end
    endtask

    // Wait for a start bit on uart_txd, then sample the 8 data bits and the
    // stop bit at the nominal mid-bit points (the DUT is the sender, so its own
    // clock is the reference; the absolute rate is uart_loop's job).
    task usb_recv;
        output integer ferr;
        output [7:0] got;
        integer k;
        integer g;
        begin
            ferr = 1;
            got  = 8'h00;
            g    = 0;
            while (uart_txd === 1'b1 && g < 20000) begin
                tick;
                g = g + 1;
            end
            if (uart_txd !== 1'b0) tfail("usb_recv", "no start bit");
            else begin
                repeat (CPB / 2) tick;
                if (uart_txd !== 1'b0) tfail("usb_recv", "start bit not low at mid-bit");
                else begin
                    for (k = 0; k < 8; k = k + 1) begin
                        repeat (CPB) tick;
                        got = {uart_txd, got[7:1]};           // LSB first
                    end
                    repeat (CPB) tick;
                    if (uart_txd !== 1'b1) tfail("usb_recv", "stop bit low");
                    ferr = 0;
                end
            end
        end
    endtask

    // Wait for the line to fall and measure the low run in clocks.
    task measure_low;
        output integer ferr;
        output integer len;
        integer g;
        begin
            ferr = 1;
            len  = 0;
            g    = 0;
            while (uart_txd === 1'b1 && g < 20000) begin
                tick;
                g = g + 1;
            end
            if (uart_txd !== 1'b0) tfail("measure_low", "no start bit");
            else begin
                len = 1;
                while (uart_txd === 1'b0 && len < 20000) begin
                    tick;
                    len = len + 1;
                end
                if (uart_txd !== 1'b1) tfail("measure_low", "the line never came back high");
                else ferr = 0;
            end
        end
    endtask

    // Drive one 8N1 frame on uart_rxd at a real-time bit period `bit_ns` with a
    // sub-clock `phase` offset; `stop_lvl` may drive the stop bit low.
    task drive_frame;
        input [7:0] b;
        input real  bit_ns;
        input real  phase;
        input       stop_lvl;
        integer k;
        begin
            @(negedge clk);
            #(phase);
            rxd_drv = 1'b0;
            #(bit_ns);
            for (k = 0; k < 8; k = k + 1) begin
                rxd_drv = b[k];
                #(bit_ns);
            end
            rxd_drv = stop_lvl;
            #(bit_ns);
            rxd_drv = 1'b1;
            #(bit_ns / 4.0);
        end
    endtask

    // Drive only a low pulse on uart_rxd (a fake start bit), `low` clocks long.
    task rxd_pulse;
        input integer low;
        integer k;
        begin
            @(negedge clk);
            rxd_drv = 1'b0;
            for (k = 0; k < low; k = k + 1) @(negedge clk);
            rxd_drv = 1'b1;
        end
    endtask

    // Hold the line low for `bits` bit times (a break), real time.
    task drive_break;
        input integer bits;
        input real    bit_ns;
        begin
            @(negedge clk);
            rxd_drv = 1'b0;
            #(bit_ns * bits);
            rxd_drv = 1'b1;
            #(bit_ns);
        end
    endtask

    // A byte must have landed on usb_rx_*: idx reaches idx_want, data is b.
    task expect_rx;
        input [7:0]  b;
        input [7:0]  idx_want;
        input [8*28-1:0] name;
        integer g;
        begin
            g = 0;
            while (usb_rx_idx !== idx_want && g < 4 * CPB) begin
                @(negedge clk);
                #1;
                g = g + 1;
            end
            if (usb_rx_idx !== idx_want) ifail(name, "usb_rx_idx", usb_rx_idx, idx_want);
            else if (usb_rx_data !== b)  ifail(name, "usb_rx_data", usb_rx_data, b);
        end
    endtask

    // ---- the ZXUNO uart ----
    // Empty the Pi's receiver: rxrecv must be low before a new exchange, or a
    // stale byte is taken for the answer.
    task pi_clear;
        integer g;
        begin
            @(negedge clk_pi);
            pi_data_read = 1'b1;
            repeat (4) @(negedge clk_pi);
            pi_data_read = 1'b0;
            g = 0;
            while (pi_rxrecv === 1'b1 && g < 4000) begin
                @(negedge clk_pi);
                g = g + 1;
            end
            repeat (50) @(negedge clk_pi);
        end
    endtask

    // One 8N1 frame from the Pi's clock domain onto uart_rxd, at the bit
    // period its uart uses (PERIOD clk_bus cycles). The wire channel is level
    // transparent, so this is how a real ESP32 talks to the machine.
    task drive_pi_frame;
        input [7:0] b;
        integer k;
        integer e;
        real    bit_ns;                  // one uart bit in nanoseconds
    begin
        // the uart shifts every PERIOD clk_bus cycles (CLKDS80/BPS when ds80)
        bit_ns = (pi_ds80 ? 208.0 : 243.0) * clk_pi_half * 2.0;
        @(negedge clk);
        rxd_drv = 1'b0;
        for (e = 0; e < (bit_ns / 20.0); e = e + 1) @(negedge clk);
        for (k = 0; k < 8; k = k + 1) begin
            rxd_drv = b[k];
            for (e = 0; e < (bit_ns / 20.0); e = e + 1) @(negedge clk);
        end
        rxd_drv = 1'b1;
        for (e = 0; e < (bit_ns / 20.0); e = e + 1) @(negedge clk);
    end
    endtask

    task pw_wait;
        output [7:0] b;
        output integer ferr;
        integer g;
        begin
            ferr = 1;
            b    = 8'h00;
            g    = 0;
            while (pw_rxrecv !== 1'b1 && g < 100000) begin
                @(negedge clk_pi);
                g = g + 1;
            end
            if (pw_rxrecv !== 1'b1) tfail("uart_loop", "uart_txd never framed");
            else begin
                b    = pw_rxdata;
                ferr = 0;
            end
        end
    endtask

    task pw_clear;
        begin
            @(negedge clk_pi);
            pw_read = 1'b0;
            @(negedge clk_pi);
            pw_read = 1'b1;
            repeat (50) @(negedge clk_pi);
        end
    endtask

    task pi_send;
        input [7:0] b;
        integer g;
        begin
            g = 0;
            while (pi_txbusy === 1'b1 && g < 100000) begin
                @(negedge clk_pi);
                g = g + 1;
            end
            if (g >= 100000) tfail("uart_loop", "the Pi is stuck busy");
            pi_txdata = b;
            @(negedge clk_pi);
            pi_txbegin = 1'b1;
            @(negedge clk_pi);
            pi_txbegin = 1'b0;
        end
    endtask

    task pi_recv;
        output [7:0]  b;
        output integer ferr;
        integer g;
        begin
            ferr = 1;
            b    = 8'h00;
            g    = 0;
            while (pi_rxrecv !== 1'b1 && g < 100000) begin
                @(negedge clk_pi);
                g = g + 1;
            end
            if (pi_rxrecv !== 1'b1) tfail("uart_loop", "no byte came back to the Pi");
            else begin
                b = pi_rxdata;
                ferr = 0;
                @(negedge clk_pi);
                pi_data_read = 1'b1;
                @(negedge clk_pi);
                pi_data_read = 1'b0;
            end
        end
    endtask

    // ---------------- the run ----------------
    initial begin
        $display("tb_uart_route: CPB %0d, bit %0.1f ns", CPB, BIT_NS);

        // ================= esp_passthrough =================
        case_errors = errors;
        do_reset;
        set_channel(0);
        esp_drive(1'b0, 1'b1, 40);
        esp_drive(1'b1, 1'b0, 40);
        g = txd_edges;
        esp_drive(1'b0, 1'b1, 20);
        esp_drive(1'b1, 1'b0, 20);
        esp_drive(1'b0, 1'b1, 30);
        esp_drive(1'b0, 1'b0, 12);      // no transition: two equal levels
        esp_drive(1'b1, 1'b0, 25);
        repeat (6) tick;
        if (txd_edges != g + 4) ifail("esp_passthrough", "uart_txd edges", txd_edges, g + 4);
        rxd_drive(1'b0, 30, "esp_rx_wire");
        rxd_drive(1'b1, 30, "esp_rx_wire");
        rxd_drive(1'b0, 14, "esp_rx_wire");
        rxd_drive(1'b1, 14, "esp_rx_wire");
        // a whole frame on the line while the wires own the port: it is never
        // resampled, so the byte channel must stay unfed
        drive_frame(8'h5A, BIT_NS, 0.0, 1'b1);
        repeat (2 * CPB) tick;
        if (usb_rx_idx !== 8'd0)
            ifail("esp_passthrough", "usb_rx_idx fed while ESP", usb_rx_idx, 0);
        if (errors == case_errors) $display("esp_passthrough: ok");
        else $display("esp_passthrough: FAIL");

        // ================= usb_tx_byte =================
        case_errors = errors;
        do_reset;
        set_channel(1);
        watch_level(1'b1, 3 * CPB, "usb_tx_byte", "silent before the strobe");
        usb_send(8'h55);
        usb_recv(ferr, got_byte);
        if (!ferr && got_byte !== 8'h55) ifail("usb_tx_byte", "0x55 mid-bit decode", got_byte, 8'h55);
        usb_send(8'h00);
        measure_low(ferr, got_len);
        if (!ferr && (got_len < 9 * CPB - 3 || got_len > 9 * CPB + 3))
            ifail("usb_tx_byte", "0x00 low run != 9 bits", got_len, 9 * CPB);
        usb_send(8'hFF);
        repeat (CPB) tick;                       // past the stop bit it follows
        measure_low(ferr, got_len);
        if (!ferr && (got_len < CPB - 3 || got_len > CPB + 3))
            ifail("usb_tx_byte", "0xFF low run != 1 bit", got_len, CPB);
        watch_level(1'b1, 3 * CPB, "usb_tx_byte", "idle after the frame");
        if (errors == case_errors) $display("usb_tx_byte: ok");
        else $display("usb_tx_byte: FAIL");

        // ================= usb_rx_byte =================
        case_errors = errors;
        do_reset;
        set_channel(1);
        // esp_rx stays idle for the whole frame while the byte channel owns the
        fork
            drive_frame(8'hA5, BIT_NS, 0.0, 1'b1);
            begin
                cn = 0;
                while (cn < 12 * CPB) begin
                    tick;
                    cn = cn + 1;
                    if (esp_rx !== 1'b1)
                        bfail("usb_rx_byte", "esp_rx fed while USB", esp_rx, 1'b1);
                end
            end
        join
        expect_rx(8'hA5, 8'd1, "usb_rx_byte");
        drive_frame(8'h3C, BIT_NS, 3.0, 1'b1);
        expect_rx(8'h3C, 8'd2, "usb_rx_byte");
        drive_frame(8'h00, BIT_NS, 0.0, 1'b1);
        expect_rx(8'h00, 8'd3, "usb_rx_byte");
        if (esp_rx !== 1'b1) bfail("usb_rx_byte", "esp_rx idle", esp_rx, 1'b1);
        if (errors == case_errors) $display("usb_rx_byte: ok");
        else $display("usb_rx_byte: FAIL");

        // ================= rx_bad_frame =================
        case_errors = errors;
        do_reset;
        set_channel(1);
        drive_frame(8'h55, BIT_NS, 0.0, 1'b0);      // stop bit driven low
        repeat (2 * CPB) tick;
        if (usb_rx_idx !== 8'd0) ifail("rx_bad_frame", "idx after a bad stop", usb_rx_idx, 0);
        rxd_pulse(20);                               // gone before mid-bit
        repeat (11 * CPB) tick;
        if (usb_rx_idx !== 8'd0) ifail("rx_bad_frame", "idx after a fake start", usb_rx_idx, 0);
        drive_frame(8'h96, BIT_NS, 0.0, 1'b1);
        expect_rx(8'h96, 8'd1, "rx_bad_frame");
        if (errors == case_errors) $display("rx_bad_frame: ok");
        else $display("rx_bad_frame: FAIL");

        // ================= rx_break =================
        // A break is a line held low for far longer than a frame: it may not be
        // counted, the deserialiser must not keep re-triggering on it, and in
        // MIDI mode it must not reach the machine at all.
        case_errors = errors;
        do_reset;
        set_channel(1);
        fork
            drive_break(19, BIT_NS);                 // 19 bit times line low
            begin
                cn = 0;
                while (cn < 20 * CPB) begin
                    tick;
                    cn = cn + 1;
                    if (esp_rx !== 1'b1)
                        bfail("rx_break", "esp_rx held by the break", esp_rx, 1'b1);
                end
            end
        join
        repeat (4 * CPB) tick;
        if (usb_rx_idx !== 8'd0) ifail("rx_break", "a break was counted", usb_rx_idx, 0);
        drive_frame(8'h5A, BIT_NS, 0.0, 1'b1);
        expect_rx(8'h5A, 8'd1, "rx_break");
        if (errors == case_errors) $display("rx_break: ok");
        else $display("rx_break: FAIL");

        // ================= rx_bit_rate =================
        case_errors = errors;
        for (ci = 0; ci < 4; ci = ci + 1) begin
            do_reset;
            set_channel(1);
            case (ci)
                0: begin bit_now = BIT_NS * 1.03; send_byte = 8'h5A; end
                1: begin bit_now = BIT_NS * 0.97; send_byte = 8'hA5; end
                2: begin bit_now = BIT_NS;        send_byte = 8'h3C; end
                default: begin bit_now = BIT_NS * 1.02; send_byte = 8'hC3; end
            endcase
            drive_frame(send_byte, bit_now, (ci == 2) ? 13.0 : (ci == 3) ? 7.5 : 1.0, 1'b1);
            expect_rx(send_byte, 8'd1, "rx_bit_rate");
        end
        if (errors == case_errors) $display("rx_bit_rate: ok");
        else $display("rx_bit_rate: FAIL");

        // ================= midi_priority =================
        // MIDI is a mute with priority: the instant mode 3 is set the line is
        // midi_line, mid-frame; nothing the byte channel has queued may escape
        // while it owns the port, nothing pushed is taken. The proof is the
        // fate of the queue after the mode goes back: three bytes come out in
        // order, the byte pushed during MIDI never appears at all.
        case_errors = errors;
        for (ci = 0; ci < 2; ci = ci + 1) begin
            do_reset;
            set_channel(ci[0]);
            // four bytes: the first is on its way out, three are queued behind
            usb_send(8'hF0);
            usb_send(8'h2C);
            usb_send(8'h93);
            usb_send(8'hD7);
            repeat (3 * CPB / 2) tick;               // a bit and a half in
            @(negedge clk);
            uart_mode = 8'd3;                        // MIDI takes over mid-byte
            for (cj = 0; cj < 4; cj = cj + 1) begin
                @(negedge clk);
                midi_line = cj[0];
                #1;
                if (uart_txd !== midi_line)
                    bfail("midi_priority", "uart_txd != midi_line", uart_txd, midi_line);
            end
            if (errors != case_errors) tfail("midi_priority", "stopped here");
            // and neither direction reaches the machine while MIDI owns the line
            @(negedge clk);
            esp_tx_drv = 1'b0;
            rxd_drv    = 1'b0;
            repeat (6) tick;
            if (uart_txd !== midi_line)
                bfail("midi_priority", "the wire moved the line", uart_txd, midi_line);
            if (esp_rx !== 1'b1) bfail("midi_priority", "esp_rx fed by the Pi", esp_rx, 1'b1);
            // a byte pushed while MIDI owns the port: dropped at the input,
            // it must never appear on the line later
            usb_send(8'h5A);
            repeat (12 * CPB) tick;
            if (usb_rx_idx !== 8'd0)
                ifail("midi_priority", "usb_rx_idx in MIDI", usb_rx_idx, 0);
            @(negedge clk);
            esp_tx_drv = 1'b1;
            rxd_drv    = 1'b1;
            midi_line  = 1'b1;                       // a quiet MIDI line
            repeat (4) tick;
            if (ci[0] == 0) begin
                // the ESP channel never owned the port: nothing was queued,
                // and mode 0 changes nothing but the mux
                @(negedge clk);
                uart_mode = 8'd0;
                repeat (12 * CPB) tick;
                watch_level(1'b1, 4 * CPB, "midi_priority", "line idle in ESP mode 0");
                usb_send(8'hF0);
                repeat (12 * CPB) tick;
                if (uart_txd !== 1'b1)
                    bfail("midi_priority", "the ESP channel framed a byte", uart_txd, 1'b1);
            end else begin
                // back to mode 0 with the receiver already listening: the
                // three queued bytes come out, the MIDI-window byte does not
                fork
                    begin
                        mn = 0;
                        for (cj = 0; cj < 4; cj = cj + 1) begin
                            g = 0;
                            while ((uart_txd !== 1'b0) && (g < 12 * CPB)) begin
                                tick;
                                g = g + 1;
                            end
                            if (uart_txd !== 1'b0) cj = 4;   // the queue is empty
                            else begin
                                usb_recv(ferr, got_byte);
                                if (ferr)
                                    tfail("midi_priority", "a queued byte never framed");
                                else begin
                                    mn = mn + 1;
                                    case (mn)
                                        1: send_byte = 8'h2C;
                                        2: send_byte = 8'h93;
                                        3: send_byte = 8'hD7;
                                        default: send_byte = 8'h5A;   // dropped
                                    endcase
                                    if (got_byte !== send_byte)
                                        ifail("midi_priority", "the byte out after MIDI",
                                              got_byte, send_byte);
                                end
                            end
                        end
                        if (mn != 3)
                            ifail("midi_priority", "bytes out after MIDI", mn, 3);
                    end
                    begin
                        @(negedge clk);
                        uart_mode = 8'd0;
                    end
                join
                repeat (12 * CPB) tick;
                // and the channel still works afterwards
                usb_send(8'h7B);
                usb_recv(ferr, got_byte);
                if (ferr) tfail("midi_priority", "the byte after MIDI never framed");
                else if (got_byte !== 8'h7B)
                    ifail("midi_priority", "byte after MIDI", got_byte, 8'h7B);
            end
        end
        if (errors == case_errors) $display("midi_priority: ok");
        else $display("midi_priority: FAIL");

        // ================= rx_gone_in_midi =================
        // While MidiLink owns the port the byte channel is deaf as well as
        // mute: a frame that arrives on the Pi line at MIDI speed, with a
        // receiver that would otherwise sample it whole, must not be counted.
        case_errors = errors;
        do_reset;
        set_channel(1);
        @(negedge clk);
        uart_mode = 8'd3;                        // MidiLink owns the port
        for (ci = 0; ci < 3; ci = ci + 1) begin
            fork
                drive_frame(8'h5A, BIT_NS, 1.0, 1'b1);
                begin
                    midi_line = 1'b1;
                    repeat (12 * CPB) tick;
                end
            join
        end
        @(negedge clk);
        uart_mode = 8'd0;
        if (usb_rx_idx !== 8'd0)
            ifail("rx_gone_in_midi", "a frame was received under MIDI",
                  usb_rx_idx, 0);
        drive_frame(8'h5A, BIT_NS, 1.0, 1'b1);   // and mode 0 receives again
        expect_rx(8'h5A, 8'd1, "rx_gone_in_midi");
        if (errors == case_errors) $display("rx_gone_in_midi: ok");
        else $display("rx_gone_in_midi: FAIL");

        // ================= idle_other_modes =================
        case_errors = errors;
        for (ci = 0; ci < 5; ci = ci + 1) begin
            for (cj = 0; cj < 2; cj = cj + 1) begin
                do_reset;
                case (ci)
                    0: uart_mode = 8'd0;
                    1: uart_mode = 8'd1;
                    2: uart_mode = 8'd2;
                    3: uart_mode = 8'd4;
                    default: uart_mode = 8'd5;
                endcase
                set_channel(cj[0]);
                idx_before = usb_rx_idx;
                for (k = 0; k < 4; k = k + 1) begin
                    @(negedge clk);
                    midi_line = k[0];
                    watch_level(1'b1, 25, "idle_other_modes", "uart_txd idle");
                    if (esp_rx !== 1'b1) bfail("idle_other_modes", "esp_rx idle", esp_rx, 1'b1);
                end
                if (usb_rx_idx !== idx_before)
                    ifail("idle_other_modes", "usb_rx_idx moved", usb_rx_idx, idx_before);
            end
        end
        if (errors == case_errors) $display("idle_other_modes: ok");
        else $display("idle_other_modes: FAIL");

        // ================= switch_mid_byte =================
        case_errors = errors;
        do_reset;
        set_channel(1);
        usb_send(8'h55);                       // the frame starts on the USB line
        fork
            usb_recv(ferr, got_byte);          // received from its own start bit
            begin
                repeat (3 * CPB) tick;         // a few bits into the frame
                @(negedge clk);
                channel = 1'b0;                // flip mid-frame
            end
        join
        if (ferr) tfail("switch_mid_byte", "the frame did not arrive");
        if (!ferr && got_byte !== 8'h55)
            ifail("switch_mid_byte", "frame survived the switch", got_byte, 8'h55);
        // the byte channel may not start another one while the flip is pending
        watch_level(1'b1, 11 * CPB, "switch_mid_byte", "line idle after the stop");
        set_channel(0);                        // settle, and the wire takes over
        esp_drive(1'b0, 1'b1, 30);
        esp_drive(1'b1, 1'b0, 30);
        if (errors == case_errors) $display("switch_mid_byte: ok");
        else $display("switch_mid_byte: FAIL");

        // ================= switch_with_backlog =================
        case_errors = errors;
        do_reset;
        set_channel(1);
        for (ci = 0; ci < 4; ci = ci + 1) usb_send(8'h10 + ci[7:0]);   // back to back
        // flip while the first frame is still on the line, so that a pop for
        // the next queued byte cannot slip in before the flip is seen
        fork
            usb_recv(ferr, got_byte);          // the first one, fully
            begin
                repeat (10 * CPB - 60) tick;
                @(negedge clk);
                channel = 1'b0;
            end
        join
        if (ferr) tfail("switch_with_backlog", "the first byte did not arrive");
        if (!ferr && got_byte !== 8'h10) ifail("switch_with_backlog", "first byte", got_byte, 8'h10);
        watch_level(1'b1, 12 * CPB, "switch_with_backlog", "queued bytes held");
        // they are only waiting: back on USB they come out in order, so the
        // receivers listen from the start bit (the channel takes effect in the
        // middle of the settle, not at its end)
        fork
            begin
                for (ci = 1; ci < 4; ci = ci + 1) begin
                    usb_recv(ferr, got_byte);
                    if (!ferr && got_byte !== (8'h10 + ci[7:0]))
                        ifail("switch_with_backlog", "held byte", got_byte, 8'h10 + ci);
                end
            end
            set_channel(1);
        join
        if (errors == case_errors) $display("switch_with_backlog: ok");
        else $display("switch_with_backlog: FAIL");

        // ================= switch_esp_frame =================
        case_errors = errors;
        do_reset;
        set_channel(0);
        @(negedge clk);
        esp_tx_drv = 1'b0;                     // the machine is mid-frame
        repeat (4) tick;
        @(negedge clk);
        channel = 1'b1;                        // the user flips to USB now
        watch_level(1'b0, 4 * CPB, "switch_esp_frame", "esp_tx still owns the line");
        @(negedge clk);
        esp_tx_drv = 1'b1;                     // its stop bit
        g = 0;
        while (uart_txd === 1'b0 && g < 8) begin
            tick;
            g = g + 1;
        end
        if (uart_txd !== 1'b1) tfail("switch_esp_frame", "the line never came back");
        // inside the idle frame the wire still owns the line: no USB start bit
        @(negedge clk);
        esp_tx_drv = 1'b0;
        repeat (4) tick;                         // esp_s2 is two clocks behind
        watch_level(1'b0, 2 * CPB, "switch_esp_frame", "the next low pulse passes");
        usb_send(8'h7E);                       // dropped: USB does not own the port
        @(negedge clk);
        esp_tx_drv = 1'b1;
        set_channel(1);
        usb_send(8'hEE);
        usb_recv(ferr, got_byte);
        if (!ferr && got_byte !== 8'hEE)
            ifail("switch_esp_frame", "byte after the switch", got_byte, 8'hEE);
        watch_level(1'b1, 3 * CPB, "switch_esp_frame", "dropped byte stayed dropped");
        if (errors == case_errors) $display("switch_esp_frame: ok");
        else $display("switch_esp_frame: FAIL");

        // ================= switch_rxd_frame =================
        case_errors = errors;
        do_reset;
        set_channel(0);
        @(negedge clk);
        rxd_drv = 1'b0;                        // the Pi starts a frame to the machine
        repeat (CPB / 2) tick;
        if (esp_rx !== 1'b0) bfail("switch_rxd_frame", "esp_rx follows the wire", esp_rx, 1'b0);
        @(negedge clk);
        channel = 1'b1;                        // flip in the middle of it
        for (k = 0; k < 3 * CPB; k = k + 1) begin
            tick;
            if (esp_rx !== 1'b0)
                bfail("switch_rxd_frame", "frame cut by the switch", esp_rx, 1'b0);
        end
        @(negedge clk);
        rxd_drv = 1'b1;                        // its stop bit
        repeat (CPB) tick;
        set_channel(1);
        if (usb_rx_idx !== 8'd0)
            ifail("switch_rxd_frame", "usb_rx_idx from a wire frame", usb_rx_idx, 0);
        if (errors == case_errors) $display("switch_rxd_frame: ok");
        else $display("switch_rxd_frame: FAIL");

        // ================= tx_backlog =================
        case_errors = errors;
        do_reset;
        set_channel(1);
        // 40 strobes, one clock apart: 1 in the shifter + 16 in the FIFO, the
        // rest dropped (the newest byte is lost), never a stall
        for (ci = 0; ci < 40; ci = ci + 1) begin
            @(negedge clk);
            usb_tx_data = 8'h10 + ci[7:0];
            usb_tx_wr   = 1'b1;
        end
        @(negedge clk);
        usb_tx_wr = 1'b0;
        for (ci = 0; ci < 17; ci = ci + 1) begin
            usb_recv(ferr, got_byte);
            if (!ferr && got_byte !== (8'h10 + ci[7:0]))
                ifail("tx_backlog", "framed byte out of order", got_byte, 8'h10 + ci);
        end
        watch_level(1'b1, 3 * CPB, "tx_backlog", "line idle after the 17 bytes");
        usb_send(8'hEE);                       // and it still takes a new byte
        usb_recv(ferr, got_byte);
        if (!ferr && got_byte !== 8'hEE) ifail("tx_backlog", "byte after the backlog", got_byte, 8'hEE);
        if (errors == case_errors) $display("tx_backlog: ok");
        else $display("tx_backlog: FAIL");

        // ================= rx_noise =================
        case_errors = errors;
        do_reset;
        set_channel(0);
        for (ci = 0; ci < 4; ci = ci + 1) begin
            repeat (11 + 37 * ci) @(negedge clk);   // glitches at varying phases
            @(negedge clk);
            rxd_drv = 1'b0;
            @(negedge clk);
            rxd_drv = 1'b1;
            cn = 0;
            while (cn < 4 * CPB) begin
                tick;
                cn = cn + 1;
                if (esp_rx !== 1'b1) bfail("rx_noise", "esp_rx blipped", esp_rx, 1'b1);
            end
        end
        // the wire path still works after the rejected glitches
        rxd_drive(1'b0, 12, "rx_noise");
        rxd_drive(1'b1, 12, "rx_noise");
        do_reset;
        set_channel(1);
        for (ci = 0; ci < 4; ci = ci + 1) begin
            repeat (7 + 53 * ci) @(negedge clk);
            @(negedge clk);
            rxd_drv = 1'b0;
            @(negedge clk);
            rxd_drv = 1'b1;
            cn = 0;
            while (cn < 4 * CPB) begin
                tick;
                cn = cn + 1;
                if (uart_txd !== 1'b1) bfail("rx_noise", "usb line low", uart_txd, 1'b1);
            end
        end
        if (usb_rx_idx !== 8'd0) ifail("rx_noise", "idx after noise", usb_rx_idx, 0);
        drive_frame(8'h5A, BIT_NS, 0.0, 1'b1);
        expect_rx(8'h5A, 8'd1, "rx_noise");
        if (errors == case_errors) $display("rx_noise: ok");
        else $display("rx_noise: FAIL");

        // ================= usb_quiet_in_esp =================
        case_errors = errors;
        do_reset;
        set_channel(0);
        for (ci = 0; ci < 4; ci = ci + 1) usb_send(8'h40 + ci[7:0]);
        watch_level(1'b1, 6 * CPB, "usb_quiet_in_esp", "no USB byte while ESP");
        if (usb_rx_idx !== 8'd0) ifail("usb_quiet_in_esp", "usb_rx_idx", usb_rx_idx, 0);
        if (esp_rx !== 1'b1) bfail("usb_quiet_in_esp", "esp_rx idle", esp_rx, 1'b1);
        // they are lost at the input, not queued: switching to USB shows nothing
        set_channel(1);
        watch_level(1'b1, 6 * CPB, "usb_quiet_in_esp", "the lost bytes never show up");
        usb_send(8'h2F);                       // and the input is not stuck shut
        usb_recv(ferr, got_byte);
        if (!ferr && got_byte !== 8'h2F) ifail("usb_quiet_in_esp", "byte after ESP", got_byte, 8'h2F);
        if (errors == case_errors) $display("usb_quiet_in_esp: ok");
        else $display("usb_quiet_in_esp: FAIL");

        // ================= rxd_low_parks_switch =================
        // What parks a pending channel switch is the line, not the receiver:
        // port_idle needs rxd_f, so every clock the wire is low resets the
        // idle counter and the latch cannot move. A machine that chatters on
        // its TX wire therefore holds the switch off, and the switch lands one
        // budget after the line stops lying.
        // (The deserialiser takes no part in this case, and the comment says
        // so: arming the flip makes chan != channel, usb_own goes false on
        // that very clock, and from there no start bit is sampled at all. A
        // dead start bit being *rejected at mid-bit* is rx_bad_frame's claim;
        // here the pulses only have to be low clocks on the wire, which is
        // what they are.)
        case_errors = errors;
        do_reset;
        set_channel(1);
        // a frame first: it empties the idle counter, so the flip below is
        // armed with the budget still to run, not already saturated
        drive_frame(8'h5A, BIT_NS, 0.0, 1'b1);
        @(negedge clk);
        channel = 1'b0;                        // the OSD item moves
        // 24 low pulses, one every three quarters of a bit: each one shorter
        // than the switch budget, together longer than it, and each one
        // resetting the idle counter
        for (ci = 0; ci < 24; ci = ci + 1) begin
            rxd_drv = 1'b0;  repeat (CPB / 4) tick;
            rxd_drv = 1'b1;  repeat (CPB / 2) tick;
        end
        if (dut.chan !== 1'b1)
            bfail("rxd_low_parks_switch", "the flip landed through the low pulses",
                  dut.chan, 1'b1);
        // the line stops lying: from here a frame of quiet is owed
        rxd_drv = 1'b1;
        g = 0;
        while ((dut.chan !== 1'b0) && (g < IDLE_BUDGET + 2 * CPB)) begin
            tick;
            g = g + 1;
        end
        if (dut.chan !== 1'b0)
            bfail("rxd_low_parks_switch", "the low pulses froze the channel",
                  dut.chan, 1'b0);
        // the machine owns the port now: its wire drives the line
        esp_drive(1'b0, 1'b1, 3 * CPB);
        rxd_drv = 1'b1;
        if (errors == case_errors) $display("rxd_low_parks_switch: ok");
        else $display("rxd_low_parks_switch: FAIL");

        // ================= rxd_frame_parks_flip =================
        // The deserialiser is traffic on its own: it keeps sampling a frame it
        // started (only the start of a frame needs usb_own), and while it runs
        // rx_quiet is false, so the port is not idle even when the line is
        // high. That term is what this case is for, and the frame is chosen to
        // show it: 0xFE is start low, one low data bit, then seven ones and a
        // stop - one 3472-clock high run in the middle of a legal frame. With
        // rx_quiet the budget can only start after the stop bit; without it
        // the counter runs inside that high run and moves the latch 3472
        // clocks early, in the middle of a frame.
        case_errors = errors;
        do_reset;
        set_channel(1);
        fork
            drive_frame(8'hFE, BIT_NS, 0.0, 1'b1);
            begin
                repeat (2 * CPB - 100) tick;       // inside the start bit's low
                @(negedge clk);
                channel = 1'b0;                    // the OSD item moves now
                if (dut.rx_state === 3'd0)         // R_IDLE: no frame, no test
                    tfail("rxd_frame_parks_flip", "the frame was never in flight");
            end
        join
        // drive_frame returns a quarter bit after the stop bit: the
        // deserialiser has just counted the byte and the port is quiet from
        // about here, ~1500 clocks into the quiet the latch must still wait
        repeat (1300) tick;
        if (dut.chan !== 1'b1)
            bfail("rxd_frame_parks_flip", "the switch ran inside the frame's high tail",
                  dut.chan, 1'b1);
        g = 0;
        while ((dut.chan !== 1'b0) && (g < IDLE_BUDGET + 2 * CPB)) begin
            tick;
            g = g + 1;
        end
        if (dut.chan !== 1'b0)
            bfail("rxd_frame_parks_flip", "the frame outlived its own quiet",
                  dut.chan, 1'b0);
        // the machine owns the port now: its wire drives the line
        esp_drive(1'b0, 1'b1, 3 * CPB);
        set_channel(1);
        if (errors == case_errors) $display("rxd_frame_parks_flip: ok");
        else $display("rxd_frame_parks_flip: FAIL");

        // ================= push_before_flip =================
        // The strobe and the OSD item one clock apart, with the port
        // idle-saturated: `chan` is still the old channel on the flip clock,
        // so without the `chan == channel` term in usb_own the pop would fire
        // on that very edge and the byte would be shifted out onto the channel
        // that has just lost the port - off the FIFO and off the wire. With the
        // term the byte waits in the queue for the channel to come back.
        case_errors = errors;
        do_reset;
        set_channel(1);                          // idle_cnt is saturated
        // the strobe and the OSD item one clock apart, written out so that the
        // pop decision falls on the very edge that moves `chan`
        @(negedge clk);
        usb_tx_data = 8'hD5;
        usb_tx_wr   = 1'b1;
        @(negedge clk);                          // ... the push clock is here
        usb_tx_wr   = 1'b0;
        channel     = 1'b0;                      // one clock later: the flip
        repeat (12 * CPB) tick;                  // the machine has the port
        if (uart_txd !== 1'b1)
            bfail("push_before_flip", "the queued byte moved the wire channel",
                  uart_txd, 1'b1);
        if (usb_rx_idx !== 8'd0)
            ifail("push_before_flip", "usb_rx_idx", usb_rx_idx, 0);
        // the queue drains as soon as the channel is back and the port has
        // idled for a frame, so the receiver has to be listening already
        fork
            usb_recv(ferr, got_byte);            // the byte is still queued
            begin
                @(negedge clk);
                channel = 1'b1;
            end
        join
        if (ferr) tfail("push_before_flip", "the byte pushed before the flip was lost");
        else if (got_byte !== 8'hD5) ifail("push_before_flip", "byte", got_byte, 8'hD5);
        if (errors == case_errors) $display("push_before_flip: ok");
        else $display("push_before_flip: FAIL");

        // ================= uart_loop =================
        // The real ZXUNO uart (upstream/.../uart/uart.v) on its own 28 MHz and
        // 24 MHz clocks, against the router on 50 MHz. In channel 1 the Pi
        // plays the HPS: its frame must arrive as usb_rx_data, and a byte
        // pushed to the router must come back as a frame its receiver decodes.
        // In channel 0 the Pi is the machine on the wire: its frame is a level
        // stream that must arrive on esp_rx and must not be decoded, and a byte
        // pushed to the router must leave uart_txd alone.
        case_errors = errors;
        do_reset;
        idx_expect = 8'd0;
        for (ci = 0; ci < 2; ci = ci + 1) begin
            @(negedge clk);
            if (ci == 0) begin                              // 28 MHz clk_bus
                clk_pi_half = 1000.0 / 56.0;
                pi_ds80     = 1'b0;
            end else begin                                 // 24 MHz clk_bus
                clk_pi_half = 1000.0 / 48.0;
                pi_ds80     = 1'b1;
            end
            repeat (200) @(negedge clk);

            // ---- channel 1: the Pi is the HPS, on rxd_drv ----
            set_channel(1);
            for (cj = 0; cj < 4; cj = cj + 1) begin
                case (cj)
                    0: send_byte = 8'h00;
                    1: send_byte = 8'h5A;
                    2: send_byte = 8'hFF;
                    default: send_byte = 8'hA5;
                endcase
                idx_expect = idx_expect + 8'd1;
                if (cj == 0) begin
                    // the Pi's own transmitter, plugged onto the receive line:
                    // a real frame, not a hand-rolled level picture
                    pi_to_rxd = 1'b1;
                    pi_send(send_byte);
                end else begin
                    drive_pi_frame(send_byte);
                end
                cn = 0;
                while (usb_rx_idx !== idx_expect && cn < 12 * CPB) begin
                    @(negedge clk);
                    cn = cn + 1;
                end
                if (usb_rx_idx !== idx_expect)
                    ifail("uart_loop", "the Pi's frame never became a byte",
                          usb_rx_idx, idx_expect);
                else if (usb_rx_data !== send_byte)
                    ifail("uart_loop", "the received byte", usb_rx_data, send_byte);
                pi_to_rxd = 1'b0;
                // and the pushed byte is a frame the Pi's receiver decodes
                pw_clear();
                fork
                    pw_wait(got_byte, ferr);
                    usb_send(send_byte);
                join
                if (ferr) tfail("uart_loop", "the pushed byte never framed");
                else if (got_byte !== send_byte)
                    ifail("uart_loop", "the framed byte", got_byte, send_byte);
            end
            pi_to_rxd = 1'b0;

            // ---- channel 0: the Pi is the machine, on the wire ----
            // The Pi's TX goes out as esp_tx, the router passes it to
            // uart_txd, the loop plug brings uart_txd back to uart_rxd, and
            // the router's synchroniser drives esp_rx - which is also the
            // Pi's own receive pin. So the byte has to come back: edge
            // counting alone would accept a stream with the bits corrupted,
            // and the byte comparison is what says the levels were right.
            set_channel(0);
            pi_loop = 1'b1;                    // esp_tx is the Pi's TX
            // the Pi's receiver latched bytes off the wire in earlier cases
            // and nobody ever read them out: drain, or pi_recv returns a
            // byte from three cases back and says "ok" about the wrong thing
            pi_clear();
            if (pi_rxrecv === 1'b1) tfail("uart_loop", "the Pi never let go of a byte");
            for (cj = 0; cj < 2; cj = cj + 1) begin
                case (cj)
                    0: send_byte = 8'hC3;
                    default: send_byte = 8'h3C;
                endcase
                pw_clear();
                // its frame arrives on esp_rx as levels and is not decoded
                got_hps = 8'h00;
                ferr_b  = 1;
                fork
                    begin
                        e_sp = 0;
                        sp_last = esp_rx;
                        repeat (12 * CPB) begin
                            @(negedge clk);
                            if (esp_rx !== sp_last) begin
                                sp_last = esp_rx;
                                e_sp = e_sp + 1;
                            end
                        end
                    end
                    begin
                        repeat (2) @(negedge clk_pi);
                        pi_send(send_byte);
                        pi_recv(got_hps, ferr_b);   // round trip through the router
                    end
                join
                if (e_sp < 4) ifail("uart_loop", "esp_rx edges for a frame", e_sp, 4);
                if (ferr_b != 0)
                    tfail("uart_loop", "the frame never came back to the Pi");
                else if (got_hps !== send_byte)
                    ifail("uart_loop", "the byte back on esp_rx", got_hps, send_byte);
                if (usb_rx_idx !== idx_expect)
                    ifail("uart_loop", "the wire channel decoded a byte",
                          usb_rx_idx, idx_expect);
                // a byte pushed to the router never reaches the wire
                watch_level(1'b1, 4 * CPB, "uart_loop", "uart_txd during ESP");
                usb_send(send_byte);
                repeat (12 * CPB) @(negedge clk);
                if (uart_txd !== 1'b1)
                    bfail("uart_loop", "uart_txd moved while ESP", uart_txd, 1'b1);
            end
            pi_loop = 1'b0;
            if (errors != case_errors) ci = 2;              // one break is enough
        end
        if (errors == case_errors) $display("uart_loop: ok");
        else $display("uart_loop: FAIL");

        // ================= skewed_clock =================
        case_errors = errors;
        for (ci = 0; ci < 2; ci = ci + 1) begin
            do_reset;
            @(negedge clk);
            clk_half = (ci == 0) ? 10.2 : 9.8;    // +/-2 % on the clock period
            set_channel(1);
            drive_frame(8'hC3, BIT_NS, 0.0, 1'b1);
            expect_rx(8'hC3, 8'd1, "skewed_clock");
            usb_send(8'h81);
            usb_recv(ferr, got_byte);
            if (!ferr && got_byte !== 8'h81)
                ifail("skewed_clock", "usb byte out", got_byte, 8'h81);
            set_channel(0);
            esp_drive(1'b0, 1'b1, 40);
            esp_drive(1'b1, 1'b0, 40);
            rxd_drive(1'b0, 20, "skewed_clock");
            rxd_drive(1'b1, 20, "skewed_clock");
        end
        @(negedge clk);
        clk_half = 10.0;
        if (errors == case_errors) $display("skewed_clock: ok");
        else $display("skewed_clock: FAIL");

        // ---- verdict ----
        if (errors == 0)
            $display("tb_uart_route: PASS");
        else
            $display("tb_uart_route: FAIL %0d error(s)", errors);
        $finish;
    end

    // edge-counted global watchdog (no $time arithmetic); the whole run, the
    // two ZXUNO loopbacks included, stays far below this many clk_sys clocks.
    initial begin
        repeat (12000000) @(posedge clk);
        $display("tb_uart_route: FAIL global timeout");
        $finish;
    end

endmodule
