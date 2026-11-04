// mcu_spi_master.sv - one 24-bit frame (CMD ADDR DATA) of the Karabas MCU
// link per `start`, SPI mode 0 (the slave samples on the rising SCK edge),
// MSB first.
//
// kg_spi_slave clocks its shifter with SCK itself, so SCK comes from a
// register and never glitches: it is high and low DIV/2 clk clocks each
// (DIV even, >= 4). MOSI changes on the falling SCK edge, half a period
// away from every rising edge, and CS stays low around the whole frame:
// the last falling SCK edge is the one that completes the slave's receive
// word, so CS rises one clock after it.
//
// After the frame CS stays high GAP clocks: kg_mcu filters the chip select
// over 3 clk_bus clocks, and the word the slave shifts out next was only
// popped from the reply queue some 7 clk_bus clocks after this frame
// (kg_mcu_link), so it needs the gap to reach the slave's input register.
//
// rx is the word the slave shifted out during this same frame
// (docs/protocol.md section 2): MISO is sampled one clock after each
// rising SCK edge, DIV/2 - 1 clocks before the slave shifts the next bit.
// rx_valid pulses with busy falling at the end of the GAP, so a master
// that fires the next frame when it sees rx_valid keeps CS high for GAP.
`default_nettype none

module mcu_spi_master #(
    parameter integer DIV = 4,   // clk clocks per SCK period (even, >= 4)
    parameter integer GAP = 32   // clk clocks CS stays high after a frame
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [23:0] tx,
    input  wire        start,    // one clock, only while idle
    output reg         busy,
    output reg  [23:0] rx,
    output reg         rx_valid,
    output reg         spi_cs_n,
    output reg         spi_sck,
    output reg         spi_mosi,
    input  wire        spi_miso
);

localparam integer HALF  = DIV / 2;
localparam integer SETUP = DIV;  // CS low before the first rising SCK edge

localparam [2:0] S_IDLE = 3'd0, S_CSUP = 3'd1, S_HIGH = 3'd2,
                 S_LOW  = 3'd3, S_TAIL = 3'd4;

reg [2:0]  state;
reg [31:0] cnt;
reg [4:0]  bitn;      // rising SCK edges left to sample (counts 24 down to 0)
reg [23:0] sr;
reg        sck_d;

// the link is idle before the first clock: SCK low, CS high
initial begin
    state    = S_IDLE;
    busy     = 1'b0;
    spi_cs_n = 1'b1;
    spi_sck  = 1'b0;
    spi_mosi = 1'b0;
    rx       = 24'd0;
    rx_valid = 1'b0;
    sck_d    = 1'b0;
end

always @(posedge clk) begin
    if (reset) begin
        state     <= S_IDLE;
        busy      <= 1'b0;
        spi_cs_n  <= 1'b1;
        spi_sck   <= 1'b0;
        spi_mosi  <= 1'b0;
        rx        <= 24'd0;
        rx_valid  <= 1'b0;
        sck_d     <= 1'b0;
    end else begin
        rx_valid <= 1'b0;
        busy     <= state != S_IDLE;
        sck_d    <= spi_sck;
        if (spi_sck && !sck_d) begin   // rising edge was last clock
            rx   <= {rx[22:0], spi_miso};
            bitn <= bitn - 5'd1;
        end
        case (state)
            S_IDLE: begin
                spi_cs_n <= 1'b1;
                if (start) begin
                    busy     <= 1'b1;
                    sr       <= tx;
                    spi_mosi <= tx[23];
                    spi_cs_n <= 1'b0;
                    cnt      <= 32'd0;
                    state    <= S_CSUP;
                end
            end
            S_CSUP: begin
                if (cnt == SETUP - 1) begin
                    spi_sck <= 1'b1;
                    cnt     <= 32'd0;
                    bitn    <= 5'd24;
                    state   <= S_HIGH;
                end else
                    cnt <= cnt + 32'd1;
            end
            S_HIGH: begin
                if (cnt == HALF - 1) begin
                    spi_sck  <= 1'b0;             // falling: the slave has
                    sr       <= {sr[22:0], 1'b0}; // sampled; present the
                    spi_mosi <= sr[22];           // next bit now, HALF
                                                  // clocks before the rise
                    cnt      <= 32'd0;
                    state    <= S_LOW;
                end else
                    cnt <= cnt + 32'd1;
            end
            S_LOW: begin
                if (cnt == HALF - 1) begin
                    if (bitn == 5'd0) begin   // edge 24 fell: end the frame
                        spi_cs_n <= 1'b1;
                        cnt      <= 32'd0;
                        state    <= S_TAIL;
                    end else begin
                        spi_sck  <= 1'b1;     // MOSI already holds this bit
                        cnt      <= 32'd0;
                        state    <= S_HIGH;
                    end
                end else
                    cnt <= cnt + 32'd1;
            end
            S_TAIL: begin
                if (cnt == GAP - 1) begin
                    busy     <= 1'b0;
                    rx_valid <= 1'b1;
                    state    <= S_IDLE;
                end else
                    cnt <= cnt + 32'd1;
            end
            default: state <= S_IDLE;
        endcase
    end
end

endmodule
