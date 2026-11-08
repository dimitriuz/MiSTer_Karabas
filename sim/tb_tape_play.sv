// Testbench for the tape player chain: rtl/tape/tape.sv (the ZX core's
// player, verbatim rtl/tape/tzxplayer.vhd through GHDL synthesis) reading
// through rtl/tape/tape_src.sv (the file image from the SD card, modeled by
// sim/models/sd_img_model.sv). It decodes what the player puts on
// `audio_out` the way the Spectrum ROM loader does, in `ce` ticks:
// pilot pulses are >= 2000 ticks, then the two sync pulses, then each bit is
// a pulse pair (855+855 T is a 0, 1710+1710 T is a 1; the pair sum 2400
// separates them). The decoded bytes must equal the TAP blocks' flag + data
// + checksum bytes, both blocks, byte for byte and byte for byte count.
//
// Cases:
//   tap_decode, tzx_decode, csw_decode
//                          hello mounted as TAP / TZX / CSW, ce every clock
//                          (turbo 8x: ena_cpu follows the enable - the
//                          brief's ce_follows_enable condition). Per ruling 4
//                          the decode cases all run at this rate: the pulse
//                          lengths in ce ticks are what the ROM sees,
//                          independent of the clk/ce ratio.
//   ce_1in8_pilot          ce one clock in eight (turbo off, 3.5 MHz on
//                          28.125 MHz), TAP: two mid-pilot pulse intervals
//                          must be 2168 +- 1 ce ticks.
//
// `pause` must be pulsed after the mount: tape.sv parks play_pause = 1 while
// tape_ready is low (a freshly mounted tape is paused), and both the TAP
// decoder and the TZX motor wait for it. Task 4 depends on that.
//
// The last line printed is `tb_tape_play: PASS` or
// `tb_tape_play: FAIL <reason>`; run via sim/run_tb_tape_play.sh.
`timescale 1ns / 1ps
`default_nettype none

