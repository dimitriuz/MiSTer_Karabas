// gs_mem.sv - the General Sound's memory: 64 KB of GS RAM in BRAM and the
// rest in the DE10-Nano DDR3, behind the DDRAM Avalon port (sys/emu_ports.vh
// DDRAM_*). clk is CLK_GS (28.125 MHz) and also the DDRAM_CLK.
//
// Address map. a[20:16] == 0 is the low 64 KB, an inferred register array
// (reg [7:0] ram [0:65535], one write port, a registered read q). The ROM
// loader writes it from its own clock: ldr_tgl goes through two flops and a
// change of the second one writes ldr_d at ldr_a[15:0] when ldr_a[20:16] is
// 0; other loader addresses are ignored. The loader write takes the RAM port
// over GS writes (the GS is held in reset while the loader runs), and its
// synchroniser keeps running in reset. The rest of the address space is in
// DDR3 at byte address 0x3000_0000 + a: ddr_addr = {4'b0011, 7'd0, a[20:3]},
// ddr_burstcnt = 1, one 64-bit line per eight bytes.
//
// Bus behaviour. q and low_r (low registered on the same edge) update every
// clock, so dout = low_r ? q : line[8*a[2:0] +: 8] is one clock behind the
// address. wait_n = !(!low && ((rd && !hit) || (wr && !wdone))) is
// combinational, so the T80 (which samples WAIT_n at the end of T2) sees it
// in the first T2; RD_n/WR_n are levels, ~MRD_n/~MWE_n.
//
// A one-line read cache: line, tag (a[20:3]) and valid; hit = valid &&
// tag == a[20:3]. A read to a line not in the cache asserts ddr_rd with the
// line address and waits for the Avalon accept (the first edge with
// ddr_busy low), then for ddr_dout_ready, which loads line, tag and valid.
// A write asserts ddr_we with ddr_din = {8{din}} and ddr_be =
// 8'b1 << a[2:0], keeps them stable until the accept, then sets wdone (wait_n
// goes 1) and clears wdone when wr falls. A read drives ddr_be = 8'hFF, the
// MiSTer DDRAM convention (byteenable is a write mask; all bytes are wanted).
// If the cache holds that line the byte is written through to it as well, so
// a following read hits the new value. No request is issued while another one
// is outstanding.
//
// reset is asynchronous, active high; it goes through a two-flop synchroniser
// to rst, which clears the FSM, valid, wdone, ddr_rd and ddr_we.
`default_nettype none

module gs_mem (
    input  wire        clk,         // CLK_GS 28.125 MHz; the DDRAM_CLK too
    input  wire        reset,       // async; synchronised inside (2 FF)
    input  wire [20:0] a,           // GS bus (gs.v MA), clk domain
    input  wire  [7:0] din,         // GS write data (MDO)
    input  wire        rd,          // = ~MRD_n (level)
    input  wire        wr,          // = ~MWE_n (level)
    output wire  [7:0] dout,        // to MDI
    output wire        wait_n,      // to GS_WAIT (T80 WAIT_n)
    input  wire [20:0] ldr_a,       // loader byte (other clock): address,
    input  wire  [7:0] ldr_d,       //   data, stable before ldr_tgl moves
    input  wire        ldr_tgl,     //   toggles once per byte
    input  wire        ddr_busy,
    output wire  [7:0] ddr_burstcnt,
    output wire [28:0] ddr_addr,
    input  wire [63:0] ddr_dout,
    input  wire        ddr_dout_ready,
    output wire        ddr_rd,
    output wire [63:0] ddr_din,
    output wire  [7:0] ddr_be,
    output wire        ddr_we
);

    // ---------------- reset synchroniser ----------------
    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk or posedge reset) begin
        if (reset) rst_sync <= 2'b11;
        else       rst_sync <= {rst_sync[0], 1'b0};
    end
    wire rst = rst_sync[1];

    // ---------------- address decode ----------------
    wire        low    = (a[20:16] == 5'd0);
    wire [17:0] line_a = a[20:3];

    // ---------------- low 64 KB: inferred BRAM ----------------
    reg [7:0] ram [0:65535];
    reg [7:0] q;
    reg       low_r;

    // loader: 2 FF, then a change of the second stage writes one byte
    reg ldr_s1 = 1'b0, ldr_s2 = 1'b0, ldr_s3 = 1'b0;
    always @(posedge clk) begin
        ldr_s1 <= ldr_tgl;
        ldr_s2 <= ldr_s1;
        ldr_s3 <= ldr_s2;
    end
    wire ldr_wr = ldr_s2 ^ ldr_s3;

    always @(posedge clk) begin
        low_r <= low;
        q     <= ram[a[15:0]];
        if (ldr_wr && ldr_a[20:16] == 5'd0)
            ram[ldr_a[15:0]] <= ldr_d;
        else if (wr && low)
            ram[a[15:0]] <= din;
    end

    // ---------------- one-line read cache ----------------
    reg [63:0] line  = 64'd0;
    reg [17:0] tag   = 18'd0;
    reg        valid = 1'b0;
    wire       hit   = valid && (tag == line_a);

    // ---------------- DDR request FSM ----------------
    localparam [1:0] ST_IDLE = 2'd0, ST_RD = 2'd1, ST_WR = 2'd2;

    reg [1:0]  state    = ST_IDLE;
    reg [17:0] req_line = 18'd0;
    reg  [2:0] req_byte = 3'd0;
    reg  [7:0] req_din  = 8'd0;
    reg        ddr_rd_r = 1'b0;
    reg        ddr_we_r = 1'b0;
    reg        wdone    = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            state    <= ST_IDLE;
            valid    <= 1'b0;
            wdone    <= 1'b0;
            ddr_rd_r <= 1'b0;
            ddr_we_r <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (!wr)
                        wdone <= 1'b0;
                    if (!low && rd && !hit) begin
                        req_line <= line_a;
                        ddr_rd_r <= 1'b1;
                        state    <= ST_RD;
                    end else if (!low && wr && !wdone) begin
                        req_line <= line_a;
                        req_byte <= a[2:0];
                        req_din  <= din;
                        if (hit)
                            line <= (line & ~(64'hFF << {a[2:0], 3'b000}))
                                    | ({56'd0, din} << {a[2:0], 3'b000});
                        ddr_we_r <= 1'b1;
                        state    <= ST_WR;
                    end
                end
                ST_RD: begin
                    if (ddr_rd_r && !ddr_busy)   // Avalon accept
                        ddr_rd_r <= 1'b0;
                    if (ddr_dout_ready && !ddr_rd_r) begin
                        line  <= ddr_dout;
                        tag   <= req_line;
                        valid <= 1'b1;
                        state <= ST_IDLE;
                    end
                end
                ST_WR: begin
                    if (!ddr_busy) begin           // Avalon accept
                        ddr_we_r <= 1'b0;
                        wdone    <= 1'b1;
                        state    <= ST_IDLE;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

    // ---------------- outputs ----------------
    assign dout        = low_r ? q : (line >> {a[2:0], 3'b000});
    assign wait_n      = !(!low && ((rd && !hit) || (wr && !wdone)));
    assign ddr_burstcnt = 8'd1;
    assign ddr_addr    = {4'b0011, 7'd0, req_line};
    assign ddr_din     = {8{req_din}};
    assign ddr_be      = ddr_we_r ? (8'b1 << req_byte) : 8'hFF;
    assign ddr_rd      = ddr_rd_r;
    assign ddr_we      = ddr_we_r;

endmodule

`default_nettype wire