// cdc_fifo.sv - SIM MODEL of rtl/mem/cdc_fifo.vhd for the Icarus flow of
// sim/run_tb_video_cdc.sh (Icarus cannot bind the VHDL entity). Same
// interface, same Cummings pointer protocol: gray pointers, two-flop
// synchronisers, combinational q from the read pointer. The real cell is
// exercised through the VHDL side by tb_cdc_fifo.
`default_nettype none

module cdc_fifo #(
    parameter integer DW = 8,
    parameter integer AW = 2
) (
    input  wire             wr_clk,
    input  wire             wr_rst,
    input  wire             wr,
    input  wire [DW-1:0]    d,
    output wire             full,
    input  wire             rd_clk,
    input  wire             rd_rst,
    input  wire             rd,
    output reg  [DW-1:0]    q,
    output wire             empty
);

    reg [DW-1:0] cells [0:(1<<AW)-1];
    reg [AW:0] wb = 0, wbg = 0, rb = 0, rbg = 0;
    reg [AW:0] wbg_s1 = 0, wbg_s2 = 0, rbg_s1 = 0, rbg_s2 = 0;

    function [AW:0] to_gray(input [AW:0] b);
        integer i;
        begin
            to_gray = b;
            for (i = 0; i < AW; i = i + 1)
                to_gray[i] = b[i] ^ b[i+1];
        end
    endfunction

    always @(posedge wr_clk) begin
        if (wr_rst) begin
            wb  <= 0;
            wbg <= 0;
        end else if (wr) begin
            cells[wb[AW-1:0]] <= d;
            wb  <= wb + 1'b1;
            wbg <= to_gray(wb + 1'b1);
        end
    end

    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rb  <= 0;
            rbg <= 0;
        end else if (rd) begin
            rb  <= rb + 1'b1;
            rbg <= to_gray(rb + 1'b1);
        end
    end

    always @(posedge rd_clk) begin
        if (rd_rst) begin wbg_s1 <= 0; wbg_s2 <= 0; end
        else begin wbg_s1 <= wbg; wbg_s2 <= wbg_s1; end
    end

    always @(posedge wr_clk) begin
        if (wr_rst) begin rbg_s1 <= 0; rbg_s2 <= 0; end
        else begin rbg_s1 <= rbg; rbg_s2 <= rbg_s1; end
    end

    always @(*) q = cells[rb[AW-1:0]];

    assign empty = (rbg == wbg_s2);
    assign full  = (wbg == {~rbg_s2[AW:AW-1], rbg_s2[AW-2:0]});

endmodule

`default_nettype wire