module tb_tape_play;

    // ---------------- clocks ----------------
    reg clk_sys = 1'b0;                     // hps_io / tape_src SD side, 50 MHz
    always #10 clk_sys = ~clk_sys;

    reg clk = 1'b0;                         // CLK_BUS, 28.125 MHz
    always #17.7778 clk = ~clk;

    // ce: every clock (turbo 8x) or one in eight (turbo off)
    reg  ce_1in8 = 1'b0;
    reg  [2:0] ce_cnt = 3'd0;
    always @(posedge clk) ce_cnt <= ce_cnt + 3'd1;
    wire ce = !ce_1in8 || (ce_cnt == 3'd0);

    // ---------------- DUTs ----------------
    reg         img_mounted = 1'b0;
    reg  [63:0] img_size = 64'd0;
    wire [31:0] sd_lba;
    wire        sd_rd;
    wire        sd_ack;
    wire  [8:0] sd_buff_addr;
    wire  [7:0] sd_buff_dout;
    wire        sd_buff_wr;

    wire        tape_ready;
    wire  [1:0] tape_mode;
    wire [24:0] tape_size;
    wire        tape_rd;
    wire [24:0] tape_addr;
    wire  [7:0] tape_din;
    wire        tape_rd_en;

    reg         pause = 1'b0;

    reg         audio_out;

    tape_src u_tape_src (
        .clk_sys(clk_sys),
        .img_mounted(img_mounted),
        .img_size(img_size),
        .sd_lba(sd_lba),
        .sd_rd(sd_rd),
        .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr),
        .sd_buff_dout(sd_buff_dout),
        .sd_buff_wr(sd_buff_wr),
        .clk(clk),
        .tape_ready(tape_ready),
        .tape_mode(tape_mode),
        .tape_size(tape_size),
        .rd(tape_rd),
        .addr(tape_addr),
        .din(tape_din),
        .rd_en(tape_rd_en)
    );

    sd_img_model #(.LAT_CLKS(1000)) sd_model (
        .clk(clk_sys),
        .lba(sd_lba),
        .rd(sd_rd),
        .ack(sd_ack),
        .buff_addr(sd_buff_addr),
        .buff_dout(sd_buff_dout),
        .buff_wr(sd_buff_wr),
        .size(img_size[31:0]),
        .past_end()
    );

    tape u_tape (
        .clk_sys(clk),
        .ce(ce),
        .mode48k(1'b0),
        .turbo(1'b0),
        .byte_wait(1'b0),
        .byte_ready(),
        .dout(),
        .pause(pause),
        .prev(1'b0),
        .next(1'b0),
        .active(),
        .available(),
        .tape_ready(tape_ready),
        .tape_mode(tape_mode),
        .tape_size(tape_size),
        .stdload(1'b0),
        .req_hdr(1'b0),
        .audio_out(audio_out),
        .rd_en(tape_rd_en),
        .rd(tape_rd),
        .addr(tape_addr),
        .din(tape_din)
    );

    // ---------------- audio_out edges in ce ticks ----------------
    // An edge seen at a ce is one tick late (tape.sv updates audio_out with
    // a nonblocking assign at that same edge), so the interval is tick - 1.
    // Unknown (X) levels while the synthesized TZX player powers up are
    // skipped: only a known-to-known change counts.
    integer tick = 0;
    reg     audio_d = 1'b1;
    integer fifo [0:1023];
    integer fifo_w = 0, fifo_r = 0;
    integer edge_tick;

    always @(posedge clk) begin
        if (ce) begin
            tick = tick + 1;
            if ((audio_out === 1'b0 || audio_out === 1'b1) &&
                (audio_d === 1'b0 || audio_d === 1'b1) &&
                (audio_out !== audio_d)) begin
                edge_tick = tick - 1;
                fifo[fifo_w % 1024] = edge_tick < 0 ? 0 : edge_tick;
                fifo_w = fifo_w + 1;
                tick = 0;
            end
            audio_d = audio_out;
        end
    end

    // ---------------- reference: the TAP blocks ----------------
    reg  [7:0] tap_ref [0:16383];
    reg  [7:0] ref_bytes [0:255];
    integer block_len [0:7];
    integer nblocks = 0;
    integer nref = 0;
    integer ref_pos = 0;

    task load_reference;
        integer p, n, j;
        begin
            $readmemh("build/sim/hello.tap.hex", tap_ref, 0, 57);
            p = 0;
            nblocks = 0;
            nref = 0;
            while (p < 58 && nblocks < 8) begin
                n = tap_ref[p] + (tap_ref[p + 1] << 8);
                p = p + 2;
                for (j = 0; j < n; j = j + 1) begin
                    ref_bytes[nref] = tap_ref[p + j];
                    nref = nref + 1;
                end
                block_len[nblocks] = n;
                nblocks = nblocks + 1;
                p = p + n;
            end
        end
    endtask

    // ---------------- result helpers ----------------
    integer errors = 0;
    integer shown = 0;
    integer case_errors;
    reg     dead = 1'b0;

    task fail_int(input [8*32-1:0] name, input [8*32-1:0] what,
                  input integer got, input integer want);
        begin
            if (got !== want) begin
                if (shown < 8)
                    $display("FAIL %0s %0s got %0d want %0d", name, what, got, want);
                else if (shown == 8)
                    $display("FAIL %0s more failures follow (not printed)", name);
                shown = shown + 1;
                errors = errors + 1;
            end
        end
    endtask

    // ---------------- the pulse stream ----------------
    task get_interval(output integer p);
        integer waited;
        begin
            waited = 0;
            while (fifo_w == fifo_r && !dead) begin
                @(posedge clk);
                waited = waited + 1;
                if (waited > 12000000) begin
                    $display("FAIL timeout waiting for a tape edge");
                    errors = errors + 1;
                    dead = 1'b1;
                end
            end
            if (dead) p = 0;
            else begin
                p = fifo[fifo_r % 1024];
                fifo_r = fifo_r + 1;
            end
        end
    endtask

    // One TAP-style block: pilot pulses (>= 2000 ticks), sync1, sync2, then
    // `n` bytes of pulse pairs. The decoded bytes are compared against the
    // TAP reference from ref_pos on.
    task decode_block(input integer n, input [8*24-1:0] name);
        integer p1, p2, i, b, v;
        begin
            get_interval(p1);
            // skip start-up junk and then every pilot pulse
            while (!dead && p1 < 2000) get_interval(p1);
            while (!dead && p1 >= 2000) get_interval(p1);
            fail_int(name, "sync1", (p1 >= 300 && p1 <= 1500) ? 1 : 0, 1);
            get_interval(p2);
            fail_int(name, "sync2", (p2 >= 300 && p2 <= 1500) ? 1 : 0, 1);
            for (i = 0; i < n && !dead; i = i + 1) begin
                v = 0;
                for (b = 7; b >= 0; b = b - 1) begin
                    get_interval(p1);
                    get_interval(p2);
                    v = (v << 1) | ((p1 + p2) > 2400 ? 1 : 0);
                end
                fail_int(name, "byte", v, ref_bytes[ref_pos]);
                ref_pos = ref_pos + 1;
            end
        end
    endtask

    // ---------------- mounting and playback ----------------
    task reset_playback;
        begin
            dead = 1'b0;
            fifo_w = 0;
            fifo_r = 0;
            tick = 0;
            audio_d = audio_out;
        end
    endtask

    task mount_file(input [31:0] sz, input [8*64-1:0] hexf);
        begin
            $readmemh(hexf, sd_model.mem, 0, sz - 1);
            img_size = sz;
            @(posedge clk_sys);
            img_mounted = 1'b1;
            @(posedge clk_sys);
            img_mounted = 1'b0;
        end
    endtask

    task wait_ready;
        begin
            @(posedge clk); #1;
            while (tape_ready) begin           // the mount drops it first
                @(posedge clk); #1;
            end
            while (!tape_ready) begin
                @(posedge clk); #1;
            end
            repeat (4) @(posedge clk);
        end
    endtask

    // play_pause is 1 after a mount; one pulse starts playback
    task start_play;
        begin
            @(posedge clk);
            pause = 1'b1;
            repeat (16) @(posedge clk);
            pause = 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    // mount, check the sniff result, start and decode both TAP blocks
    task decode_tape(input [8*24-1:0] name, input [31:0] sz,
                     input [8*64-1:0] hexf, input [1:0] mode_want);
        integer b;
        begin
            case_errors = errors;
            shown = 0;
            reset_playback();
            mount_file(sz, hexf);
            wait_ready();
            fail_int(name, "mode", tape_mode, mode_want);
            fail_int(name, "size", tape_size, sz);
            reset_playback();
            ref_pos = 0;
            start_play();
            for (b = 0; b < nblocks; b = b + 1)
                decode_block(block_len[b], name);
            fail_int(name, "decoded bytes", ref_pos, nref);
            if (errors == case_errors && !dead) $display("%0s: ok", name);
            else $display("%0s: FAIL", name);
        end
    endtask

    // ---------------- the run ----------------
    integer p1, p2;

    initial begin
        $display("tb_tape_play: start");
        // tape.sv's tzx_ack is a register with no reset value; Quartus powers
        // it up as 0, Icarus starts it as X, which makes the synthesized TZX
        // player's `tzx_req = tzx_ack` comparison X and its whole state
        // machine X. Model the hardware power-up value for the simulation.
        u_tape.tzx_ack = 1'b0;
        load_reference();
        fail_int("reference", "blocks", nblocks, 2);
        fail_int("reference", "block 0 len", nblocks > 0 ? block_len[0] : 0, 19);
        fail_int("reference", "block 1 len", nblocks > 1 ? block_len[1] : 0, 35);
        fail_int("reference", "bytes", nref, 54);

        // ce every clock for every decode case (turbo 8x): the pulse lengths
        // in ce ticks are what the ROM sees, independent of clk/ce.
        ce_1in8 = 1'b0;

        decode_tape("tap_decode", 32'd58, "build/sim/hello.tap.hex", 2'd0);
        decode_tape("tzx_decode", 32'd74, "build/sim/hello.tzx.hex", 2'd2);
        decode_tape("csw_decode", 32'd12196, "build/sim/hello.csw.hex", 2'd1);

        // the ratio case: turbo off (ce 1 in 8), the pilot is 2168 ce ticks
        case_errors = errors;
        shown = 0;
        ce_1in8 = 1'b1;
        reset_playback();
        mount_file(32'd58, "build/sim/hello.tap.hex");
        wait_ready();
        reset_playback();
        start_play();
        get_interval(p1);
        while (!dead && p1 < 2000) get_interval(p1);
        get_interval(p1);
        get_interval(p2);
        fail_int("ce_1in8_pilot", "pilot interval",
                 (p1 >= 2167 && p1 <= 2169) ? 1 : 0, 1);
        if (p1 < 2167 || p1 > 2169) $display("ce_1in8_pilot: got %0d", p1);
        if (errors == case_errors && !dead) $display("ce_1in8_pilot: ok");
        else $display("ce_1in8_pilot: FAIL");

        if (errors == 0) $display("tb_tape_play: PASS");
        else $display("tb_tape_play: FAIL %0d errors", errors);
        $finish;
    end

endmodule

`default_nettype wire