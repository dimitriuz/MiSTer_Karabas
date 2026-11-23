// Testbench for rtl/tape/tape_src.sv, the tape file image on the SD card
// (hps_io disk slot 0), cached in two 512-byte sectors and served through
// tape.sv's memory port.
//
// The consumer model is tape.sv's own rd_en handshake (rtl/tape/tape.sv,
// the lines that keep rd_req/read_done/old_rden: rd = rd_req & rd_en, rd_req
// rises only while rd_en = 0, and din is taken on the first rd_en = 0 clock
// after an rd_en = 1 clock), with addr incremented after each byte and a
// jump/consume control for the test's own reads. The SD side is
// sim/models/sd_img_model.sv, driven from build/sim/hex files the run script
// makes on the host (python3 tools/zxtap.py for hello.tap/.tzx/.csw and raw
// byte files for the rest).
//
// Cases (each prints `<case>: ok` or `FAIL <case> ...`):
//   sniff                  hello.tap, hello.tzx, hello.csw sniff as modes
//                          0, 2, 1 (src_mode) with sizes 58, 74, 12196;
//   blk_seek               prev on a converted file raises exactly one
//                          seek pulse for tape.sv, on a CSW file none;
//   sequential             every byte 0..2999 of a 3000-byte file;
//   prefetch_hides_latency LAT_CLKS = 100000 (2 ms), one byte every 300 us
//                          from 500 to 519: after the first byte no read
//                          waits more than 2 clk cycles (the worst is
//                          printed);
//   random_jump            reads at 2900, 10 and 1500 (backwards across
//                          sectors) return the right bytes;
//   jump_into_slot_being_fetched
//                          sector 0, then sector 1 (which prefetches sector
//                          2 into sector 0's slot); while that fetch is
//                          writing the slot, a read of sector 0 must miss,
//                          wait for the fetch and return sector 0's byte;
//   short_file             a 100-byte file: tape_size = 100, bytes 0..99
//                          right, and no sector past the end is fetched;
//   remount                read 600 bytes of file A, mount file B:
//                          tape_ready falls for at least 4 clk cycles, rises
//                          with B's mode/size, and B's byte 0 is read, not
//                          A's cached sector 0.
//
// The last line printed is `tb_tape_src: PASS` or
// `tb_tape_src: FAIL <reason>`; run via sim/run_tb_tape_src.sh
// (iverilog -g2012).
`timescale 1ns / 1ps
`default_nettype none

