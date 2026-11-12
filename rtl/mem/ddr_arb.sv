// ddr_arb.sv - the DDR3 arbiter: the General Sound memory (gs_mem, master 0,
// priority) and the floppy drive store (fdd_store, master 1, stage 4c) behind
// the one DE10-Nano DDR3 Avalon port (sys/emu_ports.vh DDRAM_*). clk is
// CLK_GS, which is also the DDRAM_CLK; both masters are in that domain.
//
// Grant FSM: IDLE -> GS when g_req, else -> FDD when f_req, so GS preempts a
// waiting FDD at every idle clock and the FDD only ever runs while GS is
// quiet. The granted master's signals are routed to the DDR3 and the other
// master sees busy = 1; both masters hold their request that way, exactly as
// gs_mem holds its strobes today. A write grant is released on the accept edge
// (!ddr_busy, which is also the Avalon accept condition), a read grant on
// ddr_dout_ready - the read strobe is already gone by then (the master drops it
// at its accept), so the grant type is latched when the grant is given. One
// transaction is in flight at a time and nothing is reordered.
//
// The master contract: req goes up with a strobe and comes down no later than
// the edge the transaction is served (gs_mem's req would be rd | we and falls
// at the accept; a master that keeps req up until its line is back is served
// the same way). The grant is only given while a strobe is up, so a request
// that outlives its transaction can never win a grant with nothing behind it.
//
// ddr_burstcnt is 1 always: one 64-bit line per request, the MiSTer convention
// (gs_mem drives ddr_be = 8'hFF with a read, byteenable being a write mask).
//
// reset is asynchronous, active high (the PLL lock, never the OSD reset -
// aborting an Avalon transaction mid-flight breaks the protocol, the gs_mem
// rule); it goes through a two-flop synchroniser to rst, which puts the FSM
// back in IDLE.
`default_nettype none

module ddr_arb (
    input  wire        clk,           // CLK_GS 28.125 MHz, also DDRAM_CLK
    input  wire        reset,         // async; synchronised inside (2 FF)
    // master 0: gs_mem (priority)
    input  wire        g_req,         // rd | we, held until served
    input  wire [28:0] g_addr,
    input  wire [63:0] g_din,
    input  wire  [7:0] g_be,
    input  wire        g_rd,
    input  wire        g_we,
    output wire        g_busy,
    output wire [63:0] g_dout,
    output wire        g_dout_ready,
    // master 1: fdd_store
    input  wire        f_req,
    input  wire [28:0] f_addr,
    input  wire [63:0] f_din,
    input  wire  [7:0] f_be,
    input  wire        f_rd,
    input  wire        f_we,
    output wire        f_busy,
    output wire [63:0] f_dout,
    output wire        f_dout_ready,
    // DDR3
    output wire        ddr_rd,
    output wire        ddr_we,
    output wire [28:0] ddr_addr,
    output wire [63:0] ddr_din,
    output wire  [7:0] ddr_be,
    output wire  [7:0] ddr_burstcnt,
    input  wire        ddr_busy,
    input  wire [63:0] ddr_dout,
    input  wire        ddr_dout_ready
);

    // ---------------- reset synchroniser ----------------
    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk or posedge reset) begin
        if (reset) rst_sync <= 2'b11;
        else       rst_sync <= {rst_sync[0], 1'b0};
    end
    wire rst = rst_sync[1];

    // ---------------- grant FSM ----------------
    localparam [1:0] ST_IDLE = 2'd0, ST_GS = 2'd1, ST_FDD = 2'd2;

    reg [1:0] state = ST_IDLE;
    reg       gnt_rd = 1'b0;      // what the current grant is holding
    reg       gnt_wr = 1'b0;

    wire sel_gs  = (state == ST_GS);
    wire sel_fdd = (state == ST_FDD);

    // a write is done when the request is accepted, a read when its line is
    // back; the strobes of the master that is waiting for a line are down,
    // which is why the type was latched
    wire served = (gnt_wr && !ddr_busy) || (gnt_rd && ddr_dout_ready);

    always @(posedge clk) begin
        if (rst) begin
            state  <= ST_IDLE;
            gnt_rd <= 1'b0;
            gnt_wr <= 1'b0;
        end else case (state)
            ST_IDLE: begin
                if (g_req && (g_rd || g_we)) begin
                    state  <= ST_GS;
                    gnt_rd <= g_rd;
                    gnt_wr <= g_we;
                end else if (f_req && (f_rd || f_we)) begin
                    state  <= ST_FDD;
                    gnt_rd <= f_rd;
                    gnt_wr <= f_we;
                end
            end
            ST_GS:   if (served) state <= ST_IDLE;
            ST_FDD:  if (served) state <= ST_IDLE;
            default: state <= ST_IDLE;
        endcase
    end

    // ---------------- the routed master ----------------
    wire        sel_rd   = sel_gs ? g_rd   : (sel_fdd ? f_rd   : 1'b0);
    wire        sel_we   = sel_gs ? g_we   : (sel_fdd ? f_we   : 1'b0);
    wire [28:0] sel_addr = sel_gs ? g_addr : (sel_fdd ? f_addr : 29'd0);
    wire [63:0] sel_din  = sel_gs ? g_din  : (sel_fdd ? f_din  : 64'd0);
    wire  [7:0] sel_be   = sel_gs ? g_be   : (sel_fdd ? f_be   : 8'd0);

    // ---------------- outputs ----------------
    assign g_busy       = sel_gs  ? ddr_busy : 1'b1;
    assign f_busy       = sel_fdd ? ddr_busy : 1'b1;
    assign g_dout       = ddr_dout;
    assign f_dout       = ddr_dout;
    assign g_dout_ready = sel_gs  && ddr_dout_ready;
    assign f_dout_ready = sel_fdd && ddr_dout_ready;

    assign ddr_rd       = sel_rd;
    assign ddr_we       = sel_we;
    assign ddr_addr     = sel_addr;
    assign ddr_din      = sel_din;
    assign ddr_be       = sel_be;
    assign ddr_burstcnt = 8'd1;

endmodule

`default_nettype wire
