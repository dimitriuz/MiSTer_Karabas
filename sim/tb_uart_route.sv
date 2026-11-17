// Testbench for rtl/host/uart_route.sv, the stage 5 serial channel router:
// the ESP wire channel, the USB byte channel (8N1 at CLKS_PER_BIT clocks per
// bit) and the MidiLink priority.
//
// The clock is clk_sys, nominally 50 MHz (clk_half = 10 ns). The USB timing is
// measured in clock counts (CPB = CLKS_PER_BIT), so every case is independent
// of the real clock period; skewed_clock re-runs the paths with the period
// moved by +/-2 %.
//
// Sampling discipline: every task that reads a DUT output does it after
// `@(posedge clk); #1;` (the settled post-edge value) and every wait is a
// count of clock edges - no $time arithmetic anywhere, and the global
// watchdog counts edges too.
//
// Cases (each prints `<case>: ok` or `FAIL ...`):
//   esp_passthrough  channel 0: a level on esp_tx is on uart_txd exactly two
//                    clocks later (the two-flop synchroniser, no more, no
//                    less) and stays there; a level on uart_rxd reaches
//                    esp_rx 3..6 clocks later; all transitions of a pattern
//                    arrive and nothing else moves the line.
//   usb_tx_byte      channel 1: a usb_tx_wr strobe becomes one 8N1 frame - the
//                    mid-bit decode of 0x55, and the low-run lengths of 0x00
//                    (9 bits) and 0xFF (the start bit) pin CLKS_PER_BIT.
//   usb_rx_byte      channel 1: a frame on uart_rxd becomes usb_rx_data with
//                    usb_rx_idx incremented once per byte, while esp_rx stays
//                    idle high.
//   rx_bad_frame     a frame whose stop bit is low is dropped (no idx move),
//                    and a start bit that is gone before mid-bit is rejected;
//                    a good frame after either still arrives.
//   midi_priority    uart_mode 3: uart_txd == midi_line for both channels,
//                    immediately, even with a USB byte in flight.
//   idle_other_modes every mode but 3, both channels: uart_txd and esp_rx
//                    idle high with midi_line toggling, usb_rx_idx frozen.
//   switch_mid_byte  the channel flips while a byte is on the line: the frame
//                    finishes on the line it started on and only then does the
//                    mux follow the new channel; the same holds for a low
//                    esp_tx (the machine mid-frame) when switching to USB.
//   tx_backlog       40 strobes into a 16-byte FIFO: 17 bytes go out in order,
//                    the rest are dropped (newest lost), the line idles and a
//                    later byte still frames (no deadlock).
//   rx_noise         a one-clock glitch on uart_rxd, at varying phases, is
//                    majority-of-3 filter: esp_rx never blips, no frame
//                    starts, and the next good frame still arrives.
//   usb_quiet_in_esp bytes pushed while the ESP channel is selected produce no
//                    frame and no usb_rx activity; they drain in order when
//                    the USB channel is selected.
//   skewed_clock     the ESP path, a USB byte out and a byte in again with the
//                    clock period at +2 % and at -2 %.
//
// The last line printed is `tb_uart_route: PASS` or `tb_uart_route: FAIL
// <reason>`; run via sim/run_tb_uart_route.sh (iverilog -g2012).
`timescale 1ns / 1ps

module tb_uart_route;

    localparam integer CPB = 434;          // must match the module default

    // ---------------- clock ----------------
    reg  clk = 1'b0;
    real clk_half = 10.0;                  // 10.0 -> 50 MHz
    always begin
        #(clk_half) clk = ~clk;
    end

    // ---------------- DUT ----------------
    reg          reset      = 1'b1;
    reg          channel    = 1'b0;
    reg   [ 7:0] uart_mode  = 8'd0;
    reg          esp_tx     = 1'b1;
    reg          esp_cts    = 1'b1;
    wire         esp_rx;
    reg   [ 7:0] usb_tx_data = 8'h00;
    reg          usb_tx_wr  = 1'b0;
    wire  [ 7:0] usb_rx_data;
    wire  [ 7:0] usb_rx_idx;
    reg          uart_rxd   = 1'b1;
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
    integer i, j, k, g, n;
    integer ferr;
    integer got_len;
    integer idx_before;
    reg [7:0] got_byte;
    reg [7:0] badb;

    task bfail;
        input [8*28-1:0] name;
        input [8*32-1:0] what;
        input integer got;
        input integer want;
        begin
            $display("FAIL %0s %0s got %0b want %0b", name, what, got, want);
            errors = errors + 1;
        end
    endtask

    task ifail;
        input [8*28-1:0] name;
        input [8*32-1:0] what;
        input integer got;
        input integer want;
        begin
            $display("FAIL %0s %0s got %0d want %0d", name, what, got, want);
            errors = errors + 1;
        end
    endtask

    task tfail;
        input [8*28-1:0] name;
        input [8*32-1:0] what;
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

    // level for the next n clocks, every clock checked
    task watch_level;
        input        want;
        input integer n;
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

    task do_reset;
        begin
            @(negedge clk);
            reset      = 1'b1;
            channel    = 1'b0;
            uart_mode  = 8'd0;
            esp_tx     = 1'b1;
            esp_cts    = 1'b1;
            uart_rxd   = 1'b1;
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

    // ---- the ESP wire path ----
    // Drive esp_tx to `lvl` and check the two-flop latency exactly: one clock
    // after the drive the line still carries the old level, two clocks after
    // it carries the new one, and it never changes again during the hold.
    task esp_drive;
        input        lvl;
        input        old;
        input integer hold;
        integer k;
        begin
            @(negedge clk);
            esp_tx = lvl;
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

    // Drive uart_rxd to `lvl` and check esp_rx follows it 3..6 clocks later
    // (the synchroniser plus the registered output) and holds it.
    task rxd_drive;
        input        lvl;
        input integer hold;
        input [8*28-1:0] name;
        integer seen;
        begin
            @(negedge clk);
            uart_rxd = lvl;
            seen = 0;
            for (k = 1; k <= 6; k = k + 1) begin
                tick;
                if (esp_rx === lvl && seen == 0) seen = k;
            end
            if (seen < 3) tfail(name, "esp_rx changed too early (no synchroniser)");
            if (seen == 0) tfail(name, "esp_rx never followed uart_rxd");
            for (k = 0; k < hold; k = k + 1) begin
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
    // stop bit at the nominal mid-bit points.
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
                        got = {uart_txd, got[7:1]};   // LSB first
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

    // Drive one 8N1 frame on uart_rxd at the nominal bit rate.
    task drive_frame;
        input [7:0] b;
        integer k;
        begin
            @(negedge clk);
            uart_rxd = 1'b0;
            repeat (CPB) @(negedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_rxd = b[k];
                repeat (CPB) @(negedge clk);
            end
            uart_rxd = 1'b1;                    // stop
            repeat (CPB) @(negedge clk);
            repeat (4) @(negedge clk);
        end
    endtask

    // Drive only a low pulse on uart_rxd (a fake start bit), `low` clocks long.
    task rxd_pulse;
        input integer low;
        integer k;
        begin
            @(negedge clk);
            uart_rxd = 1'b0;
            for (k = 0; k < low; k = k + 1) @(negedge clk);
            uart_rxd = 1'b1;
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

    // ---------------- the run ----------------
    initial begin
        $display("tb_uart_route: CPB %0d", CPB);

        // ================= esp_passthrough =================
        case_errors = errors;
        do_reset;
        channel   = 1'b0;
        uart_mode = 8'd0;
        // the wire level crosses with the two-flop latency and holds
        esp_drive(1'b0, 1'b1, 40);
        esp_drive(1'b1, 1'b0, 40);
        // a whole pattern: every transition arrives, nothing else moves
        g = txd_edges;
        esp_drive(1'b0, 1'b1, 20);
        esp_drive(1'b1, 1'b0, 20);
        esp_drive(1'b0, 1'b1, 30);
        esp_drive(1'b0, 1'b0, 12);      // no transition: two equal levels
        esp_drive(1'b1, 1'b0, 25);
        repeat (6) tick;
        if (txd_edges != g + 4) ifail("esp_passthrough", "uart_txd edges", txd_edges, g + 4);
        // the other direction: uart_rxd -> esp_rx
        rxd_drive(1'b0, 30, "esp_rx_wire");
        rxd_drive(1'b1, 30, "esp_rx_wire");
        rxd_drive(1'b0, 14, "esp_rx_wire");
        rxd_drive(1'b1, 14, "esp_rx_wire");
        // a whole frame on the line while the ESP channel owns it: the wires are
        // never resampled here, so the byte channel must stay unfed. The frame
        // is a real one (it survives the mid-bit confirm), so a deserialiser
        // that ignored the channel would have counted it.
        drive_frame(8'h5A);
        repeat (2 * CPB) tick;
        if (usb_rx_idx !== 8'd0)
            ifail("esp_passthrough", "usb_rx_idx fed while ESP", usb_rx_idx, 0);
        if (errors == case_errors) $display("esp_passthrough: ok");
        else $display("esp_passthrough: FAIL");

        // ================= usb_tx_byte =================
        case_errors = errors;
        do_reset;
        channel = 1'b1;
        usb_send(8'h55);
        usb_recv(ferr, got_byte);
        if (!ferr && got_byte !== 8'h55) ifail("usb_tx_byte", "0x55 mid-bit decode", got_byte, 8'h55);
        // 0x00: start + 8 zero bits are low, so the low run is 9 bit times
        usb_send(8'h00);
        measure_low(ferr, got_len);
        if (!ferr && (got_len < 9 * CPB - 3 || got_len > 9 * CPB + 3))
            ifail("usb_tx_byte", "0x00 low run != 9 bits", got_len, 9 * CPB);
        // 0xFF: only the start bit is low
        usb_send(8'hFF);
        measure_low(ferr, got_len);
        if (!ferr && (got_len < CPB - 3 || got_len > CPB + 3))
            ifail("usb_tx_byte", "0xFF low run != 1 bit", got_len, CPB);
        // then the line idles high again
        watch_level(1'b1, 3 * CPB, "usb_tx_byte", "idle after the frame");
        if (errors == case_errors) $display("usb_tx_byte: ok");
        else $display("usb_tx_byte: FAIL");

        // ================= usb_rx_byte =================
        case_errors = errors;
        do_reset;
        channel = 1'b1;
        // esp_rx stays idle for the whole frame while the byte channel owns the
        fork
            drive_frame(8'hA5);
            begin
                n = 0;
                while (n < 11 * CPB) begin
                    tick;
                    n = n + 1;
                    if (esp_rx !== 1'b1)
                        bfail("usb_rx_byte", "esp_rx fed while USB", esp_rx, 1'b1);
                end
            end
        join
        expect_rx(8'hA5, 8'd1, "usb_rx_byte");
        drive_frame(8'h3C);
        expect_rx(8'h3C, 8'd2, "usb_rx_byte");
        drive_frame(8'h00);
        expect_rx(8'h00, 8'd3, "usb_rx_byte");
        // the ESP output must have stayed idle the whole time
        if (esp_rx !== 1'b1) bfail("usb_rx_byte", "esp_rx idle", esp_rx, 1'b1);
        if (errors == case_errors) $display("usb_rx_byte: ok");
        else $display("usb_rx_byte: FAIL");

        // ================= rx_bad_frame =================
        case_errors = errors;
        do_reset;
        channel = 1'b1;
        // a frame with the stop bit low: dropped, nothing counted
        @(negedge clk);
        uart_rxd = 1'b0;
        repeat (CPB) @(negedge clk);
        badb = 8'h55;
        for (k = 0; k < 8; k = k + 1) begin
            uart_rxd = badb[k];
            repeat (CPB) @(negedge clk);
        end
        uart_rxd = 1'b0;                       // stop bit low
        repeat (CPB) @(negedge clk);
        uart_rxd = 1'b1;
        repeat (2 * CPB) @(negedge clk);
        #1;
        if (usb_rx_idx !== 8'd0) ifail("rx_bad_frame", "idx after a bad stop", usb_rx_idx, 0);
        // a start bit that is gone before mid-bit: rejected as noise
        rxd_pulse(20);
        repeat (11 * CPB) @(negedge clk);
        #1;
        if (usb_rx_idx !== 8'd0) ifail("rx_bad_frame", "idx after a fake start", usb_rx_idx, 0);
        // and the deserialiser still works
        drive_frame(8'h96);
        expect_rx(8'h96, 8'd1, "rx_bad_frame");
        if (errors == case_errors) $display("rx_bad_frame: ok");
        else $display("rx_bad_frame: FAIL");

        // ================= midi_priority =================
        case_errors = errors;
        for (i = 0; i < 2; i = i + 1) begin
            do_reset;
            channel    = i[0];
            uart_mode  = 8'd3;
            esp_tx     = 1'b0;                 // the wire channel must be ignored
            for (j = 0; j < 4; j = j + 1) begin
                @(negedge clk);
                midi_line = j[0];
                #1;
                if (uart_txd !== midi_line)
                    bfail("midi_priority", "uart_txd != midi_line", uart_txd, midi_line);
            end
            // immediately, even with a USB byte in flight
            midi_line = 1'b1;
            usb_send(8'hF0);
            repeat (3 * CPB / 2) tick;         // a bit and a half into the frame
            @(negedge clk);
            uart_mode = 8'd3;
            #1;
            if (uart_txd !== 1'b1) bfail("midi_priority", "idle midi line", uart_txd, 1'b1);
            @(negedge clk);
            midi_line = 1'b0;
            #1;
            if (uart_txd !== 1'b0) bfail("midi_priority", "midi 0 over a frame", uart_txd, 1'b0);
            @(negedge clk);
            midi_line = 1'b1;
            #1;
            if (uart_txd !== 1'b1) bfail("midi_priority", "midi 1 over a frame", uart_txd, 1'b1);
        end
        if (errors == case_errors) $display("midi_priority: ok");
        else $display("midi_priority: FAIL");

        // ================= idle_other_modes =================
        case_errors = errors;
        for (i = 0; i < 5; i = i + 1) begin
            for (j = 0; j < 2; j = j + 1) begin
                do_reset;
                case (i)
                    0: uart_mode = 8'd0;
                    1: uart_mode = 8'd1;
                    2: uart_mode = 8'd2;
                    3: uart_mode = 8'd4;
                    default: uart_mode = 8'd5;
                endcase
                channel = j[0];
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
        // USB byte in flight, switch to ESP: the frame finishes on the line
        do_reset;
        channel = 1'b1;
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
        // after the stop bit the line must follow esp_tx
        watch_level(1'b1, CPB + 8, "switch_mid_byte", "line high after the stop");
        esp_drive(1'b0, 1'b1, 30);             // esp_tx now reaches the line
        esp_drive(1'b1, 1'b0, 30);
        // ESP wire low, switch to USB: the line stays where esp_tx has it
        do_reset;
        channel = 1'b0;
        @(negedge clk);
        esp_tx = 1'b0;                         // the machine mid-frame
        repeat (8) tick;
        @(negedge clk);
        channel = 1'b1;                        // flip while esp_tx is low
        watch_level(1'b0, 5 * CPB, "switch_mid_byte", "esp_tx still owns the line");
        @(negedge clk);
        esp_tx = 1'b1;
        g = 0;
        while (uart_txd === 1'b0 && g < 12) begin
            tick;
            g = g + 1;
        end
        if (uart_txd !== 1'b1) tfail("switch_mid_byte", "the line never came back to USB");
        else if (g < 1 || g > 6) ifail("switch_mid_byte", "latency back", g, 4);
        if (errors == case_errors) $display("switch_mid_byte: ok");
        else $display("switch_mid_byte: FAIL");

        // ================= tx_backlog =================
        case_errors = errors;
        do_reset;
        channel = 1'b1;
        // 40 strobes, one clock apart: 1 in the shifter + 16 in the FIFO, the
        // rest dropped (the newest byte is lost), never a stall
        for (i = 0; i < 40; i = i + 1) begin
            @(negedge clk);
            usb_tx_data = 8'h10 + i[7:0];
            usb_tx_wr   = 1'b1;
        end
        @(negedge clk);
        usb_tx_wr = 1'b0;
        for (i = 0; i < 17; i = i + 1) begin
            usb_recv(ferr, got_byte);
            if (!ferr && got_byte !== (8'h10 + i[7:0]))
                ifail("tx_backlog", "framed byte out of order", got_byte, 8'h10 + i);
        end
        // nothing else follows: the 23 lost bytes never appear
        watch_level(1'b1, 3 * CPB, "tx_backlog", "line idle after the 17 bytes");
        // and the module still takes a new byte
        usb_send(8'hEE);
        usb_recv(ferr, got_byte);
        if (!ferr && got_byte !== 8'hEE) ifail("tx_backlog", "byte after the backlog", got_byte, 8'hEE);
        if (errors == case_errors) $display("tx_backlog: ok");
        else $display("tx_backlog: FAIL");

        // ================= rx_noise =================
        case_errors = errors;
        // ESP channel: the glitch must not reach esp_rx at all
        do_reset;
        channel = 1'b0;
        for (i = 0; i < 4; i = i + 1) begin
            repeat (11 + 37 * i) @(negedge clk);  // glitches at varying phases
            @(negedge clk);
            uart_rxd = 1'b0;
            @(negedge clk);
            uart_rxd = 1'b1;
            n = 0;
            while (n < 8 * CPB) begin
                tick;
                n = n + 1;
                if (esp_rx !== 1'b1) bfail("rx_noise", "esp_rx blipped", esp_rx, 1'b1);
            end
        end
        // USB channel: no frame starts, and the next good frame still arrives
        do_reset;
        channel = 1'b1;
        for (i = 0; i < 4; i = i + 1) begin
            repeat (7 + 53 * i) @(negedge clk);   // glitches at varying phases
            @(negedge clk);
            uart_rxd = 1'b0;
            @(negedge clk);
            uart_rxd = 1'b1;
            n = 0;
            while (n < 4 * CPB) begin
                tick;
                n = n + 1;
                if (uart_txd !== 1'b1) bfail("rx_noise", "usb line low", uart_txd, 1'b1);
            end
        end
        if (usb_rx_idx !== 8'd0) ifail("rx_noise", "idx after noise", usb_rx_idx, 0);
        drive_frame(8'h5A);
        expect_rx(8'h5A, 8'd1, "rx_noise");
        if (errors == case_errors) $display("rx_noise: ok");
        else $display("rx_noise: FAIL");

        // ================= usb_quiet_in_esp =================
        case_errors = errors;
        do_reset;
        channel = 1'b0;                        // the ESP channel is selected
        for (i = 0; i < 4; i = i + 1) usb_send(8'h40 + i[7:0]);
        watch_level(1'b1, 6 * CPB, "usb_quiet_in_esp", "no USB byte while ESP");
        if (usb_rx_idx !== 8'd0) ifail("usb_quiet_in_esp", "usb_rx_idx", usb_rx_idx, 0);
        if (esp_rx !== 1'b1) bfail("usb_quiet_in_esp", "esp_rx idle", esp_rx, 1'b1);
        // switching to USB drains the queue in order
        @(negedge clk);
        channel = 1'b1;
        for (i = 0; i < 4; i = i + 1) begin
            usb_recv(ferr, got_byte);
            if (!ferr && got_byte !== (8'h40 + i[7:0]))
                ifail("usb_quiet_in_esp", "queued byte", got_byte, 8'h40 + i);
        end
        watch_level(1'b1, 2 * CPB, "usb_quiet_in_esp", "drained");
        if (errors == case_errors) $display("usb_quiet_in_esp: ok");
        else $display("usb_quiet_in_esp: FAIL");

        // ================= skewed_clock =================
        case_errors = errors;
        for (i = 0; i < 2; i = i + 1) begin
            do_reset;
            @(negedge clk);
            clk_half = (i == 0) ? 10.2 : 9.8;   // +/-2 % on the clock period
            channel  = 1'b1;
            drive_frame(8'hC3);
            expect_rx(8'hC3, 8'd1, "skewed_clock");
            usb_send(8'h81);
            usb_recv(ferr, got_byte);
            if (!ferr && got_byte !== 8'h81)
                ifail("skewed_clock", "usb byte out", got_byte, 8'h81);
            @(negedge clk);
            channel = 1'b0;
            repeat (CPB) tick;
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

    // edge-counted global watchdog (no $time arithmetic); the whole run is far
    // below this many clk_sys clocks.
    initial begin
        repeat (4000000) @(posedge clk);
        $display("tb_uart_route: FAIL global timeout");
        $finish;
    end

endmodule
