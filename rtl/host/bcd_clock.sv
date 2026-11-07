// bcd_clock.sv - the RTC time the MCU link sends: hps_io's RTC bytes, kept
// and advanced in the FPGA between MiSTer's HPS updates (the HPS sends the
// time about once a minute, so frames built straight from the input would
// show the seconds standing still). TSConf_MiSTer's mc146818a.v does the
// same: it loads its registers on an RTC[64] toggle and ticks them itself.
//
// now keeps hps_io's byte layout ([7:0] sec, [15:8] min, [23:16] hour,
// [31:24] date, [39:32] month, [47:40] year, [55:48] weekday), BCD
// throughout, except that the weekday is the MC146818A's 1-7 (the HPS
// weekday is 0-6, so it is +1 on every load).
//
// The registers load at reset and on every toggle of rtc[64]; otherwise one
// second passes every SEC_CLKS clocks, in BCD, 24 h: seconds 59->00 carry to
// minutes, minutes to hours, hours 23->00 to the next day. A new day
// increments the weekday (7->1) and rolls the date with the month's length
// (28/29 in February, a leap year is 2000-2099: tens digit even and units
// 0/4/8, or tens odd and units 2/6); a month rollover after 12 rolls the
// year (99->00).
`default_nettype none

module bcd_clock #(
    parameter integer SEC_CLKS = 50000000   // one second at clk = 50 MHz
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [64:0] rtc,
    output reg  [55:0] now
);

wire [7:0] s  = now[7:0];
wire [7:0] mi = now[15:8];
wire [7:0] h  = now[23:16];
wire [7:0] d  = now[31:24];
wire [7:0] mo = now[39:32];
wire [7:0] y  = now[47:40];
wire [7:0] wd = now[55:48];

function [7:0] bcd_inc;
    input [7:0] v;
    begin
        bcd_inc = (v[3:0] == 4'd9) ? {v[7:4] + 4'd1, 4'd0}
                                   : {v[7:4], v[3:0] + 4'd1};
    end
endfunction

// 2000-2099: divisible by four
wire leap = y[4] ? (y[3:0] == 4'd2 || y[3:0] == 4'd6)
                 : (y[3:0] == 4'd0 || y[3:0] == 4'd4 || y[3:0] == 4'd8);

wire [7:0] dmax = (mo == 8'h02) ? (leap ? 8'h29 : 8'h28) :
                  (mo == 8'h04 || mo == 8'h06 ||
                   mo == 8'h09 || mo == 8'h11) ? 8'h30 : 8'h31;

wire sec_c  = (s == 8'h59);
wire min_c  = sec_c && (mi == 8'h59);
wire hour_c = min_c && (h == 8'h23);
wire day_c  = hour_c && (d == dmax);
wire mon_c  = day_c && (mo == 8'h12);

wire [55:0] next_now;
assign next_now[7:0]   = sec_c  ? 8'h00 : bcd_inc(s);
assign next_now[15:8]  = min_c  ? 8'h00 : (sec_c  ? bcd_inc(mi) : mi);
assign next_now[23:16] = hour_c ? 8'h00 : (min_c  ? bcd_inc(h)  : h);
assign next_now[31:24] = day_c  ? 8'h01 : (hour_c ? bcd_inc(d)  : d);
assign next_now[39:32] = day_c  ? (mon_c ? 8'h01 : bcd_inc(mo)) : mo;
assign next_now[47:40] = mon_c  ? ((y == 8'h99) ? 8'h00 : bcd_inc(y)) : y;
assign next_now[55:48] = hour_c ? ((wd == 8'h07) ? 8'h01 : wd + 8'd1) : wd;

reg [31:0] tick;
reg        rtc64_prev;

wire load = rtc[64] != rtc64_prev;

always @(posedge clk) begin
    if (reset) begin
        now        <= {rtc[55:48] + 8'd1, rtc[47:0]};
        tick       <= 32'd0;
        rtc64_prev <= rtc[64];
    end else begin
        rtc64_prev <= rtc[64];
        if (load) begin
            now  <= {rtc[55:48] + 8'd1, rtc[47:0]};
            tick <= 32'd0;
        end else if (tick >= SEC_CLKS - 1) begin
            tick <= 32'd0;
            now  <= next_now;
        end else
            tick <= tick + 32'd1;
    end
end

endmodule