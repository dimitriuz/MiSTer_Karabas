// video_cdc.sv - the pixel-word crossing of the top: {RGB, HS, VS, BLANK}
// samples pushed on the machine's bus clock cross into the 112.5 MHz video
// clock through an async FIFO (ruling 2 of the resume note).
//
// clk_bus  the bus clock; ce_in its pixel enable (ADC_CLK = ENA_RGB): the
//          word on din is pushed on every clk_bus rising edge with ce_in.
// clk_vid  the video clock (clk_sdr); ce_out the registered pop strobe -
//          every word appears on dout exactly between two of its edges.
// stall    sim-only: hold the read side (tied 0 at the top) so a test can
//          queue several words up.
// reset    the machine ARESET on both sides (the cdc_fifo contract: held
//          for at least three clocks of the slower domain).
`default_nettype none

module video_cdc #(
    parameter integer W = 12
) (
    input  wire          clk_bus,
    input  wire          clk_vid,
    input  wire          reset,
    input  wire          ce_in,
    input  wire [W-1:0]  din,
    input  wire          stall,
    output reg           ce_out = 1'b0,
    output reg  [W-1:0]  dout = '0
);

    wire [W-1:0] q;
    wire         full;
    wire         empty;
    wire         pop = ~empty & ~stall;

    cdc_fifo #(.DW(W), .AW(3)) fifo (
        .wr_clk(clk_bus), .wr_rst(reset), .wr(ce_in), .d(din), .full(full),
        .rd_clk(clk_vid), .rd_rst(reset), .rd(pop), .q(q), .empty(empty)
    );

    // q changes together with the pointer, so at the pop edge itself q
    // still shows the word being popped: capture it on `pop` (NOT on a
    // delayed pop_d - with that the register lags ce_out by one clk_vid
    // cycle and every word arrives shifted; proven by sim/tb_video_cdc.sv)
    // - dout and ce_out then change on the same edge, and dout is stable
    // from one strobe to the next.
    always @(posedge clk_vid) begin
        ce_out <= pop;
        if (pop) dout <= q;
    end

    // synthesis translate_off
    // A push into a full FIFO silently loses the word (the cdc_fifo
    // contract); at 4x read to 1x write rate that is a design error.
    always @(posedge clk_bus) begin
        if (!reset && ce_in && full) begin
            $display("video_cdc: FAILURE: push while full at %0t", $time);
            $fatal(1, "video_cdc: push while full");
        end
    end
    // synthesis translate_on

endmodule

`default_nettype wire
