// sd_img_model.sv - SIM MODEL of the hps_io SD block interface for one disk
// slot, as tape_src sees it: the core holds sd_rd (a level) until the ack,
// the model waits for the sector, then raises sd_ack, emits 512 sd_buff_wr
// pulses with sd_buff_addr counting 0..511 and the sector's bytes on
// sd_buff_dout, and drops sd_ack.
//
// The file is the byte array mem[0:16383] (16 KB, enough for the fixtures)
// and size is its length in bytes; bytes at or past the end read as 0, as
// hps_io pads a short file. The tb fills mem with $readmemh, sets size and
// pulses the mount. The wait from sd_rd to sd_ack is at least LAT_CLKS clk
// clocks; lat is a reg so the bench can change it per case (the default is
// the parameter LAT_CLKS, needed by the prefetch_hides_latency case).
//
// A request raised while sd_ack is high is an error, as in hps_io: err goes
// sticky and the message names it. A request whose first byte is at or past
// the end of the file sets past_end (the tb clears it when it wants to
// check that no sector past the tape is fetched).
`default_nettype none

module sd_img_model #(
    parameter integer LAT_CLKS = 10   // clk clocks from sd_rd to sd_ack
) (
    input  wire        clk,           // clk_sys
    input  wire [31:0] lba,           // sector number
    input  wire        rd,            // sd_rd, a level until sd_ack
    output reg         ack,           // sd_ack
    output reg   [8:0] buff_addr,     // sd_buff_addr
    output reg   [7:0] buff_dout,     // sd_buff_dout
    output reg         buff_wr,       // sd_buff_wr
    input  wire [31:0] size,          // file size in bytes
    output reg         past_end       // a request started at/past the file end
);

    localparam [1:0] M_IDLE = 2'd0, M_WAIT = 2'd1, M_DATA = 2'd2, M_END = 2'd3;

    reg [7:0] mem [0:32767];

    reg [1:0]  state = M_IDLE;
    reg [31:0] base  = 32'd0;
    reg [31:0] lat   = LAT_CLKS;
    reg [31:0] cnt   = 32'd0;
    reg [9:0]  idx   = 10'd0;
    reg        err   = 1'b0;

    wire [31:0] off = (base << 9) + {22'd0, idx};

    always @(posedge clk) begin
        buff_wr <= 1'b0;

        case (state)
            M_IDLE: if (rd) begin
                if (ack) begin
                    $display("sd_img_model: ERROR a request was raised while sd_ack was high");
                    err <= 1'b1;
                end else begin
                    base  <= lba;
                    cnt   <= lat;
                    state <= M_WAIT;
                    if (size != 0 && ({9'd0, lba[22:0]} << 9) >= size)
                        past_end <= 1'b1;
                end
            end
            M_WAIT: if (cnt == 0) begin
                ack   <= 1'b1;
                idx   <= 10'd0;
                state <= M_DATA;
            end else
                cnt <= cnt - 32'd1;
            M_DATA: begin
                buff_wr   <= 1'b1;
                buff_addr <= idx[8:0];
                buff_dout <= (off < size) ? mem[off[14:0]] : 8'd0;
                idx       <= idx + 10'd1;
                if (idx == 10'd511)
                    state <= M_END;
            end
            M_END: begin
                ack   <= 1'b0;
                state <= M_IDLE;
            end
            default: state <= M_IDLE;
        endcase
    end

endmodule

`default_nettype wire