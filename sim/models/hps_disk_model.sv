// hps_disk_model.sv - SIM MODEL of hps_io's sector transport for the two
// image slots img_src serves (hps_io disk slots 4 and 5). It mirrors
// sim/models/sd_img_model.sv with a slot bit on every signal, and adds the
// write direction:
//
//   read:  the core raises rd[i] (a level) with lba_i and holds it until
//          ack[i]; the model waits at least LAT_CLKS clk clocks, raises
//          ack[i], emits 512 buff_wr pulses with buff_addr counting 0..511
//          and the sector's bytes on buff_dout, and drops ack[i].
//   write: the same with wr[i] and buff_wr low: the model addresses each
//          byte on buff_addr and samples buff_din two clocks later (the
//          core's registered read; hps_io reads sd_buff_din one strobe
//          apart, so two clocks is its timing with room to spare).
//
// One request at a time, as hps_io has it: one engine serves both slots and
// the core serialises its requests. The memory is mem[slot][0:1048575]
// (1 MB, 2048 sectors, per slot) and the tb reads and writes it through the
// instance (hps.mem[slot][off]), the way tb_tape_src fills sd_img_model's
// mem. img_size is one size for both slots, as the main module has one
// img_size input. Bytes at or past the end read as 0 (hps_io pads a short
// file), and a request whose first byte is at or past the end sets
// past_end[slot] (sticky; the tb clears it).
`default_nettype none

module hps_disk_model #(
    parameter integer LAT_CLKS = 10   // clk clocks from the request to ack
) (
    input  wire        clk,           // clk_sys
    input  wire [63:0] img_size,      // bytes, one size for both slots
    input  wire  [1:0] rd,            // the core's requests, levels until ack
    input  wire  [1:0] wr,
    input  wire [31:0] lba_a,
    input  wire [31:0] lba_b,
    output reg   [1:0] ack = 2'b00,    // ack[i] while slot i transfers
    output reg   [8:0] buff_addr,
    output reg   [7:0] buff_dout,
    output reg         buff_wr,
    input  wire  [7:0] buff_din,
    output reg   [1:0] past_end       // a request touched a sector past the file
);

    localparam [2:0] M_IDLE  = 3'd0;
    localparam [2:0] M_WAIT  = 3'd1;  // LAT_CLKS
    localparam [2:0] M_DATA  = 3'd2;  // read: 512 buff_wr pulses
    localparam [2:0] M_WADDR = 3'd3;  // write: the byte address
    localparam [2:0] M_WWAIT = 3'd4;  // write: one clock for the core's read
    localparam [2:0] M_WDATA = 3'd5;  // write: sample buff_din
    localparam [2:0] M_END   = 3'd6;

    reg [7:0] mem [0:1][0:1048575];

    reg [2:0]  state = M_IDLE;
    reg        cur = 1'b0;            // the slot being served
    reg        wrm = 1'b0;            // the request is a write
    reg [31:0] base = 32'd0;
    reg [31:0] lat = LAT_CLKS;
    reg [31:0] cnt = 32'd0;
    reg  [9:0] idx = 10'd0;

    wire        slot_b = rd[1] | wr[1];
    wire [31:0] req_lba = slot_b ? lba_b : lba_a;
    wire [63:0] pos = ({32'd0, base} << 9) + {54'd0, idx};

    always @(posedge clk) begin
        buff_wr <= 1'b0;

        case (state)
            M_IDLE: begin
                if (rd[1] && wr[1])
                    $display("hps_disk_model: ERROR slot b read and write at once");
                else if (rd[0] && wr[0])
                    $display("hps_disk_model: ERROR slot a read and write at once");
                else if (rd != 2'b00 || wr != 2'b00) begin
                    if (ack != 2'b00)
                        $display("hps_disk_model: ERROR a request was raised while ack was high");
                    cur   <= slot_b;
                    wrm   <= |wr;
                    base  <= req_lba;
                    cnt   <= lat;
                    idx   <= 10'd0;
                    if (({32'd0, req_lba} << 9) >= img_size) begin
                        if (slot_b) past_end[1] <= 1'b1;
                        else        past_end[0] <= 1'b1;
                    end
                    state <= M_WAIT;
                end
            end
            M_WAIT: begin
                if (cnt == 0) begin
                    ack   <= cur ? 2'b10 : 2'b01;
                    state <= wrm ? M_WADDR : M_DATA;
                    idx   <= 10'd0;
                end else
                    cnt <= cnt - 32'd1;
            end
            M_DATA: begin
                buff_wr   <= 1'b1;
                buff_addr <= idx[8:0];
                buff_dout <= (pos < img_size) ? mem[cur][pos[19:0]] : 8'd0;
                idx       <= idx + 10'd1;
                if (idx == 10'd511)
                    state <= M_END;
            end
            M_WADDR: begin
                buff_addr <= idx[8:0];
                state     <= M_WWAIT;
            end
            M_WWAIT: state <= M_WDATA;
            M_WDATA: begin
                mem[cur][pos[19:0]] <= buff_din;
                idx <= idx + 10'd1;
                if (idx == 10'd511)
                    state <= M_END;
                else
                    state <= M_WADDR;
            end
            M_END: begin
                ack   <= 2'b00;
                state <= M_IDLE;
            end
            default: state <= M_IDLE;
        endcase
    end

endmodule

`default_nettype wire