module tb_tape_src;

    // ---------------- clocks ----------------
    reg clk_sys = 1'b0;                     // hps_io side, 50 MHz
    always #10 clk_sys = ~clk_sys;

    reg clk = 1'b0;                         // CLK_BUS, 28.125 MHz
    always #17.7778 clk = ~clk;

    // ---------------- DUT ----------------
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
    wire        rd_en;
    wire  [7:0] din;

    reg  [24:0] addr = 25'd0;
    reg         rd_req = 1'b0;
    reg         read_done = 1'b1;
    reg         old_rden = 1'b0;
    reg   [7:0] din_r = 8'd0;
    reg         consume = 1'b0;             // tb: tape.sv consumed the byte
    reg         jump = 1'b0;                // tb: set addr, cancel a request
    reg  [24:0] jump_addr = 25'd0;
    wire        rd = rd_req & rd_en;

    // prev/next drive the converter's block seeks; blk_seek is tape_conv's
    // one-clock "the stream restarts here" pulse, which the top holds for
    // 15 clocks before tape.sv sees it (Karabas_Profi.sv)
    reg         seek_prev = 1'b0;
    reg         seek_next = 1'b0;
    wire        blk_seek;
    integer     blk_seek_n = 0;
    always @(posedge clk) if (blk_seek) blk_seek_n = blk_seek_n + 1;

    tape_src dut (
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
        .rd(rd),
        .addr(addr),
        .din(din),
        .rd_en(rd_en),
        .seek_prev(seek_prev),
        .seek_next(seek_next),
        .blk_seek(blk_seek),
        .stock_tzx(1'b0)
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

    // ---------------- consumer: tape.sv's handshake ----------------
    // The same lines as tape.sv (rd_req/read_done/old_rden), plus the tb's
    // consume (tape.sv clears read_done in its data path), the byte-address
    // increment and the jump control.
    always @(posedge clk) begin
        old_rden <= rd_en;

        if (consume) begin
            read_done <= 1'b0;
        end else if (~rd_en) begin
            if (rd_req) begin
                if (old_rden) begin
                    if (~read_done) begin
                        din_r <= din;
                        read_done <= 1'b1;
                        addr <= addr + 1'b1;
                    end
                    rd_req <= 1'b0;
                end
            end else begin
                rd_req <= ~read_done;
            end
        end

        if (jump) begin
            addr   <= jump_addr;
            rd_req <= 1'b0;
        end
    end

    // ---------------- reference and helpers ----------------
    reg [7:0] ref_mem [0:32767];

    integer errors = 0;
    integer shown = 0;
    integer case_errors;
    integer i;
    integer worst, first_w, low_cycles;
    reg [7:0] d;

    task fail_byte(input [8*32-1:0] name, input integer a,
                   input [7:0] got, input [7:0] want);
        begin
            if (got !== want) begin
                if (shown < 8)
                    $display("FAIL %0s addr %0d got %02h want %02h", name, a, got, want);
                else if (shown == 8)
                    $display("FAIL %0s more failures follow (not printed)", name);
                shown = shown + 1;
                errors = errors + 1;
            end
        end
    endtask

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

    // one img_mounted pulse with the file behind it
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

    // wait for tape_ready to fall (if it is high) and rise; count the low
    // clk cycles from where this task first sees it low
    task wait_cycle(output integer low);
        begin
            low = 0;
            @(posedge clk); #1;
            while (tape_ready) begin
                @(posedge clk); #1;
            end
            while (!tape_ready) begin
                low = low + 1;
                @(posedge clk); #1;
            end
        end
    endtask

    // set the consumer address and clear read_done, then let the handshake
    // start the request
    task start_at(input [24:0] a);
        begin
            @(posedge clk);
            jump = 1'b1;
            jump_addr = a;
            consume = 1'b1;
            @(posedge clk);
            jump = 1'b0;
            consume = 1'b0;
        end
    endtask

    task wait_byte(output [7:0] data, output integer waited);
        begin
            waited = 0;
            @(posedge clk); #1;
            while (!rd) begin
                @(posedge clk); #1;
            end
            while (!read_done) begin
                waited = waited + 1;
                @(posedge clk); #1;
            end
            data = din_r;
        end
    endtask

    task get_next(output [7:0] data, output integer waited);
        begin
            @(posedge clk);
            consume = 1'b1;
            @(posedge clk);
            consume = 1'b0;
            wait_byte(data, waited);
        end
    endtask

    // ---------------- the run ----------------
    initial begin
        $display("tb_tape_src: start");

        // ---- sniff: the three signature formats give modes 0, 2, 1 ----
        // tape_mode is always 1: the player only ever sees the converter's
        // CSW stream (or a CSW file). What the sniff itself decided is
        // src_mode, and the size tells the two apart: a converted file is
        // unbounded (0x1FFFFFF), a passthrough one is the file's own size.
        case_errors = errors;
        shown = 0;
        mount_file(32'd58, "build/sim/hello.tap.hex");
        wait_cycle(low_cycles);
        fail_int("sniff", "tap src_mode", dut.src_mode, 0);
        fail_int("sniff", "tap mode", tape_mode, 1);
        fail_int("sniff", "tap size", tape_size, 25'h1FFFFFF);
        mount_file(32'd74, "build/sim/hello.tzx.hex");
        wait_cycle(low_cycles);
        fail_int("sniff", "tzx src_mode", dut.src_mode, 2);
        fail_int("sniff", "tzx mode", tape_mode, 1);
        fail_int("sniff", "tzx size", tape_size, 25'h1FFFFFF);
        mount_file(32'd17037, "build/sim/hello.csw.hex");
        wait_cycle(low_cycles);
        fail_int("sniff", "csw src_mode", dut.src_mode, 1);
        fail_int("sniff", "csw mode", tape_mode, 1);
        fail_int("sniff", "csw size", tape_size, 17037);
        if (errors == case_errors) $display("sniff: ok");
        else $display("sniff: FAIL");

        // ---- blk_seek: one pulse per converter jump, none in passthrough ----
        // The pulse is how tape.sv learns to drop its CSW RLE state, and the
        // top holds it for 15 clocks. `prev` is used because `next` only
        // seeks after the stream has reached a block end.
        case_errors = errors;
        shown = 0;
        mount_file(32'd58, "build/sim/hello.tap.hex");
        wait_cycle(low_cycles);
        blk_seek_n = 0;
        seek_prev = 1'b1;
        repeat (16) @(posedge clk);
        seek_prev = 1'b0;
        repeat (200) @(posedge clk);
        fail_int("blk_seek", "pulses on a converted file", blk_seek_n, 1);
        mount_file(32'd17037, "build/sim/hello.csw.hex");
        wait_cycle(low_cycles);
        blk_seek_n = 0;
        seek_prev = 1'b1;
        repeat (16) @(posedge clk);
        seek_prev = 1'b0;
        repeat (200) @(posedge clk);
        fail_int("blk_seek", "pulses in passthrough", blk_seek_n, 0);
        if (errors == case_errors) $display("blk_seek: ok");
        else $display("blk_seek: FAIL");

        // ---- sequential: every byte of a 3000-byte file ----
        case_errors = errors;
        shown = 0;
        sd_model.lat = 1000;
        mount_file(32'd3000, "build/sim/raw3000.hex");
        wait_cycle(low_cycles);
        $readmemh("build/sim/raw3000.hex", ref_mem, 0, 2999);
        start_at(25'd0);
        for (i = 0; i < 3000; i = i + 1) begin
            get_next(d, worst);
            fail_byte("sequential", i, d, ref_mem[i]);
        end
        if (errors == case_errors) $display("sequential: ok");
        else $display("sequential: FAIL");

        // ---- prefetch_hides_latency: 2 ms SD latency, one byte / 300 us ----
        case_errors = errors;
        shown = 0;
        sd_model.lat = 100000;                   // 2 ms at 50 MHz
        mount_file(32'd3000, "build/sim/raw3000.hex");
        wait_cycle(low_cycles);
        $readmemh("build/sim/raw3000.hex", ref_mem, 0, 2999);
        start_at(25'd500);
        worst = 0;
        first_w = 0;
        for (i = 0; i < 20; i = i + 1) begin
            get_next(d, low_cycles);             // per-read wait, reuse var
            fail_byte("prefetch_hides_latency", 500 + i, d, ref_mem[500 + i]);
            if (i == 0) first_w = low_cycles;
            else if (low_cycles > worst) worst = low_cycles;
            repeat (8438) @(posedge clk);        // 300 us at 28.125 MHz
        end
        $display("prefetch_hides_latency: first wait %0d, worst after the first %0d clk",
                 first_w, worst);
        if (worst > 2) fail_int("prefetch_hides_latency", "worst wait", worst, 2);
        if (errors == case_errors) $display("prefetch_hides_latency: ok");
        else $display("prefetch_hides_latency: FAIL");

        // ---- random_jump: backwards across sectors ----
        case_errors = errors;
        shown = 0;
        sd_model.lat = 1000;
        mount_file(32'd3000, "build/sim/raw3000.hex");
        wait_cycle(low_cycles);
        $readmemh("build/sim/raw3000.hex", ref_mem, 0, 2999);
        start_at(25'd2900);
        get_next(d, worst);
        fail_byte("random_jump", 2900, d, ref_mem[2900]);
        start_at(25'd10);
        get_next(d, worst);
        fail_byte("random_jump", 10, d, ref_mem[10]);
        start_at(25'd1500);
        get_next(d, worst);
        fail_byte("random_jump", 1500, d, ref_mem[1500]);
        if (errors == case_errors) $display("random_jump: ok");
        else $display("random_jump: FAIL");

        // ---- jump_into_slot_being_fetched: the old tag must miss ----
        case_errors = errors;
        shown = 0;
        sd_model.lat = 20000;
        mount_file(32'd3000, "build/sim/raw3000.hex");
        wait_cycle(low_cycles);
        $readmemh("build/sim/raw3000.hex", ref_mem, 0, 2999);
        start_at(25'd0);
        get_next(d, worst);              // sector 0 hit: prefetches sector 1
        fail_byte("jump_into_slot_being_fetched", 0, d, ref_mem[0]);
        start_at(25'd512);
        get_next(d, worst);              // sector 1 hit: prefetches sector 2 into slot 0
        fail_byte("jump_into_slot_being_fetched", 512, d, ref_mem[512]);
        // the sector-2 fetch has written past offset 400 into slot 0 now
        i = 0;
        @(posedge clk_sys); #1;
        while (!(sd_model.state == sd_model.M_DATA && sd_model.idx > 10'd420)
               && i < 100000) begin
            @(posedge clk_sys); #1;
            i = i + 1;
        end
        if (i >= 100000)
            fail_int("jump_into_slot_being_fetched", "write phase", i, 0);
        start_at(25'd400);
        get_next(d, worst);              // sector 0's byte, never sector 2's
        fail_byte("jump_into_slot_being_fetched", 400, d, ref_mem[400]);
        if (errors == case_errors) $display("jump_into_slot_being_fetched: ok");
        else $display("jump_into_slot_being_fetched: FAIL");

        // ---- short_file: 100 bytes, no prefetch past the end ----
        case_errors = errors;
        shown = 0;
        sd_model.lat = 1000;
        mount_file(32'd100, "build/sim/raw100.hex");
        wait_cycle(low_cycles);
        $readmemh("build/sim/raw100.hex", ref_mem, 0, 99);
        sd_model.past_end = 1'b0;
        fail_int("short_file", "size", tape_size, 100);
        fail_int("short_file", "mode", tape_mode, 1);
        start_at(25'd0);
        for (i = 0; i < 100; i = i + 1) begin
            get_next(d, worst);
            fail_byte("short_file", i, d, ref_mem[i]);
        end
        if (sd_model.past_end)
            fail_int("short_file", "sector past the end fetched", 1, 0);
        if (errors == case_errors) $display("short_file: ok");
        else $display("short_file: FAIL");

        // ---- remount: B replaces A, ready falls then rises, B's byte 0 ----
        case_errors = errors;
        shown = 0;
        sd_model.lat = 1000;
        mount_file(32'd3000, "build/sim/raw3000.hex");
        wait_cycle(low_cycles);
        $readmemh("build/sim/raw3000.hex", ref_mem, 0, 2999);
        start_at(25'd0);
        for (i = 0; i < 600; i = i + 1) begin
            get_next(d, worst);
            fail_byte("remount A", i, d, ref_mem[i]);
        end
        mount_file(32'd600, "build/sim/raw_b.hex");
        wait_cycle(low_cycles);
        if (low_cycles < 4)
            fail_int("remount", "tape_ready low clks", low_cycles, 4);
        fail_int("remount", "mode B", tape_mode, 1);
        fail_int("remount", "size B", tape_size, 600);
        $readmemh("build/sim/raw_b.hex", ref_mem, 0, 599);
        start_at(25'd22);
        get_next(d, worst);
        fail_byte("remount", 22, d, ref_mem[22]);
        if (errors == case_errors) $display("remount: ok");
        else $display("remount: FAIL");

        // ---- verdict ----
        if (sd_model.err) begin
            $display("FAIL the SD model saw a request while sd_ack was high");
            errors = errors + 1;
        end
        if (errors == 0)
            $display("tb_tape_src: PASS");
        else
            $display("tb_tape_src: FAIL %0d error(s)", errors);
        $finish;
    end

    // edge-counted global watchdog (no $time arithmetic: it is unreliable in
    // deep Icarus runs); 40M clk clocks is ~1.4 s, far above the whole run
    initial begin
        repeat (40000000) @(posedge clk);
        $display("tb_tape_src: FAIL global timeout");
        $finish;
    end

endmodule

`default_nettype wire