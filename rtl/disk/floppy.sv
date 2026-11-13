// floppy.sv - the floppy drives of the VG93 (stage 4c): a MiSTer drive model
// for the unpatched upstream controller (hrdy_fdc + fdd_glue, profi.vhd wires
// the drive pins to this module). One module, two drives: the VG93 has the
// single Beta Disk port #FF, so drive selection, side, motor, step and write
// data come as they do on the real ribbon cable, and everything the model
// decides is flux.
//
// Flux. clk_bus ticks the cell cadence: a cell tick every cell_den/cell_num
// clocks (4/225 at 28.125 MHz and 14/675 at the DS80's 24.107 MHz is 500 kHz,
// half an MFM cell; the top picks them with the disk speed). A revolution is
// 100 000 ticks = 200 ms, /INDEX is high for its first 500 ticks (1 ms) and
// the 6250 bytes of a track are read 16 ticks to the byte from the store's
// buffer. Every 16th tick the byte counter moves and the MFM encoder shifts
// the 16 channel bits of that byte (a sync byte is 4489h, otherwise the clock
// bit is "the previous bit and this bit are both 0", the encoder of the
// upstream tb_hrdy_fdc bench); a channel 1 raises RDATA for 8 clocks - the
// separator in fdd_glue needs two samples of the level, and its flux event is
// the falling edge of /RDATA, which is this rising edge. INDEX and RDATA are
// low while the motor is off or no drive is selected.
//
// The track the drive reads lives in the store (Task 4, fdd_store on gs_clk).
// A step, a side flip or a select moves the head, and the model asks for the
// track with a toggle handshake: trk_req_tgl with {drive, side, track}; an
// answer whose echo matches and whose ready is 1 switches the stream from 4Eh
// filler to the buffer at the next index (the store gets a whole revolution to
// build it, and a real drive has no other way to change tracks either). ready
// 0 keeps the filler and index keeps pulsing, which is what an empty drive
// looks like to the chip; while nothing is ready the request is asked again at
// every index, so a mount the store noticed on its own is picked up within a
// revolution without a second head movement.
//
// Writing. WD pulses of the chip (only inside WGATE; hrdy_fdc gates them) are
// measured with a free running integer counter: n = (dt + HALF) / CELL_CLK
// with CELL_CLK/HALF = 56/28 at 28 MHz and 48/24 at 24 MHz - the chip's write
// cell is 2 CLK of a 1 MHz CLK, 1991 ns, so 1, 2 or 3 of them per cell
// interval and no real arithmetic. n cells are shifted into a 48-bit register
// (the upstream bench's decoder shape); 3x4489h is a sync, the byte after it
// is FE (an ID: C,H,R,N and 2 CRC bytes, checked) or FB/F8 (a data field of
// 128<<N bytes and 2 CRC bytes, checked; N above 3 does not fit the 1024-byte
// buffer and is dropped). The write target is the last ID the drive *emitted*
// with a good CRC before WGATE rose: the chip read that ID from this same flux,
// which is why the drive knows it (the TRD convention keeps H=0 in the IDs of
// both sides, so wr_info carries the head's side as well). On the fall of
// WGATE with a complete, CRC-good data field the written sector goes to the
// store with wr_tgl and wr_info; the next field is ignored until wr_ack_tgl
// answers, and a drive that reports write protect captures nothing at all (the
// status bit comes from fdc_wprt, the chip tests it itself). The read stream
// keeps running through WGATE, as it does on a real drive: after the store has
// patched the buffer the next revolution reads the new bytes.
//
// The buffers themselves are the store's altsyncram instances: port B of the
// track buffer is read here (that is the address below, one track of 6250 9-bit
// words), port A of the written-sector buffer is written here. trk_addr_a
// mirrors the read address (a store that looks at port A on gs_clk may);
// nothing in this module reads trk_q_a.
//
// swap is profi's FDC_SWAP_O (port #028B bit 3): it exchanges the A/B mapping
// of the select lines and nothing else. fdc_side_n is profi's FDC_SIDE_N, which
// upstream drives from hrdy_fdc's FDC_SIDE1: high is side 1.
`default_nettype none

module floppy (
    input  wire        clk, reset,          // clk_bus
    input  wire        ds80,                // synchronised at the top (vmode[3])
    input  wire        swap,                // profi FDC_SWAP_O, synchronised
    input  wire [15:0] cell_num, cell_den,  // cadence; top wires 4/225 or 14/675 by ds80
    // profi drive pins (active high at the boundary)
    input  wire [1:0]  fdc_drive,           // one-hot {B,A}, motor-gated upstream
    input  wire        fdc_motor, fdc_step, fdc_dir, fdc_side_n,
    input  wire        fdc_wgate, fdc_wdata,
    output reg         fdc_rdata, fdc_index,
    output wire        fdc_tr00, fdc_wprt,
    input  wire [1:0]  wprt,                // per-drive readonly, synchronised
    // store side (gs_clk), toggle handshakes
    output reg         trk_req_tgl,
    output reg  [8:0]  trk_req,             // {drive, side, track[6:0]}
    input  wire        trk_ack_tgl,
    input  wire  [9:0] trk_ack,             // {ready, drive, side, track[6:0]}
    // track buffers: port B read here, port A written by the store
    output wire [12:0] trk_addr_a, trk_addr_b,
    input  wire  [8:0] trk_q_a, trk_q_b,    // {sync, byte}
    // written sector: one shared 1024x8 buffer, port A written here
    output reg         wr_tgl,
    output reg  [35:0] wr_info,             // {drive, side, track[6:0], C, H, R, N[2:0]}
    input  wire        wr_ack_tgl,
    output wire [9:0]  wr_addr, output wire [7:0] wr_data, output wire wr_we
);

    localparam [16:0] REV_TICKS  = 17'd100000;   // cell ticks of a revolution: 200 ms
    localparam [16:0] IDX_TICKS  = 17'd500;      // of them /INDEX is high: 1 ms
    localparam [12:0] TRK_BYTES  = 13'd6250;     // = REV_TICKS / 16
    localparam [6:0]  LAST_TRACK = 7'd83;        // TRD reaches 82
    localparam [3:0]  PULSE_CLK  = 4'd8;         // RDATA width of a channel 1
    localparam [7:0]  FILLER     = 8'h4E;        // what an unready track emits
    localparam [47:0] SYNC3      = {16'h4489, 16'h4489, 16'h4489};

    localparam [2:0] W_HUNT = 3'd0, W_MARK = 3'd1, W_ID = 3'd2, W_DATA = 3'd3;

    // ---------------- the code of the flux ----------------
    function [15:0] crc_byte(input [15:0] crc, input [7:0] b);
        integer i;
        begin
            crc_byte = crc ^ {b, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                crc_byte = crc_byte[15] ? {crc_byte[14:0], 1'b0} ^ 16'h1021 : {crc_byte[14:0], 1'b0};
        end
    endfunction

    // the CRC of the three sync bytes of a mark. A wire, not a zero-argument
    // function: Quartus refuses to call a function with no arguments (the value
    // is a constant, so a wire is what it is).
    wire [15:0] crc_a13 = crc_byte(crc_byte(crc_byte(16'hFFFF, 8'hA1), 8'hA1), 8'hA1);

    // the MFM encoder of the upstream bench: sync words are 4489h (the clock
    // of the mark is missing), otherwise a clock bit between two 0 bits
    function [15:0] chan_word(input [8:0] q, input prev);
        reg [7:0] b;
        begin
            b = q[7:0];
            if (q[8])
                chan_word = 16'h4489;
            else
                chan_word = {!prev && !b[7], b[7], !b[7] && !b[6], b[6], !b[6] && !b[5], b[5],
                             !b[5] && !b[4], b[4], !b[4] && !b[3], b[3], !b[3] && !b[2], b[2],
                             !b[2] && !b[1], b[1], !b[1] && !b[0], b[0]};
        end
    endfunction

    function [7:0] mfm_data(input [15:0] w);
        mfm_data = {w[14], w[12], w[10], w[8], w[6], w[4], w[2], w[0]};
    endfunction

    // cells in an interval, rounded: the chip's write cell is CELL_CLK clocks
    function [3:0] cells_of(input [16:0] v, input [7:0] c);
        reg [3:0] k;
        reg [16:0] t;
        begin
            cells_of = 4'd1;                     // pulses closer than a cell merge
            for (k = 4'd1; k <= 4'd8; k = k + 4'd1) begin
                t = {9'd0, c} * {13'd0, k};
                if (v >= t) cells_of = k;
            end
        end
    endfunction

    // ---------------- the head and the selection ----------------
    reg [6:0] trk_a = 7'd0;
    reg [6:0] trk_b = 7'd0;
    reg       sel_drv = 1'b0;          // the drive that is held across a deselect

    // `hrdy_fdc` gates both select lines with `motor`, and `motor` is the chip's
    // head-load output (`hrdy_fdc.v:133/140/170`), so the select lines are down
    // whenever the head is not being loaded - which is the state a seek steps in:
    // measured on the wire, a `SEEK` on a freshly selected drive emits its five
    // pulses with `FDC_DS == 00` (`no_select` counts them and fails if none did).
    // A step therefore belongs to the drive that is held, not to whoever is
    // selected this instant: requiring the select to be up would mean no head ever
    // moves, and a step that arrived before anything was selected goes nowhere
    // rather than to drive A.
    reg sel_seen = 1'b0;               // a drive has been selected since reset
    wire       now_drv   = swap ? fdc_drive[0] : fdc_drive[1];
    wire       selected  = |fdc_drive;
    wire       side      = fdc_side_n;                 // FDC_SIDE1: high is side 1
    wire [6:0] track     = sel_drv ? trk_b : trk_a;
    wire       stream_on = fdc_motor && sel_seen && !reset;

    wire       drv       = sel_drv;

    assign fdc_tr00 = (track == 7'd0);
    assign fdc_wprt = wprt[drv];
    wire [8:0] cur = {drv, side, track};   // what the store is asked for

    reg step_d = 1'b0;

    wire       step_up = fdc_step && !step_d;
    wire [6:0] step_nx = fdc_dir ? ((track == LAST_TRACK) ? track : track + 7'd1)
                                 : ((track == 7'd0) ? track : track - 7'd1);

    always @(posedge clk) begin
        step_d <= fdc_step;
        if (reset) begin
            sel_drv  <= 1'b0;
            sel_seen <= 1'b0;
            trk_a    <= 7'd0;
            trk_b    <= 7'd0;
        end
        else begin
            if (selected) begin
                sel_drv  <= now_drv;
                sel_seen <= 1'b1;
            end
            // the step counts for the held drive; before anything has been
            // selected there is no drive to step at all
            if (step_up && sel_seen) begin
                if (sel_drv) trk_b <= step_nx;
                else         trk_a <= step_nx;
            end
        end
    end

    // ---------------- the cell cadence and the revolution ----------------
    reg [16:0] acc  = 17'd0;
    reg        tick = 1'b0;
    reg [16:0] rev  = 17'd0;

    wire [16:0] rev_n    = (rev == REV_TICKS - 17'd1) ? 17'd0 : rev + 17'd1;
    wire        new_byte = (rev_n[3:0] == 4'd0);
    wire        new_rev  = (rev_n == 17'd0);
    wire [12:0] byte_now = rev[16:4];
    wire [13:0] ahead    = (byte_now == TRK_BYTES - 13'd1) ? 14'd0
                                                           : {1'b0, byte_now} + 14'd1;

    assign trk_addr_b = ahead[12:0];
    assign trk_addr_a = ahead[12:0];

    always @(posedge clk) begin
        if (reset) begin
            acc  <= 17'd0;
            tick <= 1'b0;
        end
        else begin
            if (acc + {1'b0, cell_num} >= {1'b0, cell_den}) begin
                acc  <= acc + {1'b0, cell_num} - {1'b0, cell_den};
                tick <= 1'b1;
            end
            else begin
                acc  <= acc + {1'b0, cell_num};
                tick <= 1'b0;
            end
        end
    end

    // ---------------- the state of the store side ----------------
    reg       stream_ready = 1'b0;   // the store holds the requested track
    reg [8:0] req_sent     = 9'd0;
    reg       wr_pend      = 1'b0;   // a written sector waits for its ack

    // the crossings: a toggle with a payload held across it (img_src's rule)
    reg ack_s1 = 1'b0, ack_s2 = 1'b0, ack_seen = 1'b0;
    reg wrack_s1 = 1'b0, wrack_s2 = 1'b0, wrack_seen = 1'b0;
    wire ack_ev   = (ack_s2 != ack_seen);
    wire wrack_ev = (wrack_s2 != wrack_seen);

    always @(posedge clk) begin
        ack_s1   <= trk_ack_tgl;
        ack_s2   <= ack_s1;
        wrack_s1 <= wr_ack_tgl;
        wrack_s2 <= wrack_s1;
    end

    // ---------------- the read stream ----------------
    reg        active = 1'b0;    // the buffer is being read (taken at index)
    reg [8:0]  q_cur  = {1'b0, FILLER};
    reg [15:0] chan   = 16'd0;
    reg [3:0]  pleft  = 4'd0;

    wire [8:0]  src_q  = active ? trk_q_b : {1'b0, FILLER};
    wire [15:0] chan_n = new_byte ? chan_word(src_q, q_cur[0]) : {chan[14:0], 1'b0};
    wire        pulse  = tick && stream_on && chan_n[15];

    always @(posedge clk) begin
        if (reset) begin
            rev       <= 17'd0;          // rev is reset and advanced here, once
            active    <= 1'b0;
            q_cur     <= {1'b0, FILLER};
            chan      <= 16'd0;
            fdc_index <= 1'b0;
        end
        else if (tick) begin
            rev       <= rev_n;
            fdc_index <= stream_on && (rev_n < IDX_TICKS);
            chan      <= chan_n;
            if (new_byte) q_cur  <= src_q;
            // A request going out ends the track that is being read: the head
            // has moved, and the store builds one buffer per drive and side in
            // place, so what it holds until it answers for the new track is not
            // that track's data. The drive reads 4Eh filler until the answer has
            // arrived and the next index comes round.
            if (cur != req_sent)  active <= 1'b0;
            else if (new_rev)     active <= stream_ready;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            pleft     <= 4'd0;
            fdc_rdata <= 1'b0;
        end
        else if (pulse) begin
            pleft     <= PULSE_CLK;
            fdc_rdata <= 1'b1;
        end
        else if (pleft > 4'd1) begin
            pleft     <= pleft - 4'd1;
            fdc_rdata <= 1'b1;
        end
        else begin
            pleft     <= 4'd0;
            fdc_rdata <= 1'b0;
        end
    end

    // ---------------- the track request ----------------
    // (cur is declared with the head: the read stream has to see it too)
    always @(posedge clk) begin
        if (reset) begin
            trk_req_tgl  <= 1'b0;
            trk_req      <= 9'd0;
            req_sent     <= 9'd0;
            stream_ready <= 1'b0;
            ack_seen     <= 1'b0;
            wrack_seen   <= 1'b0;
        end
        else begin
            ack_seen   <= ack_s2;
            wrack_seen <= wrack_s2;

            // an answer for the request that is out: only a matching echo
            // switches the stream, ready of an answer for another request is
            // nothing this drive may believe
            if (ack_ev && (trk_ack[8:0] == req_sent)) stream_ready <= trk_ack[9];

            if (cur != req_sent) begin
                req_sent     <= cur;
                trk_req      <= cur;
                trk_req_tgl  <= ~trk_req_tgl;
                stream_ready <= 1'b0;
            end
            // nothing ready: ask again at every index, so a remount the store
            // saw by itself reaches the drive without a head movement
            else if (tick && new_rev && !stream_ready && stream_on)
                trk_req_tgl <= ~trk_req_tgl;
        end
    end

    // ---------------- the ID fields and the written flux ----------------
    reg               wgate_d = 1'b0, wdata_d = 1'b0;
    wire              wg_rise  = fdc_wgate && !wgate_d;
    wire              wg_fall  = !fdc_wgate && wgate_d;
    wire              wd_rise  = fdc_wdata && !wdata_d;
    wire [7:0]        cell_clk = ds80 ? 8'd48 : 8'd56;
    wire [7:0]        half_clk = ds80 ? 8'd24 : 8'd28;
    reg  [15:0]       dtc      = 16'd0;   // clk since the last WD pulse
    reg               wfirst   = 1'b1;    // the first pulse of this WGATE
    reg  [3:0]        sh       = 4'd0;    // cells still to shift
    reg  [3:0]        ncell    = 4'd0;  // cells the last WD pulse accounts for
    reg  [3:0]        zcell    = 4'd0;  // pulseless cells since that pulse
    reg  [47:0]       wsr      = 48'd0;
    reg  [3:0]        wbits    = 4'd0;
    reg  [2:0]        wst      = W_HUNT;
    reg  [2:0]        widx     = 3'd0;
    reg  [15:0]       wcrc     = 16'hFFFF;
    reg  [7:0]        rcrc_hi  = 8'd0;
    reg  [10:0]       dneed    = 11'd0;
    reg  [10:0]       dgot     = 11'd0;
    reg               data_ok  = 1'b0;
    reg               drop     = 1'b0;    // this WGATE writes nothing
    reg  [9:0]        cap_addr = 10'd0;
    reg  [7:0]        cap_byte = 8'd0;
    reg               cap_stb  = 1'b0;

    // the ID the drive last read correctly: the target of the next WGATE
    reg [7:0] id_c = 8'd0, id_h = 8'd0, id_r = 8'd0, id_n = 8'd0;

    // the write target, taken as WGATE rises
    reg [7:0] tgt_c = 8'd0, tgt_h = 8'd0, tgt_r = 8'd0, tgt_n = 8'd0;
    reg       tgt_drv = 1'b0, tgt_side = 1'b0;
    reg [6:0] tgt_trk = 7'd0;

    // the ID field of the written flux, and of the bytes the drive emits
    reg [7:0] wid_c, wid_h, wid_r, wid_n, wrcrc_hi;
    reg [7:0] rid_c, rid_h, rid_r, rid_n, rrcrc_hi;
    reg [1:0] rsync = 2'd0;
    reg [2:0] rst   = 3'd0;          // 0 idle, 1..4 C,H,R,N, 5,6 the CRC
    reg [15:0] rcrc = 16'hFFFF;

    wire        pulse_load = wd_rise && fdc_wgate;
    wire [16:0] dtq        = {1'b0, dtc} + {9'd0, half_clk};

    // The flux after the last WD pulse of a field: no transition is a cell of
    // 0, and the last byte of a field needs those cells - its own last channel
    // cell is bit 0 of the CRC's low byte, a 0 for half of all CRCs, and with
    // nothing shifting after the last pulse that byte would never close and the
    // whole write would be lost. The pulseless cells are counted from the pulse
    // in the same rounded units as an interval, so a pulse that arrives in
    // time accounts for its own cells and nothing is counted twice.
    wire [3:0]  n_pul  = wfirst ? 4'd1 : cells_of(dtq, cell_clk);
    wire [3:0]  n_add  = (n_pul > zcell) ? (n_pul - zcell) : 4'd1;
    wire [16:0] zdue   = ({13'd0, ncell} + {13'd0, zcell} + 17'd1) * {10'd0, cell_clk};
    wire        free_zero = fdc_wgate && !pulse_load && (sh == 4'd0) && (zcell != 4'd15)
                            && (zdue <= dtq);
    wire        bit_in     = (!pulse_load && (sh != 4'd0)) || free_zero;
    wire [47:0] wsr_n      = bit_in ? {wsr[46:0], free_zero ? 1'b0 : (sh == 4'd1)} : wsr;
    wire [7:0]  wbyte      = mfm_data(wsr_n[15:0]);

    always @(posedge clk) begin
        wgate_d <= fdc_wgate;
        wdata_d <= fdc_wdata;
        cap_stb <= 1'b0;

        if (reset) begin
            wst   <= W_HUNT;
            sh    <= 4'd0;
            ncell <= 4'd0;
            zcell <= 4'd0;
            wfirst <= 1'b1;
            dtc   <= 16'd0;
            rsync <= 2'd0;
            rst   <= 3'd0;
            wr_tgl <= 1'b0;         // the store's toggle pair belongs to this
            wr_pend <= 1'b0;        // block alone: Quartus rejects two drivers
        end
        else begin
            // the store answered for the last written sector (cleared here, and
            // before the WGATE fall below, so a field completed in the same
            // clock keeps its pending flag)
            if (wrack_ev) wr_pend <= 1'b0;
            // ---- the clock of the write intervals ----
            if (wg_rise || (wd_rise && fdc_wgate)) dtc <= 16'd0;
            else if (dtc != 16'hFFFF) dtc <= dtc + 16'd1;

            // ---- WGATE: the target as it opens, the field as it closes ----
            if (wg_rise) begin
                wfirst  <= 1'b1;
                wst     <= W_HUNT;
                wbits   <= 4'd0;
                sh      <= 4'd0;
                ncell   <= 4'd0;
                zcell   <= 4'd0;
                data_ok <= 1'b0;
                drop    <= wr_pend || wprt[drv];
                tgt_drv  <= drv;
                tgt_side <= side;
                tgt_trk  <= track;
                tgt_c    <= id_c;
                tgt_h    <= id_h;
                tgt_r    <= id_r;
                tgt_n    <= id_n;
            end
            if (wg_fall) begin
                if (!drop && data_ok) begin
                    wr_tgl  <= ~wr_tgl;
                    wr_info <= {tgt_drv, tgt_side, tgt_trk, tgt_c, tgt_h, tgt_r, tgt_n[2:0]};
                    wr_pend <= 1'b1;
                end
                data_ok <= 1'b0;
                wst     <= W_HUNT;
            end

            // ---- a WD pulse: shift the cells it owes, the last of them a 1 ----
            if (pulse_load) begin
                sh     <= n_add;
                ncell  <= n_add;
                zcell  <= 4'd0;
                wfirst <= 1'b0;
            end
            else if (bit_in) begin
                wsr <= wsr_n;
                if (sh != 4'd0) sh    <= sh - 4'd1;
                else            zcell <= zcell + 4'd1;
            end

            // ---- the written flux, byte by byte ----
            if (bit_in) begin
                if (wst == W_HUNT) begin
                    if (wsr_n == SYNC3) begin
                        wst   <= W_MARK;
                        wbits <= 4'd0;
                        wcrc  <= crc_a13;
                    end
                end
                else if (wbits == 4'd15) begin
                    wbits <= 4'd0;
                    case (wst)
                        W_MARK: begin
                            if (wbyte == 8'hFE) begin
                                wcrc <= crc_byte(wcrc, wbyte);
                                wst  <= W_ID;
                                widx <= 3'd0;
                            end
                            else if ((wbyte == 8'hFB || wbyte == 8'hF8) && tgt_n <= 8'd3) begin
                                wcrc  <= crc_byte(wcrc, wbyte);
                                dneed <= 11'd128 << tgt_n;
                                dgot  <= 11'd0;
                                wst   <= W_DATA;
                            end
                            else wst <= W_HUNT;
                        end
                        W_ID: begin
                            case (widx)
                                3'd0: wid_c    <= wbyte;
                                3'd1: wid_h    <= wbyte;
                                3'd2: wid_r    <= wbyte;
                                3'd3: wid_n    <= wbyte;
                                3'd4: wrcrc_hi <= wbyte;
                                default: begin
                                    // a FORMAT wrote an ID: only a good CRC counts
                                    if (wcrc == {wrcrc_hi, wbyte} && wid_n <= 8'd3) begin
                                        id_c <= wid_c;
                                        id_h <= wid_h;
                                        id_r <= wid_r;
                                        id_n <= wid_n;
                                    end
                                    wst <= W_HUNT;
                                end
                            endcase
                            if (widx <= 3'd3) wcrc <= crc_byte(wcrc, wbyte);
                            widx <= widx + 3'd1;
                        end
                        W_DATA: begin
                            if (dgot < dneed) begin
                                if (!drop) begin
                                    cap_addr <= dgot[9:0];
                                    cap_byte <= wbyte;
                                    cap_stb  <= 1'b1;
                                    wcrc     <= crc_byte(wcrc, wbyte);
                                end
                                dgot <= dgot + 11'd1;
                            end
                            else if (dgot == dneed) begin
                                rcrc_hi <= wbyte;
                                dgot    <= dgot + 11'd1;
                            end
                            else if (dgot == dneed + 11'd1) begin
                                data_ok <= !drop && (wcrc == {rcrc_hi, wbyte});
                                dgot    <= dgot + 11'd1;
                                wst     <= W_HUNT;
                            end
                        end
                        default: wst <= W_HUNT;
                    endcase
                end
                else wbits <= wbits + 4'd1;
            end

            // ---- the ID fields of the bytes the drive emits ----
            if (tick && new_byte) begin
                if (src_q[8] && src_q[7:0] == 8'hA1) begin
                    rcrc  <= (rsync == 2'd0) ? crc_byte(16'hFFFF, 8'hA1) : crc_byte(rcrc, 8'hA1);
                    rsync <= (rsync != 2'd3) ? rsync + 2'd1 : rsync;
                    rst   <= 3'd0;
                end
                else if (rsync == 2'd3 && !src_q[8] && src_q[7:0] == 8'hFE) begin
                    rcrc  <= crc_byte(rcrc, 8'hFE);
                    rsync <= 2'd0;
                    rst   <= 3'd1;
                end
                else begin
                    rsync <= 2'd0;
                    case (rst)
                        3'd1: begin rid_c   <= src_q[7:0]; rcrc <= crc_byte(rcrc, src_q[7:0]); rst <= 3'd2; end
                        3'd2: begin rid_h   <= src_q[7:0]; rcrc <= crc_byte(rcrc, src_q[7:0]); rst <= 3'd3; end
                        3'd3: begin rid_r   <= src_q[7:0]; rcrc <= crc_byte(rcrc, src_q[7:0]); rst <= 3'd4; end
                        3'd4: begin rid_n   <= src_q[7:0]; rcrc <= crc_byte(rcrc, src_q[7:0]); rst <= 3'd5; end
                        3'd5: begin rrcrc_hi <= src_q[7:0]; rst <= 3'd6; end
                        3'd6: begin
                            // the last ID the chip could have read: the write target
                            if (rcrc == {rrcrc_hi, src_q[7:0]} && rid_n <= 8'd3) begin
                                id_c <= rid_c;
                                id_h <= rid_h;
                                id_r <= rid_r;
                                id_n <= rid_n;
                            end
                            rst <= 3'd0;
                        end
                        default: rst <= 3'd0;
                    endcase
                end
            end
        end
    end

    assign wr_addr = cap_addr;
    assign wr_data = cap_byte;
    assign wr_we   = cap_stb;

endmodule

`default_nettype wire
