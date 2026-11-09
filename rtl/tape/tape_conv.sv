// tape_conv.sv - a streaming TAP/TZX to CSW converter for tape_src.
//
// The TAP and TZX players of the ZX core fail the data block on this
// machine's Profi ROM even when their waveform is byte-perfect (see
// docs/dev/stage4a-results.md). The CSW player in tape.sv plays the same
// bytes correctly, so this module turns a mounted TAP/TZX file into the CSW
// byte stream that player consumes: the 32-byte CSW v1 header zxtap.py
// writes (tape.sv's hdrsz), then RLE pulse lengths for each block (lead-in,
// sync, bits, pause). sim/tb_conv checks the output byte for byte against
// zxtap.py's CSW of the same TAP, for both the TAP and the TZX form.
//
// Input: the original file through tape_src's sector cache
// (in_addr/in_req/in_data/in_valid); the read address jumps when the tape
// is navigated. Output: tape.sv's rd/rd_en handshake. Supported: TAP and
// the TZX standard-speed 0x10 block. Any other TZX block ends the tape
// (metadata/other block types are not converted yet).
//
// Block navigation: the OSD's Tape previous/next block items arrive as
// prev/next levels. Each block's first source byte is remembered (cur_start,
// prev_start) and, once its flag byte has been read, its end (blk_end).
// A jump rewinds the input reader and restarts the parser at the target
// block; blk_seek tells tape.sv to drop its CSW RLE state at the same time,
// so the player resumes at the new block's first pulse.
`default_nettype none

module tape_conv (
    input  wire        clk,
    input  wire        active,      // converter mode and tape_ready
    input  wire [1:0]  src_mode,    // 0 TAP, 2 TZX
    input  wire [24:0] in_size,
    output wire [24:0] in_addr,     // read address; jumps on a block seek
    output reg         in_req,
    input  wire [7:0]  in_data,
    input  wire        in_valid,
    input  wire        rd,
    output reg  [7:0]  din,
    output reg         rd_en,
    output reg         done,
    // prev/next from the OSD (levels, edge-detected here): jump to the
    // neighbouring block of the source file; blk_seek tells the player to
    // restart its CSW parse at the new block's first byte
    input  wire        prev,
    input  wire        next,
    output reg         blk_seek
);

    localparam [1:0] SRC_TAP = 2'd0, SRC_TZX = 2'd2;

    localparam [4:0] P_HDR = 5'd0, P_TAPLEN = 5'd1, P_TZXHDR = 5'd2,
                     P_TZXID = 5'd3, P_TZX10 = 5'd4, P_FLAG = 5'd5,
                     P_PILOT = 5'd6, P_SYNC1 = 5'd7, P_SYNC2 = 5'd8,
                     P_DATA = 5'd9, P_NEXTBYTE = 5'd10, P_CALC = 5'd11,
                     P_PAUSE = 5'd12, P_NEXT = 5'd13, P_END = 5'd14;

    // ------------------------- input reader -------------------------
    reg  [7:0] rq_byte = 8'd0;
    reg        rq_have = 1'b0;
    reg        want = 1'b0;
    reg        take = 1'b0;
    reg [24:0] rd_addr = 25'd0;
    assign in_addr = rd_addr;

    // block navigation state
    reg        old_prev = 1'b0, old_next = 1'b0;
    reg [24:0] cur_start = 25'd0, prev_start = 25'd0;
    reg [24:0] blk_end = 25'd0;
    reg        blk_end_ok = 1'b0;
    reg        seek_req = 1'b0;
    reg [24:0] seek_addr = 25'd0;
    reg  [4:0] seek_phase = 5'd0;
    wire nav_edge = (prev & ~old_prev) | (next & ~old_next);

    // ---------------------- parser and output -----------------------
    reg [4:0]  phase = P_HDR;
    reg [7:0]  out_byte = 8'd0;
    reg        out_valid = 1'b0;

    reg [5:0]  hdr_i = 6'd0;
    reg [1:0]  len_i = 2'd0;
    reg  [7:0] len_lo = 8'd0;
    reg [15:0] blen = 16'd0;
    reg [15:0] bytes_left = 16'd0;
    reg  [7:0] flag = 8'd0;
    reg  [7:0] cur = 8'd0;
    reg  [3:0] data_bit = 4'd0;
    reg        bit_half = 1'b0;
    reg [15:0] pilot_left = 16'd0;
    reg [2:0]  pause_i = 3'd0;
    reg [1:0]  tzx10_i = 2'd0;
    reg [15:0] pause_ms = 16'd0;
    reg [24:0] pause_samp = 25'd0;
    reg [5:0]  calc_i = 6'd0;
    reg [31:0] calc_q = 32'd0;
    reg [31:0] calc_rem = 32'd0;
    reg [31:0] calc_shr = 32'd0;
    // pause_ms * 441 = pause_ms * 44.1 * 10; the /10 is a restoring division
    // over 32 clocks (one 32-bit compare/subtract per clock). The single-cycle
    // multiply+divide was a ~56 ns clk_bus28 path and failed setup.
    wire [31:0] pm = {16'd0, pause_ms};
    wire [31:0] calc_prod = pm + (pm << 3) + (pm << 4) + (pm << 5)
                              + (pm << 7) + (pm << 8);
    reg [9:0]  tzxh_i = 10'd0;
    reg [19:0] end_wait = 20'd0;

    always @(posedge clk) begin
        if (!active) begin
            phase     <= P_HDR;
            hdr_i     <= 6'd0;
            len_i     <= 2'd0;
            out_valid <= 1'b0;
            rd_en     <= 1'b0;
            done      <= 1'b0;
            end_wait  <= 20'd0;
            pause_i   <= 3'd0;
            rd_addr    <= 25'd0;
            in_req     <= 1'b0;
            rq_have    <= 1'b0;
            cur_start  <= 25'd0;
            prev_start <= 25'd0;
            blk_end_ok <= 1'b0;
            seek_req   <= 1'b0;
            blk_seek   <= 1'b0;
            old_prev   <= 1'b0;
            old_next   <= 1'b0;
        end else begin
            // input reader (one byte at a time, seekable)
            take <= 1'b0;
            blk_seek <= 1'b0;
            if (seek_req) begin
                rd_addr  <= seek_addr;
                in_req   <= 1'b0;
                rq_have  <= 1'b0;
                len_i    <= 2'd0;
                seek_req <= 1'b0;
                phase    <= seek_phase;
                blk_seek <= 1'b1;
            end
            if (in_req && in_valid && !seek_req) begin
                rq_byte <= in_data;
                rq_have <= 1'b1;
                in_req  <= 1'b0;
            end
            if (take) begin
                rq_have <= 1'b0;
                rd_addr <= rd_addr + 25'd1;
            end
            if (want && !in_req && !rq_have && !take && !seek_req) in_req <= 1'b1;

            // prev/next: jump to the neighbouring block of the source file
            old_prev <= prev;
            old_next <= next;
            if (!seek_req && (prev & ~old_prev)) begin
                seek_req   <= 1'b1;
                seek_phase <= (src_mode == SRC_TZX) ? P_TZXID : P_TAPLEN;
                if (rd_addr > cur_start) seek_addr <= cur_start;
                else if (cur_start != 25'd0) seek_addr <= prev_start;
                else seek_addr <= rd_addr;
                out_valid  <= 1'b0;
                rd_en      <= 1'b0;
                blk_end_ok <= 1'b0;
            end
            if (!seek_req && (next & ~old_next) && blk_end_ok) begin
                seek_req   <= 1'b1;
                seek_addr  <= blk_end;
                seek_phase <= (src_mode == SRC_TZX) ? P_TZXID : P_TAPLEN;
                out_valid  <= 1'b0;
                rd_en      <= 1'b0;
                blk_end_ok <= 1'b0;
            end

            // player byte handshake
            if (!rd_en) rd_en <= 1'b1;
            else if (!rd) rd_en <= 1'b0;
            else if (out_valid) begin
                din       <= out_byte;
                rd_en     <= 1'b0;
                out_valid <= 1'b0;
            end

            if (!out_valid && !seek_req && !nav_edge) begin
                case (phase)
                P_HDR: begin
                    // exactly the 32 bytes zxtap.py writes: tape.sv consumes
                    // the header (hdrsz 32) and plays the first pulse after it
                    if (hdr_i < 6'd32) begin
                        out_byte  <= csw_header(hdr_i);
                        out_valid <= 1'b1;
                        hdr_i     <= hdr_i + 6'd1;
                    end else begin
                        hdr_i <= 6'd0;
                        phase <= (src_mode == SRC_TZX) ? P_TZXHDR : P_TAPLEN;
                    end
                end

                P_TAPLEN: begin
                    want <= 1'b1;
                    if (rd_addr >= in_size) phase <= P_END;
                    else if (rq_have && !take) begin
                        take <= 1'b1;
                        if (len_i == 2'd0) begin
                            prev_start <= cur_start;
                            cur_start  <= rd_addr;
                            blk_end_ok <= 1'b0;
                            len_lo <= rq_byte;
                            len_i  <= 2'd1;
                        end else begin
                            blen   <= {rq_byte, len_lo};
                            len_i  <= 2'd0;
                            phase  <= P_FLAG;
                            want   <= 1'b0;
                        end
                    end
                end

                P_TZXHDR: begin
                    want <= 1'b1;
                    if (rd_addr >= in_size) phase <= P_END;
                    else if (rq_have && !take) begin
                        take <= 1'b1;
                        tzxh_i <= tzxh_i + 10'd1;
                        if (tzxh_i == 10'd9) begin
                            tzxh_i <= 10'd0;
                            phase  <= P_TZXID;
                            want   <= 1'b0;
                        end
                    end
                end

                P_TZXID: begin
                    want <= 1'b1;
                    if (rd_addr >= in_size) phase <= P_END;
                    else if (rq_have && !take) begin
                        take <= 1'b1;
                        prev_start <= cur_start;
                        cur_start  <= rd_addr;
                        blk_end_ok <= 1'b0;
                        tzx10_i <= 2'd0;
                        phase <= (rq_byte == 8'h10) ? P_TZX10 : P_END;
                        want  <= 1'b0;
                    end
                end

                P_TZX10: begin
                    want <= 1'b1;
                    if (rd_addr >= in_size) phase <= P_END;
                    else if (rq_have && !take) begin
                        take <= 1'b1;
                        case (tzx10_i)
                        2'd0: pause_ms[7:0]  <= rq_byte;
                        2'd1: pause_ms[15:8] <= rq_byte;
                        2'd2: blen[7:0]      <= rq_byte;
                        default: begin
                            blen[15:8] <= rq_byte;
                            phase <= P_FLAG;
                            want  <= 1'b0;
                        end
                        endcase
                        tzx10_i <= tzx10_i + 2'd1;
                    end
                end

                P_FLAG: begin
                    want <= 1'b1;
                    if (rd_addr >= in_size) phase <= P_END;
                    else if (rq_have && !take) begin
                        take <= 1'b1;
                        flag  <= rq_byte;
                        cur   <= rq_byte;
                        bytes_left <= blen - 16'd1;
                        pilot_left <= rq_byte[7] ? 16'd8064 : 16'd8063;
                        data_bit <= 4'd7;
                        bit_half <= 1'b0;
                        blk_end    <= rd_addr + {9'd0, blen};
                        blk_end_ok <= 1'b1;
                        phase <= P_PILOT;
                        want  <= 1'b0;
                    end
                end

                P_PILOT: begin
                    out_byte  <= 8'd27;
                    out_valid <= 1'b1;
                    if (pilot_left <= 16'd1) phase <= P_SYNC1;
                    pilot_left <= pilot_left - 16'd1;
                end

                P_SYNC1: begin
                    out_byte  <= 8'd8;
                    out_valid <= 1'b1;
                    phase <= P_SYNC2;
                end

                P_SYNC2: begin
                    out_byte  <= 8'd9;
                    out_valid <= 1'b1;
                    phase <= P_DATA;
                end

                P_DATA: begin
                    // two RLE bytes per bit, MSB first
                    out_byte  <= cur[7] ? 8'd22 : 8'd11;
                    out_valid <= 1'b1;
                    if (!bit_half) begin
                        bit_half <= 1'b1;
                    end else begin
                        bit_half <= 1'b0;
                        cur <= {cur[6:0], 1'b0};
                        if (data_bit == 4'd0) begin
                            if (bytes_left == 16'd0) begin
                                pause_i <= 3'd0;
                                if (src_mode == SRC_TZX) begin
                                    phase  <= P_CALC;
                                    calc_i <= 6'd0;
                                end else begin
                                    phase      <= P_PAUSE;
                                    pause_samp <= 25'd44100;  // 1000 ms at 44100 Hz
                                end
                            end else begin
                                phase <= P_NEXTBYTE;
                                want  <= 1'b1;
                            end
                        end else begin
                            data_bit <= data_bit - 4'd1;
                        end
                    end
                end

                P_NEXTBYTE: begin
                    want <= 1'b1;
                    if (rd_addr >= in_size) phase <= P_END;
                    else if (rq_have && !take) begin
                        take <= 1'b1;
                        cur  <= rq_byte;
                        bytes_left <= bytes_left - 16'd1;
                        data_bit <= 4'd7;
                        bit_half <= 1'b0;
                        phase <= P_DATA;
                        want  <= 1'b0;
                    end
                end

                P_CALC: begin
                    // pause_samp = calc_prod / 10, one quotient bit per clock
                    if (calc_i == 6'd0) begin
                        calc_q   <= 32'd0;
                        calc_rem <= 32'd0;
                        calc_shr <= calc_prod;
                        calc_i   <= 6'd1;
                    end else if (calc_i <= 6'd32) begin
                        calc_shr <= {calc_shr[30:0], 1'b0};
                        calc_q   <= {calc_q[30:0], 1'b0};
                        if ({calc_rem[30:0], calc_shr[31]} >= 32'd10) begin
                            calc_rem <= {calc_rem[30:0], calc_shr[31]} - 32'd10;
                            calc_q   <= {calc_q[30:0], 1'b1};
                        end else begin
                            calc_rem <= {calc_rem[30:0], calc_shr[31]};
                        end
                        calc_i <= calc_i + 6'd1;
                    end else begin
                        pause_samp <= calc_q[24:0];
                        pause_i    <= 3'd0;
                        phase      <= P_PAUSE;
                    end
                end

                P_PAUSE: begin
                    want <= 1'b0;
                    if (pause_samp == 25'd0) begin
                        phase <= P_NEXT;
                    end else if (pause_samp <= 25'd255) begin
                        out_byte  <= pause_samp[7:0];
                        out_valid <= 1'b1;
                        phase <= P_NEXT;
                    end else begin
                        case (pause_i)
                        3'd0: begin out_byte <= 8'd0; out_valid <= 1'b1; pause_i <= 3'd1; end
                        3'd1: begin out_byte <= pause_samp[7:0];   out_valid <= 1'b1; pause_i <= 3'd2; end
                        3'd2: begin out_byte <= pause_samp[15:8];  out_valid <= 1'b1; pause_i <= 3'd3; end
                        3'd3: begin out_byte <= pause_samp[23:16]; out_valid <= 1'b1; pause_i <= 3'd4; end
                        default: begin out_byte <= pause_samp[24]; out_valid <= 1'b1; phase <= P_NEXT; end
                        endcase
                    end
                end

                P_NEXT: begin
                    if (rd_addr >= in_size) begin
                        phase <= P_END;
                    end else if (src_mode == SRC_TZX) begin
                        phase <= P_TZXID;
                    end else begin
                        phase <= P_TAPLEN;
                    end
                end

                P_END: begin
                    want <= 1'b0;
                    // let the last pulse (and checksum bit) finish before
                    // tape_ready drops and resets the player
                    if (end_wait == 20'hFFFFF) done <= 1'b1;
                    else end_wait <= end_wait + 20'd1;
                end
                default: phase <= P_END;
                endcase
            end
        end
    end

    function [7:0] csw_header(input [5:0] i);
        case (i)
            5'd0:  csw_header = "C";  5'd1:  csw_header = "o";
            5'd2:  csw_header = "m";  5'd3:  csw_header = "p";
            5'd4:  csw_header = "r";  5'd5:  csw_header = "e";
            5'd6:  csw_header = "s";  5'd7:  csw_header = "s";
            5'd8:  csw_header = "e";  5'd9:  csw_header = "d";
            5'd10: csw_header = " ";  5'd11: csw_header = "S";
            5'd12: csw_header = "q";  5'd13: csw_header = "u";
            5'd14: csw_header = "a";  5'd15: csw_header = "r";
            5'd16: csw_header = "e";  5'd17: csw_header = " ";
            5'd18: csw_header = "W";  5'd19: csw_header = "a";
            5'd20: csw_header = "v";  5'd21: csw_header = "e";
            5'd22: csw_header = 8'h1a;
            5'd23: csw_header = 8'd1;
            5'd24: csw_header = 8'd1;
            5'd25: csw_header = 8'h44;   // 44100 LE low
            5'd26: csw_header = 8'hAC;   // 44100 LE high
            5'd27: csw_header = 8'd1;    // RLE
            5'd28: csw_header = 8'd0;    // flags
            default: csw_header = 8'd0;  // three zeros
        endcase
    endfunction

endmodule

`default_nettype wire