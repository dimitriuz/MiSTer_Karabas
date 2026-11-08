// Testbench for rtl/sound/mt32_mix.sv, the MT32-pi audio mix, the MIDI TX
// mute for a disabled Pi and the MidiLink UART route.
//
// The audio path: emu_l/r cross into CLK_AUDIO through two registers, then a
// third register holds sat16(emu_s2 + (pi_on ? pi : 0)). A case drives its
// inputs on a falling edge and samples audio_l/r on the 3rd rising edge after
// that drive (with a 1 ns settle, so the register update is visible).
//
// Cases (each prints `<case>: ok` or `FAIL ...`):
//   pi_absent    available = 0, random emu and pi values: audio == emu;
//   pi_on        available, enabled: audio_l/r are the sums of both sources;
//   sat_up       0x7000 + 0x7000 clips to 0x7FFF;
//   sat_down     -0x7000 + -0x7000 clips to 0x8000;
//   pi_disabled  available but disabled: audio == emu (pi ignored) and
//                midi_tx_to_pi stays 1 while midi_tx toggles;
//   midi_pass    available and enabled: midi_tx_to_pi == midi_tx;
//   uart_route   uart_mode 0/1/2/4: uart_txd idles high while midi_tx
//                toggles; uart_mode 3: uart_txd == midi_tx, with the Pi
//                disabled as well as enabled.
//
// The last line printed is `tb_mt32_mix: PASS` or `tb_mt32_mix: FAIL <reason>`;
// run via sim/run_tb_mt32_mix.sh (iverilog -g2012).
`timescale 1ns / 1ps

module tb_mt32_mix;

    // ---------------- clock ----------------
    reg clk = 1'b0;
    always #20.345 clk = ~clk;                 // 24.576 MHz, 40.69 ns

    // ---------------- DUT ----------------
    reg signed [15:0] emu_l = 16'sd0, emu_r = 16'sd0;
    reg signed [15:0] pi_l  = 16'sd0, pi_r  = 16'sd0;
    reg               pi_available = 1'b0;
    reg               pi_disable   = 1'b0;
    reg               midi_tx      = 1'b1;
    reg        [ 7:0] uart_mode    = 8'd0;
    wire signed [15:0] audio_l, audio_r;
    wire               midi_tx_to_pi;
    wire               uart_txd;

    mt32_mix dut (
        .clk(clk),
        .emu_l(emu_l), .emu_r(emu_r),
        .pi_l(pi_l), .pi_r(pi_r),
        .pi_available(pi_available),
        .pi_disable(pi_disable),
        .midi_tx(midi_tx),
        .uart_mode(uart_mode),
        .audio_l(audio_l), .audio_r(audio_r),
        .midi_tx_to_pi(midi_tx_to_pi),
        .uart_txd(uart_txd)
    );

    // ---------------- helpers ----------------
    integer errors = 0;
    integer case_errors;
    integer i, j;
    integer seed;
    reg [15:0] rnd;

    task afail;
        input [8*32-1:0] name;
        input [8*8-1:0]  what;
        input signed [15:0] got;
        input signed [15:0] want;
        begin
            $display("FAIL %0s %0s got %04h want %04h", name, what, got, want);
            errors = errors + 1;
        end
    endtask

    // Drive the audio inputs and pi flags on a falling edge, then sample on
    // the 3rd rising edge (two sync registers + the audio output register).
    task audio_case;
        input signed [15:0] el;
        input signed [15:0] er;
        input signed [15:0] pl;
        input signed [15:0] pr;
        input avail;
        input pi_off;
        begin
            @(negedge clk);
            emu_l = el; emu_r = er; pi_l = pl; pi_r = pr;
            pi_available = avail; pi_disable = pi_off;
            repeat (3) @(posedge clk);
            #1;
        end
    endtask

    task mfail;
        input [8*32-1:0] name;
        input [8*8-1:0]  what;
        input got;
        input want;
        begin
            $display("FAIL %0s %0s got %b want %b", name, what, got, want);
            errors = errors + 1;
        end
    endtask

    // ---------------- the run ----------------
    initial begin
        seed = 32'h4D543233;
        $display("tb_mt32_mix: seed %08h", seed);

        // ---- pi_absent: the Pi's samples never reach the mix ----
        case_errors = errors;
        for (i = 0; i < 8; i = i + 1) begin
            rnd = $urandom(seed); emu_l = rnd;
            rnd = $urandom(seed); emu_r = rnd;
            rnd = $urandom(seed); pi_l  = rnd;
            rnd = $urandom(seed); pi_r  = rnd;
            audio_case(emu_l, emu_r, pi_l, pi_r, 1'b0, 1'b0);
            if (audio_l !== emu_l) afail("pi_absent", "audio_l", audio_l, emu_l);
            if (audio_r !== emu_r) afail("pi_absent", "audio_r", audio_r, emu_r);
        end
        if (errors == case_errors) $display("pi_absent: ok");
        else $display("pi_absent: FAIL");

        // ---- pi_on: both sources sum ----
        case_errors = errors;
        audio_case(16'sh1000, -16'sh1000, 16'sh2000, 16'sh0800, 1'b1, 1'b0);
        if (audio_l !== 16'sh3000) afail("pi_on", "audio_l", audio_l, 16'sh3000);
        if (audio_r !== -16'sh0800) afail("pi_on", "audio_r", audio_r, -16'sh0800);
        if (errors == case_errors) $display("pi_on: ok");
        else $display("pi_on: FAIL");

        // ---- sat_up: 0x7000 + 0x7000 clips to 0x7FFF ----
        case_errors = errors;
        audio_case(16'sh7000, 16'sh7000, 16'sh7000, 16'sh7000, 1'b1, 1'b0);
        if (audio_l !== 16'sh7FFF) afail("sat_up", "audio_l", audio_l, 16'sh7FFF);
        if (audio_r !== 16'sh7FFF) afail("sat_up", "audio_r", audio_r, 16'sh7FFF);
        if (errors == case_errors) $display("sat_up: ok");
        else $display("sat_up: FAIL");

        // ---- sat_down: -0x7000 + -0x7000 clips to 0x8000 ----
        case_errors = errors;
        audio_case(-16'sh7000, -16'sh7000, -16'sh7000, -16'sh7000, 1'b1, 1'b0);
        if (audio_l !== 16'sh8000) afail("sat_down", "audio_l", audio_l, 16'sh8000);
        if (audio_r !== 16'sh8000) afail("sat_down", "audio_r", audio_r, 16'sh8000);
        if (errors == case_errors) $display("sat_down: ok");
        else $display("sat_down: FAIL");

        // ---- pi_disabled: audio is the emulator's, the Pi sees an idle TX ----
        case_errors = errors;
        audio_case(16'sh1234, -16'sh1234, 16'sh7000, -16'sh7000, 1'b1, 1'b1);
        if (audio_l !== 16'sh1234) afail("pi_disabled", "audio_l", audio_l, 16'sh1234);
        if (audio_r !== -16'sh1234) afail("pi_disabled", "audio_r", audio_r, -16'sh1234);
        for (j = 0; j < 4; j = j + 1) begin
            midi_tx = j[0];
            #1;
            if (midi_tx_to_pi !== 1'b1)
                mfail("pi_disabled", "midi_tx_to_pi", midi_tx_to_pi, 1'b1);
        end
        if (errors == case_errors) $display("pi_disabled: ok");
        else $display("pi_disabled: FAIL");

        // ---- midi_pass: an enabled Pi gets the emulator's TX line ----
        case_errors = errors;
        pi_available = 1'b1; pi_disable = 1'b0;
        for (j = 0; j < 4; j = j + 1) begin
            midi_tx = j[0];
            #1;
            if (midi_tx_to_pi !== midi_tx)
                mfail("midi_pass", "midi_tx_to_pi", midi_tx_to_pi, midi_tx);
        end
        if (errors == case_errors) $display("midi_pass: ok");
        else $display("midi_pass: FAIL");

        // ---- uart_route: only mode 3 (MIDI) carries the line ----
        case_errors = errors;
        for (i = 0; i < 5; i = i + 1) begin
            case (i)
                0: uart_mode = 8'd0;
                1: uart_mode = 8'd1;
                2: uart_mode = 8'd2;
                3: uart_mode = 8'd3;
                default: uart_mode = 8'd4;
            endcase
            for (j = 0; j < 2; j = j + 1) begin
                // the route must not depend on the Pi: disabled and enabled
                pi_available = 1'b1; pi_disable = j[0];
                midi_tx = 1'b0;
                #1;
                if (uart_mode == 8'd3) begin
                    if (uart_txd !== 1'b0)
                        mfail("uart_route", "uart_txd mode 3 midi_tx 0", uart_txd, 1'b0);
                end else begin
                    if (uart_txd !== 1'b1)
                        mfail("uart_route", "uart_txd other mode midi_tx 0", uart_txd, 1'b1);
                end
                midi_tx = 1'b1;
                #1;
                if (uart_mode == 8'd3) begin
                    if (uart_txd !== 1'b1)
                        mfail("uart_route", "uart_txd mode 3 midi_tx 1", uart_txd, 1'b1);
                end else begin
                    if (uart_txd !== 1'b1)
                        mfail("uart_route", "uart_txd other mode midi_tx 1", uart_txd, 1'b1);
                end
            end
        end
        if (errors == case_errors) $display("uart_route: ok");
        else $display("uart_route: FAIL");

        // ---- verdict ----
        if (errors == 0)
            $display("tb_mt32_mix: PASS");
        else
            $display("tb_mt32_mix: FAIL %0d error(s)", errors);
        $finish;
    end

    // edge-counted global watchdog (no $time arithmetic: unreliable in deep
    // Icarus runs); well above the whole run.
    initial begin
        repeat (200000) @(posedge clk);
        $display("tb_mt32_mix: FAIL global timeout");
        $finish;
    end

endmodule