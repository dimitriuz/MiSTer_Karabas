// Testbench for rtl/mem/gs_mem.sv, the General Sound memory: 64 KB of GS
// RAM in BRAM (0x00000..0x0FFFF, the ROM loader writing 0x0000..0x7FFF) and
// the rest in DDR3 at byte address 0x3000_0000. The DDR side is
// sim/models/ddram_model.sv, a 2 MB Avalon slave that checks the handshake.
//
// The GS bus is driven like the T80 at CE = 1: address and data set on one
// clock edge, rd/wr raised on the next, dout taken and the strobe dropped on
// the first edge where wait_n was 1. The loader runs on its own 24.107 MHz
// clock, started at a 7 ns offset from the 28.125 MHz GS clock, one byte per
// 64 loader clocks; it writes while the GS is held in reset.
//
// Cases (each prints `<case>: ok` or `FAIL <case> <addr> <got> <want>`):
//   loader_rom                the loader writes 32768 bytes (addr*7+3), then
//                             GS reads of 0x0000..0x7FFF return them, never
//                             waiting;
//   bram_ram                  write and read back 0x8000..0xFFFF (stride 97),
//                             no wait;
//   ddr_random                2000 random reads and writes over
//                             0x10000..0x1FFFFF with a read latency of 3..20
//                             clocks and 30% random busy; every read equals
//                             the reference;
//   read_hit                  two reads in one 8-byte line; the second has
//                             wait_n = 1 in its first cycle;
//   write_hits_cached_line    read a line, write one of its bytes, read that
//                             byte: the new value (the cache is written
//                             through, so it is also in the DDR);
//   long_busy                 force_busy for 300 clocks during a write and
//                             then during a read; both complete correctly and
//                             wait_n stays 0 meanwhile.
//
// The last line printed is `tb_gs_mem: PASS` or `tb_gs_mem: FAIL <reason>`;
// run via sim/run_tb_gs_mem.sh (iverilog -g2012).
`timescale 1ns / 1ps

module tb_gs_mem;

    // ---------------- clocks ----------------
    reg gclk = 1'b0;
    always #17.7775 gclk = ~gclk;              // 28.125 MHz, 35.555 ns

    reg lclk = 1'b0;
    initial begin
        #7;                                     // odd offset
        forever #20.7408 lclk = ~lclk;          // 24.107 MHz, 41.4816 ns
    end

    // ---------------- DUT ----------------
    reg         reset = 1'b1;
    reg  [20:0] a     = 21'd0;
    reg   [7:0] din   = 8'd0;
    reg         rd    = 1'b0;
    reg         wr    = 1'b0;
    wire  [7:0] dout;
    wire        wait_n;

    reg  [20:0] ldr_a   = 21'd0;
    reg   [7:0] ldr_d   = 8'd0;
    reg         ldr_tgl = 1'b0;

    reg         force_busy = 1'b0;
    wire        ddr_busy;
    wire  [7:0] ddr_burstcnt;
    wire [28:0] ddr_addr;
    wire [63:0] ddr_dout;
    wire        ddr_dout_ready;
    wire        ddr_rd;
    wire [63:0] ddr_din;
    wire  [7:0] ddr_be;
    wire        ddr_we;

    gs_mem dut (
        .clk(gclk),
        .reset(reset),
        .a(a),
        .din(din),
        .rd(rd),
        .wr(wr),
        .dout(dout),
        .wait_n(wait_n),
        .ldr_a(ldr_a),
        .ldr_d(ldr_d),
        .ldr_tgl(ldr_tgl),
        .ddr_busy(ddr_busy),
        .ddr_burstcnt(ddr_burstcnt),
        .ddr_addr(ddr_addr),
        .ddr_dout(ddr_dout),
        .ddr_dout_ready(ddr_dout_ready),
        .ddr_rd(ddr_rd),
        .ddr_din(ddr_din),
        .ddr_be(ddr_be),
        .ddr_we(ddr_we)
    );

    ddram_model #(
        .LAT(4),
        .BUSY_PCT(30)
    ) model (
        .clk(gclk),
        .force_busy(force_busy),
        .burstcnt(ddr_burstcnt),
        .addr(ddr_addr),
        .rd(ddr_rd),
        .din(ddr_din),
        .be(ddr_be),
        .we(ddr_we),
        .dout(ddr_dout),
        .dout_ready(ddr_dout_ready),
        .busy(ddr_busy)
    );

    // ---------------- reference and helpers ----------------
    reg [7:0] ref_mem [0:2097151];

    integer errors = 0;
    integer shown  = 0;        // failures printed for the current case (cap 8)
    integer case_errors;
    integer wa     = 0;         // clock edges the last transaction spent waiting
    integer i, j;
    integer seed;
    reg [31:0] rnd;
    reg [20:0] taddr;
    reg  [7:0] rdata;

    task fail(input [8*32-1:0] name, input [20:0] addr,
              input [7:0] got, input [7:0] want);
        begin
            if (shown < 8)
                $display("FAIL %0s %05h got %02h want %02h", name, addr, got, want);
            else if (shown == 8)
                $display("FAIL %0s more failures follow (not printed)", name);
            shown = shown + 1;
            errors = errors + 1;
        end
    endtask

    task wfail(input [8*32-1:0] name, input [20:0] addr, input integer n);
        begin
            if (shown < 8)
                $display("FAIL %0s %05h waited %0d", name, addr, n);
            else if (shown == 8)
                $display("FAIL %0s more failures follow (not printed)", name);
            shown = shown + 1;
            errors = errors + 1;
        end
    endtask

    // one GS read cycle
    task bus_read(input [20:0] addr, output [7:0] data);
        integer n;
        begin
            @(posedge gclk);
            a <= addr; din <= 8'd0; rd <= 1'b0; wr <= 1'b0;
            @(posedge gclk);
            rd <= 1'b1;
            n = 0;
            @(posedge gclk);
            #1;
            while (!wait_n) begin
                n = n + 1;
                if (n > 5000) begin
                    $display("tb_gs_mem: FAIL bus_read timeout at %05h", addr);
                    $finish;
                end
                @(posedge gclk);
                #1;
            end
            data = dout;
            wa = n;
            rd <= 1'b0;
        end
    endtask

    // one GS write cycle
    task bus_write(input [20:0] addr, input [7:0] val);
        integer n;
        begin
            @(posedge gclk);
            a <= addr; din <= val; rd <= 1'b0; wr <= 1'b0;
            @(posedge gclk);
            wr <= 1'b1;
            n = 0;
            @(posedge gclk);
            #1;
            while (!wait_n) begin
                n = n + 1;
                if (n > 5000) begin
                    $display("tb_gs_mem: FAIL bus_write timeout at %05h", addr);
                    $finish;
                end
                @(posedge gclk);
                #1;
            end
            wa = n;
            wr <= 1'b0;
        end
    endtask

    task do_reset;
        begin
            @(posedge gclk);
            reset <= 1'b1;
            repeat (8) @(posedge gclk);
            reset <= 1'b0;
            repeat (8) @(posedge gclk);
        end
    endtask

    // loader byte: address and data first, then the toggle, one per 64 clocks
    task loader_byte(input [20:0] addr, input [7:0] d);
        begin
            @(posedge lclk);
            #1 ldr_a = addr; ldr_d = d;
            @(posedge lclk);
            #1 ldr_tgl = ~ldr_tgl;
            repeat (62) @(posedge lclk);
        end
    endtask

    // ---------------- the run ----------------
    initial begin
        for (j = 0; j < 2097152; j = j + 1) ref_mem[j] = 8'd0;
        seed = 32'h5EED2A17;
        $display("tb_gs_mem: seed %08h", seed);

        // ---- loader_rom: the loader fills 0x0000..0x7FFF, GS in reset ----
        case_errors = errors;
        shown = 0;
        reset = 1'b1;
        repeat (4) @(posedge lclk);
        for (i = 0; i < 32768; i = i + 1) begin
            ref_mem[i] = (i * 7 + 3) & 8'hFF;
            loader_byte(i[20:0], (i * 7 + 3) & 8'hFF);
        end
        @(posedge gclk);
        reset <= 1'b0;
        repeat (8) @(posedge gclk);
        for (i = 0; i < 32768; i = i + 1) begin
            bus_read(i[20:0], rdata);
            if (rdata !== ref_mem[i])
                fail("loader_rom", i[20:0], rdata, ref_mem[i]);
            if (wa != 0) wfail("loader_rom", i[20:0], wa);
        end
        if (errors == case_errors) $display("loader_rom: ok");
        else $display("loader_rom: FAIL");

        // ---- bram_ram: write and read back 0x8000..0xFFFF, stride 97 ----
        case_errors = errors;
        shown = 0;
        for (i = 16'h8000; i <= 16'hFFFF; i = i + 97) begin
            bus_write(i[20:0], (i * 13 + 5) & 8'hFF);
            ref_mem[i] = (i * 13 + 5) & 8'hFF;
            if (wa != 0) wfail("bram_ram", i[20:0], wa);
        end
        for (i = 16'h8000; i <= 16'hFFFF; i = i + 97) begin
            bus_read(i[20:0], rdata);
            if (rdata !== ref_mem[i])
                fail("bram_ram", i[20:0], rdata, ref_mem[i]);
            if (wa != 0) wfail("bram_ram", i[20:0], wa);
        end
        if (errors == case_errors) $display("bram_ram: ok");
        else $display("bram_ram: FAIL");

        // ---- ddr_random: 2000 random reads and writes above 0xFFFF ----
        case_errors = errors;
        shown = 0;
        for (i = 0; i < 2000; i = i + 1) begin
            rnd = $urandom(seed);
            taddr = 21'h10000 + (rnd % 32'h1F0000);
            model.lat = 3 + (rnd % 18);
            if (rnd[8]) begin
                rnd = $urandom(seed);
                bus_write(taddr, rnd[7:0]);
                ref_mem[taddr] = rnd[7:0];
            end else begin
                bus_read(taddr, rdata);
                if (rdata !== ref_mem[taddr])
                    fail("ddr_random", taddr, rdata, ref_mem[taddr]);
            end
        end
        if (errors == case_errors) $display("ddr_random: ok");
        else $display("ddr_random: FAIL");

        // ---- read_hit: two reads in one line, the second never waits ----
        case_errors = errors;
        shown = 0;
        do_reset;
        bus_write(21'h10000, 8'h11); ref_mem[21'h10000] = 8'h11;
        bus_write(21'h10005, 8'h22); ref_mem[21'h10005] = 8'h22;
        bus_read(21'h10000, rdata);                   // miss: fills the line
        if (rdata !== 8'h11) fail("read_hit", 21'h10000, rdata, 8'h11);
        if (wa == 0) wfail("read_hit", 21'h10000, 0);
        bus_read(21'h10005, rdata);                   // hit: no wait at all
        if (rdata !== 8'h22) fail("read_hit", 21'h10005, rdata, 8'h22);
        if (wa != 0) wfail("read_hit", 21'h10005, wa);
        if (errors == case_errors) $display("read_hit: ok");
        else $display("read_hit: FAIL");

        // ---- write_hits_cached_line: write-through updates the cached line ----
        case_errors = errors;
        shown = 0;
        bus_write(21'h10005, 8'h33); ref_mem[21'h10005] = 8'h33;
        bus_read(21'h10005, rdata);                   // must hit, new value
        if (rdata !== 8'h33) fail("write_hits_cached_line", 21'h10005, rdata, 8'h33);
        if (wa != 0) wfail("write_hits_cached_line", 21'h10005, wa);
        do_reset;                                     // cache gone: read the DDR
        bus_read(21'h10005, rdata);
        if (rdata !== 8'h33) fail("write_hits_cached_line", 21'h10005, rdata, 8'h33);
        if (errors == case_errors) $display("write_hits_cached_line: ok");
        else $display("write_hits_cached_line: FAIL");

        // ---- long_busy: a write and a read held off for 300 clocks ----
        case_errors = errors;
        shown = 0;
        do_reset;
        // write: hold force_busy over the whole request
        @(posedge gclk);
        a <= 21'h1E0000; din <= 8'hA5; rd <= 1'b0; wr <= 1'b0;
        @(posedge gclk);
        wr <= 1'b1;
        @(posedge gclk);
        force_busy <= 1'b1;
        for (i = 0; i < 300; i = i + 1) begin
            @(posedge gclk);
            #1;
            if (wait_n !== 1'b0) wfail("long_busy write", i[20:0], wait_n);
        end
        force_busy <= 1'b0;
        @(posedge gclk);
        #1;
        wa = 0;
        while (!wait_n) begin
            wa = wa + 1;
            @(posedge gclk);
            #1;
        end
        wr <= 1'b0;
        ref_mem[21'h1E0000] = 8'hA5;
        // the write reached the DDR: read it back from a cold cache
        do_reset;
        bus_read(21'h1E0000, rdata);
        if (rdata !== 8'hA5) fail("long_busy", 21'h1E0000, rdata, 8'hA5);
        // read: hold force_busy while the miss is outstanding
        @(posedge gclk);
        a <= 21'h1E1000; din <= 8'd0; rd <= 1'b0; wr <= 1'b0;
        @(posedge gclk);
        rd <= 1'b1;
        @(posedge gclk);
        force_busy <= 1'b1;
        for (i = 0; i < 300; i = i + 1) begin
            @(posedge gclk);
            #1;
            if (wait_n !== 1'b0) wfail("long_busy read", i[20:0], wait_n);
        end
        force_busy <= 1'b0;
        @(posedge gclk);
        #1;
        while (!wait_n) begin
            @(posedge gclk);
            #1;
        end
        if (dout !== ref_mem[21'h1E1000])
            fail("long_busy", 21'h1E1000, dout, ref_mem[21'h1E1000]);
        rd <= 1'b0;
        if (errors == case_errors) $display("long_busy: ok");
        else $display("long_busy: FAIL");

        // ---- verdict ----
        if (errors == 0)
            $display("tb_gs_mem: PASS");
        else
            $display("tb_gs_mem: FAIL %0d error(s)", errors);
        $finish;
    end

    // edge-counted global watchdog (no $time arithmetic: it is unreliable in
    // deep Icarus runs); 40M GS clocks is ~1.4 s, far above the whole run
    initial begin
        repeat (40000000) @(posedge gclk);
        $display("tb_gs_mem: FAIL global timeout");
        $finish;
    end

endmodule