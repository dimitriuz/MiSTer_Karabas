// fdc_trace.sv - a debug log of what the machine does to the floppy controller,
// sent out of the HPS UART (the board's /dev/ttyS1) while the OSD switch is on.
//
// The profi core exposes, per CPU bus cycle on clk_bus (profi.vhd, PROFI_REWRITES):
//   dbg_wr   a write to the FDC (a port #1F/#3F/#5F/#7F or #FF write)
//   dbg_rd   a read from it
//   dbg_ff   the access is the system port #FF
//   dbg_reg  A[6:5]: 0 command/status, 1 track, 2 sector, 3 data
//   dbg_d    the data bus the CPU drives,  dbg_q  what the controller answers
//
// Records (21 bits {kind[1:0], ff, reg[1:0], data[15:0]}, a 64-entry buffer on clk_bus):
//   kind 0  a write            ff, reg, data[7:0] = the byte (reg 0 = command)
//   kind 1  a status read      data[7:0] = the status the CPU got
//   kind 2  a data burst, logged when the first non-data access ends a run of data reads:
//             reg 0  data = the number of data reads
//             reg 1  {first byte, second}      reg 2  {third, fourth}
//             reg 3  {last byte, 0}
// A status read that repeats the last logged status (a poll loop) is not logged again
// until something else happens. Writes to the system port #FF are logged only up to 8 in a row (a beeper loop floods
// it); the next access of any other kind restarts the allowance.
// The access is sampled 2 clk_bus after its qualified strobe rises (the data bus has
// settled by then; a CPU access is far longer than that at any speed but turbo 8x).
//
// clk_sys side: the write pointer crosses as a Gray code through two flops (and the read
// pointer back, so a full buffer drops the newest record), the RAM is read on clk_sys, and
// every record leaves as three bytes
//   b0 = 0x80 | kind<<3 | ff<<2 | reg     b1 = data[15:8]     b2 = data[7:0]
// one byte per BYTE_CLKS clk_sys (a frame at 115200 baud is 4340 clocks), so the 16-byte
// FIFO of uart_route never overflows. `enable` (an OSD item, any clock) gates the capture.
`default_nettype none

module fdc_trace #(
    parameter integer BYTE_CLKS = 4400
) (
    input  wire       clk_bus,
    input  wire       clk_sys,
    input  wire       enable,
    input  wire       dbg_wr,
    input  wire       dbg_rd,
    input  wire       dbg_ff,
    input  wire [1:0] dbg_reg,
    input  wire [7:0] dbg_d,
    input  wire [7:0] dbg_q,
    output reg  [7:0] tx_data = 8'd0,
    output reg        tx_wr   = 1'b0,
    output reg        burst_end = 1'b0,   // clk_bus: a run of >= 512 data reads just ended
    output wire       idle                 // clk_sys: nothing left to send
);
    function [5:0] g2b(input [5:0] g);
        integer i;
        begin
            g2b[5] = g[5];
            for (i = 4; i >= 0; i = i - 1) g2b[i] = g2b[i + 1] ^ g[i];
        end
    endfunction

    // ---------------- clk_bus: capture ----------------
    reg [1:0] en_s = 2'b00;
    always @(posedge clk_bus) en_s <= {en_s[0], enable};
    wire en_b = en_s[1];

    reg [20:0] mem [0:63];
    reg  [5:0] wptr = 6'd0;
    reg  [5:0] wgray = 6'd0;
    reg  [5:0] rgray = 6'd0;
    reg  [5:0] rg_s1 = 6'd0, rg_s2 = 6'd0;
    always @(posedge clk_bus) begin rg_s1 <= rgray; rg_s2 <= rg_s1; end
    wire [5:0] rp_b = g2b(rg_s2);
    wire       full = (wptr + 6'd1) == rp_b;

    // the qualified accesses: a write, a status read, a data read
    wire a_wr = dbg_wr;
    wire a_st = dbg_rd && !dbg_ff && dbg_reg == 2'd0;
    wire a_dr = dbg_rd && !dbg_ff && dbg_reg == 2'd3;
    wire a_any = a_wr | a_st | a_dr;
    reg  a_wr_q = 1'b0, a_st_q = 1'b0, a_dr_q = 1'b0;
    wire a_rise = (a_wr && !a_wr_q) || (a_st && !a_st_q) || (a_dr && !a_dr_q);
    reg [1:0] dly = 2'd0;

    reg [15:0] dcnt = 16'd0;           // data reads in the current burst
    reg  [7:0] b0 = 8'd0, b1 = 8'd0, b2 = 8'd0, b3 = 8'd0, blast = 8'd0;
    reg  [3:0] ffrun = 4'd0;           // consecutive #FF writes logged
    reg  [7:0] last_stat = 8'd0;       // the last status logged; a poll loop repeats it
    reg        last_stat_v = 1'b0;

    reg        push = 1'b0;
    reg [20:0] rec  = 21'd0;
    // a record waiting behind a burst summary
    reg        pend_v = 1'b0;
    reg [20:0] pend   = 21'd0;
    reg  [2:0] fl = 3'd0;              // burst summary records still to push (4..1)

    always @(posedge clk_bus) begin
        push   <= 1'b0;
        burst_end <= 1'b0;
        a_wr_q <= a_wr; a_st_q <= a_st; a_dr_q <= a_dr;

        if (a_rise) dly <= 2'd2;
        else if (dly != 2'd0) dly <= dly - 2'd1;

        // ---- the sample, one clock before dly runs out ----
        if (dly == 2'd1 && a_any && en_b) begin
            if (a_dr) begin
                if (dcnt == 16'd0) b0 <= dbg_q;
                if (dcnt == 16'd1) b1 <= dbg_q;
                if (dcnt == 16'd2) b2 <= dbg_q;
                if (dcnt == 16'd3) b3 <= dbg_q;
                blast <= dbg_q;
                dcnt  <= dcnt + 16'd1;
            end
            else begin
                // a write or a status read ends a burst: summary first, this record behind it
                if (a_wr && dbg_ff) begin
                    if (ffrun != 4'd8) ffrun <= ffrun + 4'd1;
                end
                else ffrun <= 4'd0;
                if (a_wr) last_stat_v <= 1'b0;
                if (a_st) begin last_stat <= dbg_q; last_stat_v <= 1'b1; end
                if (!(a_wr && dbg_ff && ffrun == 4'd8) && !(a_st && last_stat_v && dbg_q == last_stat && dcnt == 16'd0)) begin
                    pend_v <= 1'b1;
                    pend   <= a_wr ? {2'd0, dbg_ff, dbg_reg, 8'd0, dbg_d}
                                   : {2'd1, 1'b0, 2'd0, 8'd0, dbg_q};
                end
                if (dcnt != 16'd0) fl <= 3'd4;
                if (dcnt >= 16'd512) burst_end <= 1'b1;
            end
        end

        // ---- one record per clock: the burst summary, then the pending record ----
        if (fl != 3'd0 && !full) begin
            fl   <= fl - 3'd1;
            push <= 1'b1;
            case (fl)
            3'd4: rec <= {2'd2, 1'b0, 2'd0, dcnt};
            3'd3: rec <= {2'd2, 1'b0, 2'd1, b0, b1};
            3'd2: rec <= {2'd2, 1'b0, 2'd2, b2, b3};
            default: begin rec <= {2'd2, 1'b0, 2'd3, blast, 8'd0}; dcnt <= 16'd0; end
            endcase
        end
        else if (fl == 3'd0 && pend_v && !full && !push) begin
            pend_v <= 1'b0;
            push   <= 1'b1;
            rec    <= pend;
        end
        if (!en_b) begin dcnt <= 16'd0; fl <= 3'd0; pend_v <= 1'b0; ffrun <= 4'd0; end

        if (push) begin
            mem[wptr] <= rec;
            wptr      <= wptr + 6'd1;
            wgray     <= (wptr + 6'd1) ^ ((wptr + 6'd1) >> 1);
        end
    end

    // ---------------- clk_sys: serialise ----------------
    reg [5:0] wg_s1 = 6'd0, wg_s2 = 6'd0;
    always @(posedge clk_sys) begin wg_s1 <= wgray; wg_s2 <= wg_s1; end
    wire [5:0] wp_s = g2b(wg_s2);

    reg  [5:0]  rptr = 6'd0;
    reg  [20:0] q = 21'd0;
    always @(posedge clk_sys) q <= mem[rptr];

    localparam [2:0] S_IDLE = 3'd0, S_RD = 3'd1, S_B0 = 3'd2, S_B1 = 3'd3, S_B2 = 3'd4;
    reg [2:0]  st = S_IDLE;
    reg [12:0] tmr = 13'd0;
    reg [20:0] cur = 21'd0;

    always @(posedge clk_sys) begin
        tx_wr <= 1'b0;
        if (tmr != 13'd0) tmr <= tmr - 13'd1;
        case (st)
        S_IDLE: if (rptr != wp_s && tmr == 13'd0) st <= S_RD;
        S_RD: begin cur <= q; st <= S_B0; end          // q holds mem[rptr] since the last clock
        S_B0: if (tmr == 13'd0) begin
            tx_data <= {1'b1, 2'b00, cur[20:19], cur[18], cur[17:16]};
            tx_wr   <= 1'b1;
            tmr     <= BYTE_CLKS;
            st      <= S_B1;
        end
        S_B1: if (tmr == 13'd0) begin
            tx_data <= cur[15:8];
            tx_wr   <= 1'b1;
            tmr     <= BYTE_CLKS;
            st      <= S_B2;
        end
        S_B2: if (tmr == 13'd0) begin
            tx_data <= cur[7:0];
            tx_wr   <= 1'b1;
            tmr     <= BYTE_CLKS;
            rptr    <= rptr + 6'd1;
            rgray   <= (rptr + 6'd1) ^ ((rptr + 6'd1) >> 1);
            st      <= S_IDLE;
        end
        default: st <= S_IDLE;
        endcase
    end
    assign idle = (st == S_IDLE) && (rptr == wp_s) && (tmr == 13'd0);
endmodule
