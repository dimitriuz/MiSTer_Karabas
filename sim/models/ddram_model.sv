// ddram_model.sv - SIM MODEL of the DE10-Nano DDR3 Avalon slave as the
// core's DDR3 masters see it (sys/emu_ports.vh DDRAM_*): WORDS 64-bit lines.
// Two address regions are accepted, both checked against every request:
//   the General Sound memory (gs_mem): addr[28:18] == {4'b0011, 7'd0}, i.e.
//     word 0x0600_0000 = byte 0x3000_0000, index addr[17:0];
//   the floppy drive store (stage 4c): addr[28:19] == {4'b0011, 1'b1, 5'd0},
//     i.e. word 0x0700_0000 = byte 0x3800_0000, index 262144 + addr[18:0].
// Any other address is fatal. A request (rd or we high) is accepted on the
// rising edge where busy = 0; the model then keeps busy high for LAT clocks
// (read) or a few clocks (write). A read pulses dout_ready for one clock with
// the word LAT clocks after its acceptance.
//
// It checks the DUT against the same Avalon contract it models: both strobes
// high together, a request whose address or data changes while busy was high,
// a bad address or burst count, and a second read requested before the first
// one's data came back are all fatal (sim $error plus the FAIL verdict
// prefixed with FAIL_TAG, so every bench reports itself). Writes apply ddr_be
// per byte.
//
// The random busy uses a 16-bit LFSR: BUSY_PCT percent of the idle clocks
// start a busy of 0..15 clocks, so a request can wait an arbitrary time.
`default_nettype none

module ddram_model #(
    parameter integer LAT      = 4,   // read latency, clocks from accept to dout_ready
    parameter integer BUSY_PCT = 0,   // percent of idle clocks that start a pseudo-random busy
    parameter integer WORDS    = 786432,  // lines: 0..262143 the GS region, 262144..786431 the FDD one
    parameter [8*16-1:0] FAIL_TAG = "tb_gs_mem"   // the bench a fatal is reported for
) (
    input  wire        clk,
    input  wire        force_busy,    // hold busy high (the long-busy case)
    input  wire  [7:0] burstcnt,
    input  wire [28:0] addr,
    input  wire        rd,
    input  wire [63:0] din,
    input  wire  [7:0] be,
    input  wire        we,
    output reg  [63:0] dout,
    output reg         dout_ready,
    output wire        busy
);

    // one 64-bit word per line: the GS region's 262144 lines plus the FDD
    // region's, which the index formula puts at 262144 + addr[18:0]
    reg [63:0] mem [0:WORDS-1];

    reg [7:0]  lat;          // read latency; a reg so the bench can vary it
    reg        busy_r = 1'b0;
    reg  [7:0] cnt    = 8'd0;
    reg        is_rd  = 1'b0;
    reg [19:0] line_idx = 20'd0;
    reg        rd_in_flight = 1'b0;

    reg [15:0] lfsr = 16'hACE1;

    // ---------------- address regions ----------------
    // === so that an X address stays as fatal as it was with !==
    wire in_gs  = (addr[28:18] === {4'b0011, 7'd0});        // the GS map
    wire in_fdd = (addr[28:19] === {4'b0011, 1'b1, 5'd0});  // the FDD store map
    wire [19:0] line_of = in_gs ? {2'd0, addr[17:0]}
                                : (20'd262144 + {1'b0, addr[18:0]});

    wire accept = !busy && (rd || we);
    assign busy = busy_r | force_busy;

    wire [63:0] be_mask =
        (be[0] ? 64'h00000000000000FF : 64'd0) |
        (be[1] ? 64'h000000000000FF00 : 64'd0) |
        (be[2] ? 64'h0000000000FF0000 : 64'd0) |
        (be[3] ? 64'h00000000FF000000 : 64'd0) |
        (be[4] ? 64'h000000FF00000000 : 64'd0) |
        (be[5] ? 64'h0000FF0000000000 : 64'd0) |
        (be[6] ? 64'h00FF000000000000 : 64'd0) |
        (be[7] ? 64'hFF00000000000000 : 64'd0);

    integer i;
    initial begin
        lat        = LAT;
        dout       = 64'd0;
        dout_ready = 1'b0;
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 64'd0;
    end

    // ---------------- transaction engine ----------------
    always @(posedge clk) begin
        dout_ready <= 1'b0;
        if (accept) begin
            busy_r   <= 1'b1;
            cnt      <= lat - 1;
            is_rd    <= rd;
            line_idx <= line_of;
            if (we)
                mem[line_of] <= (mem[line_of] & ~be_mask) | (din & be_mask);
            if (rd)
                rd_in_flight <= 1'b1;
        end else if (busy_r) begin
            if (cnt == 8'd0) begin
                busy_r <= 1'b0;
                if (is_rd) begin
                    dout        <= mem[line_idx];
                    dout_ready  <= 1'b1;
                    rd_in_flight <= 1'b0;
                end
            end else begin
                cnt <= cnt - 8'd1;
            end
        end else if (BUSY_PCT != 0) begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            if ((lfsr % 100) < BUSY_PCT) begin
                busy_r <= 1'b1;
                cnt    <= lfsr[3:0];
                is_rd  <= 1'b0;     // a random busy window returns no data
            end
        end
    end

    // ---------------- contract checks ----------------
    reg        prev_rd = 1'b0, prev_we = 1'b0, prev_busy = 1'b0, accepted_prev = 1'b0;
    reg [28:0] prev_addr = 29'd0;
    reg [63:0] prev_din  = 64'd0;
    reg  [7:0] prev_be   = 8'd0;

    task fatal(input [8*40-1:0] what);
        begin
            $error("ddram_model: %0s", what);
            $display("%0s: FAIL ddram_model: %0s", FAIL_TAG, what);
            $finish;
        end
    endtask

    always @(posedge clk) begin
        if (rd && we)
            fatal("both strobes high");
        if ((rd || we) && ((!in_gs && !in_fdd) || burstcnt !== 8'd1))
            fatal("bad address or burst count");
        if (prev_busy && !accepted_prev && (prev_rd || prev_we) &&
            (rd !== prev_rd || we !== prev_we || addr !== prev_addr ||
             din !== prev_din || be !== prev_be))
            fatal("request changed while busy");
        if (rd && !prev_rd && rd_in_flight)
            fatal("second read while one is in flight");

        prev_rd       <= rd;
        prev_we       <= we;
        prev_busy     <= busy;
        prev_addr     <= addr;
        prev_din      <= din;
        prev_be       <= be;
        accepted_prev <= accept;
    end

endmodule

`default_nettype wire