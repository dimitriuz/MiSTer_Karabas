// tape_src.sv - the tape file image from the SD card (hps_io disk slot 0),
// read a 512-byte sector at a time, cached in two sectors and served through
// tape.sv's (rtl/tape/tape.sv) memory port. The file is never loaded into
// memory.
//
// Domains. clk_sys (50 MHz) owns the hps_io side and the cache BRAM; clk
// (CLK_BUS, 28.125 MHz) owns the slot tags, the valid bits and the requests.
// Every clk_sys <-> clk crossing is a toggle with a two-flop synchroniser on
// the receiving side. Multi-bit payloads are registered by the sender before
// its toggle moves and sampled by the receiver after the synchronised toggle
// changes: the mount payload {valid, mode, size} on clk_sys -> clk, and the
// fetch request/ack payload {gen, slot, lba} clk -> clk_sys -> clk. No other
// signal crosses.
//
// Mount. On a rising img_mounted, clk_sys sends the mount toggle with
// {valid=0}; clk drops tape_ready and clears both valid bits. tape_ready
// stays low for at least 4 clk clocks, so tape.sv's rising-edge detection
// sees every new tape. With img_size != 0, clk_sys reads sector 0 into slot
// 0 and sniffs the bytes as they arrive on sd_buff_dout: "ZXTape!" at bytes
// 0..6 is TZX (mode 2), "Compressed Square Wave" at 0..21 is CSW (mode 1),
// anything else is TAP (mode 0). It then sends the mount toggle again with
// {valid=1, mode, size}, where size = min(img_size, 2^25-1); clk sets
// tape_mode/tape_size, marks slot 0 valid with tag 0 (it holds sector 0 from
// the sniff) and raises tape_ready. An eject (img_size = 0) sends only the
// {valid=0} toggle. A mount during the sniff makes the sniff result stale
// and the sniff runs again for the new image.
//
// Cache. One 1 KB dual-clock BRAM, reg [7:0] cache [0:1023], written on
// clk_sys at {slot, sd_buff_addr} and read on clk with a registered read
// (Quartus infers a dual-clock M10K). Two slots, each with a 16-bit sector
// tag and a valid bit in the clk domain. A fetch is requested by a toggle
// carrying {gen, slot, lba} from clk to clk_sys and acknowledged by a toggle
// back with the same payload; gen is a 2-bit mount generation counter, so a
// fetch that was in flight when a mount arrived is ignored by clk. The slot
// being fetched is invalid from the request until the ack, so a read of its
// old tag misses and waits for the fetch instead of taking a mix of the old
// and new sector. clk_sys
// serialises the hps_io accesses: it raises sd_rd (with sd_lba) and holds it
// until sd_ack rises, writes each byte into the slot while sd_ack is high,
// and drops sd_rd as soon as it sees sd_ack; the ack toggle goes out when
// sd_ack falls. Queued requests are served after a sniff; a request whose
// generation does not match the mount counter is stale and is dropped, so it
// can never overwrite the freshly sniffed sector 0. The clk side keeps at
// most one request in flight (fetch_inflight).
//
// Serving. The rd_en handshake of tape.sv alternates 0 -> 1: with rd_en = 1
// and no rd it returns to 0; a hit (addr[24:9] equals a valid slot's tag)
// loads din from the BRAM and drops rd_en; a miss requests that sector into
// the slot not holding the current one and keeps rd_en = 1 until the fetch
// ack makes it a hit. The registered BRAM read is tagged with the address
// and slot it was read for (q_ok), so a slot that became valid in this clock
// is served one clock later and never with the other slot's data. When a
// read hits slot s for sector L, sector L+1 is prefetched into the other
// slot if it starts inside the file, is not already in the other slot, and
// no fetch is in flight. No sector past tape_size is ever fetched. rd_en
// stays 0 while tape_ready is 0.
`default_nettype none

module tape_src (
    // hps_io side (clk_sys, 50 MHz), disk slot 0, 512-byte sectors
    input  wire        clk_sys,
    input  wire        img_mounted,     // hps_io img_mounted[0] (pulse)
    input  wire [63:0] img_size,
    output reg  [31:0] sd_lba,
    output reg         sd_rd,
    input  wire        sd_ack,
    input  wire  [8:0] sd_buff_addr,
    input  wire  [7:0] sd_buff_dout,
    input  wire        sd_buff_wr,
    // tape side (clk = clk_bus)
    input  wire        clk,
    output reg         tape_ready,      // a file is mounted and sniffed
    output reg   [1:0] tape_mode,       // 0 TAP, 1 CSW, 2 TZX
    output reg  [24:0] tape_size,       // min(img_size, 2^25 - 1)
    input  wire        rd,              // tape.sv rd
    input  wire [24:0] addr,            // tape.sv addr
    output wire  [7:0] din,             // tape.sv din
    output wire        rd_en,           // tape.sv rd_en
    input  wire        seek_prev,       // OSD Tape previous block
    input  wire        seek_next,       // OSD Tape next block
    output wire        blk_seek,        // converter jumped: reset the parse
    input  wire        stock_tzx        // 1: a TZX goes to tape.sv's own engine, 0: through tape_conv (sampled at mount)
);

    localparam [1:0] MODE_TAP = 2'd0, MODE_CSW = 2'd1, MODE_TZX = 2'd2;

    // The source file format; TAP/TZX are streamed through tape_conv as CSW.
    reg  [1:0]  src_mode = MODE_CSW;
    reg  [24:0] src_size = 25'd0;
    // A TZX mounted with stock_tzx = 1 skips the converter and plays through
    // tape.sv's own TZX engine (all block types). Latched at the mount.
    reg         use_stock = 1'b0;
    wire        conv = (src_mode != MODE_CSW) && !use_stock;

    // payload layouts
    //   mount {valid, mode[1:0], size[24:0]}
    //   fetch {gen[1:0], slot, lba[15:0]}
    localparam MOUNT_VALID = 27, MOUNT_MODE = 25, MOUNT_SIZE = 0;
    localparam REQ_GEN = 17, REQ_SLOT = 16, REQ_LBA = 0;

    // ---------------- the dual-clock cache BRAM ----------------
    reg [7:0] cache [0:1023];

    // ---------------- the domain crossings ----------------
    reg [27:0] mount_payload = 28'd0;   // clk_sys -> clk
    reg        mount_tgl = 1'b0;
    reg        req_tgl = 1'b0;          // clk -> clk_sys
    reg [18:0] req_payload = 19'd0;
    reg        ack_tgl = 1'b0;          // clk_sys -> clk
    reg [18:0] ack_payload = 19'd0;

    // ================= clk_sys: the hps_io side =================
    localparam [55:0]  TZX_MAGIC = "ZXTape!";
    localparam [175:0] CSW_MAGIC = "Compressed Square Wave";

    localparam [1:0] S_IDLE = 2'd0, S_WAIT = 2'd1, S_DATA = 2'd2, S_END = 2'd3;

    reg [1:0]  state = S_IDLE;
    reg        old_mounted = 1'b0;
    reg [1:0]  mount_cnt = 2'd0;        // increments per img_mounted
    reg [1:0]  sniff_cnt = 2'd0;        // mount_cnt the sniff belongs to
    reg        sniff_pending = 1'b0;
    reg        sniff_active = 1'b0;
    reg        tzx_ok = 1'b0, csw_ok = 1'b0;
    reg        buf_slot = 1'b0;         // slot the current fetch writes
    reg [18:0] cur_req = 19'd0;         // request being served, echoed in ack

    // request crossing from clk
    reg        req_s1 = 1'b0, req_s2 = 1'b0, req_seen = 1'b0;
    reg [18:0] rq_payload = 19'd0;
    reg        pending_req = 1'b0;

    // sniff comparators: byte i of each signature
    wire [2:0] tzx_i = (sd_buff_addr < 9'd7)  ? sd_buff_addr[2:0] : 3'd0;
    wire [4:0] csw_i = (sd_buff_addr < 9'd22) ? sd_buff_addr[4:0] : 5'd0;
    wire [7:0] tzx_exp = TZX_MAGIC[8 * (3'd6 - tzx_i) +: 8];
    wire [7:0] csw_exp = CSW_MAGIC[8 * (5'd21 - csw_i) +: 8];

    wire [24:0] size25 = (img_size[63:25] != 0) ? 25'h1FFFFFF : img_size[24:0];
    wire  [1:0] sniff_mode = tzx_ok ? MODE_TZX : (csw_ok ? MODE_CSW : MODE_TAP);

    always @(posedge clk_sys) begin
        // ---- mount: one {valid=0} toggle per event, payload first ----
        old_mounted <= img_mounted;
        if (img_mounted && !old_mounted) begin
            mount_cnt     <= mount_cnt + 2'd1;
            mount_payload <= 28'd0;
            mount_tgl     <= ~mount_tgl;
            sniff_pending <= (img_size != 0);
        end

        // ---- request crossing in ----
        req_s1 <= req_tgl;
        req_s2 <= req_s1;
        if (req_s2 != req_seen) begin
            req_seen    <= req_s2;
            rq_payload  <= req_payload;
            pending_req <= 1'b1;
        end

        // ---- the bytes of the sector while sd_ack is high ----
        if (sd_buff_wr && state == S_DATA) begin
            cache[{buf_slot, sd_buff_addr}] <= sd_buff_dout;
            if (sniff_active) begin
                if (sd_buff_addr < 9'd7 && sd_buff_dout != tzx_exp)
                    tzx_ok <= 1'b0;
                if (sd_buff_addr < 9'd22 && sd_buff_dout != csw_exp)
                    csw_ok <= 1'b0;
            end
        end

        // ---- the one-at-a-time hps_io FSM ----
        case (state)
            S_IDLE: begin
                if (sniff_pending) begin
                    sniff_pending <= 1'b0;
                    sniff_active  <= 1'b1;
                    sniff_cnt     <= mount_cnt;
                    tzx_ok        <= 1'b1;
                    csw_ok        <= 1'b1;
                    buf_slot      <= 1'b0;
                    sd_lba        <= 32'd0;
                    sd_rd         <= 1'b1;
                    state         <= S_WAIT;
                end else if (pending_req) begin
                    pending_req <= 1'b0;
                    // a stale generation was superseded by a mount: drop it
                    if (rq_payload[REQ_GEN +: 2] == mount_cnt) begin
                        cur_req  <= rq_payload;
                        buf_slot <= rq_payload[REQ_SLOT];
                        sd_lba   <= {16'd0, rq_payload[REQ_LBA +: 16]};
                        sd_rd    <= 1'b1;
                        state    <= S_WAIT;
                    end
                end
            end
            S_WAIT: if (sd_ack) begin
                sd_rd <= 1'b0;
                state <= S_DATA;
            end
            S_DATA: if (!sd_ack) begin
                state <= S_END;
            end
            S_END: begin
                if (sniff_active) begin
                    if (sniff_cnt == mount_cnt) begin
                        mount_payload <= {1'b1, sniff_mode, size25};
                        mount_tgl     <= ~mount_tgl;
                    end
                    sniff_active <= 1'b0;
                end else begin
                    ack_payload <= cur_req;
                    ack_tgl     <= ~ack_tgl;
                end
                state <= S_IDLE;
            end
            default: state <= S_IDLE;
        endcase
    end

    // ================= clk: the cache tags and the tape port =================
    reg [15:0] tag0 = 16'd0, tag1 = 16'd0;
    reg        valid0 = 1'b0, valid1 = 1'b0;
    reg        cur_slot = 1'b0;         // slot of the last served sector
    reg  [1:0] gen = 2'd0;              // mount generation in a request
    reg        mount_s1 = 1'b0, mount_s2 = 1'b0, mount_seen = 1'b0;
    reg        ack_s1 = 1'b0, ack_s2 = 1'b0, ack_seen = 1'b0;
    reg        fetch_inflight = 1'b0;
    reg        pending_ready = 1'b0;
    reg  [2:0] ready_hold = 3'd0;

    // registered BRAM read, tagged so a fresh slot is never misread
    reg [7:0] qbuf = 8'd0;
    reg [8:0] q_lo = 9'd0;
    reg       q_slot = 1'b0;

    // converter input port
    wire [24:0] conv_in_addr;
    wire        conv_in_req;
    reg   [7:0] conv_data = 8'd0;
    reg         conv_valid = 1'b0;
    wire  [7:0] conv_din;
    wire        conv_rd_en;
    wire        conv_done;

    // the cache serves the player (CSW) or the converter's input reader
    reg  [7:0] c_din = 8'd0;
    reg        c_rd_en = 1'b0;
    reg        old_c_rd_en = 1'b0;
    wire [24:0] c_addr = conv ? conv_in_addr : addr;
    wire        c_rd = conv ? (conv_in_req & c_rd_en & ~conv_valid) : rd;
    wire [24:0] fetch_size = conv ? src_size : tape_size;

    assign din   = conv ? conv_din   : c_din;
    assign rd_en = conv ? conv_rd_en : c_rd_en;

    // converter input response: c_din is registered on the serve clock
    always @(posedge clk) begin
        old_c_rd_en <= c_rd_en;
        if (conv) begin
            if (conv_in_req && !c_rd_en && old_c_rd_en) conv_data <= qbuf;
            if (!conv_in_req) conv_valid <= 1'b0;
            else if (conv_in_req && !c_rd_en && old_c_rd_en) conv_valid <= 1'b1;
        end else begin
            conv_valid <= 1'b0;
        end
    end

    wire [15:0] sec = c_addr[24:9];
    wire        hit0 = valid0 && (tag0 == sec);
    wire        hit1 = valid1 && (tag1 == sec);
    wire        hit_any = hit0 | hit1;
    wire        hit_slot = hit0 ? 1'b0 : 1'b1;
    wire        rd_slot = hit_any ? hit_slot : cur_slot;
    wire        q_ok = (q_lo == c_addr[8:0]) && (q_slot == rd_slot);

    wire [16:0] sec_next = {1'b0, sec} + 17'd1;
    wire [25:0] next_off = {sec_next, 9'd0};
    wire        prefetch_in_file = (next_off < {1'b0, fetch_size});
    wire        other_valid = hit_slot ? valid0 : valid1;
    wire [15:0] other_tag = hit_slot ? tag0 : tag1;
    wire        prefetch_free = !(other_valid && other_tag == sec_next[15:0]);
    wire        prefetch_ok = prefetch_in_file && prefetch_free && !fetch_inflight;

    wire mount_now = (mount_s2 != mount_seen);
    wire fsm_en = tape_ready && !mount_now;

    always @(posedge clk) begin
        // registered cache read for the current address
        qbuf   <= cache[{rd_slot, c_addr[8:0]}];
        q_lo   <= c_addr[8:0];
        q_slot <= rd_slot;

        // CDC in
        mount_s1 <= mount_tgl;
        mount_s2 <= mount_s1;
        ack_s1   <= ack_tgl;
        ack_s2   <= ack_s1;

        // one ready-hold clock down per clk
        if (ready_hold != 0) ready_hold <= ready_hold - 3'd1;

        if (mount_now) begin
            mount_seen <= mount_s2;
            if (!mount_payload[MOUNT_VALID]) begin
                // {valid=0}: a new (or ejected) tape
                tape_ready    <= 1'b0;
                valid0        <= 1'b0;
                valid1        <= 1'b0;
                gen           <= gen + 2'd1;
                fetch_inflight <= 1'b0;
                pending_ready <= 1'b0;
                ready_hold    <= 3'd4;
            end else begin
                // {valid=1, mode, size}: the sniff is done. TAP/TZX go
                // through tape_conv, so the player always sees CSW; its
                // size is the converter's (unbounded) output.
                src_mode   <= mount_payload[MOUNT_MODE +: 2];
                src_size   <= mount_payload[MOUNT_SIZE +: 25];
                use_stock  <= stock_tzx && (mount_payload[MOUNT_MODE +: 2] != MODE_CSW);
                tape_mode  <= (stock_tzx && mount_payload[MOUNT_MODE +: 2] != MODE_CSW)
                              ? mount_payload[MOUNT_MODE +: 2] : MODE_CSW;
                tape_size  <= (stock_tzx || mount_payload[MOUNT_MODE +: 2] == MODE_CSW)
                              ? mount_payload[MOUNT_SIZE +: 25] : 25'h1FFFFFF;
                tag0       <= 16'd0;
                valid0     <= 1'b1;
                cur_slot   <= 1'b0;
                pending_ready <= 1'b1;
            end
        end else begin
            if (ack_s2 != ack_seen) begin
                ack_seen <= ack_s2;
                if (ack_payload[REQ_GEN +: 2] == gen) begin
                    if (ack_payload[REQ_SLOT]) begin
                        valid1 <= 1'b1;
                        tag1   <= ack_payload[REQ_LBA +: 16];
                    end else begin
                        valid0 <= 1'b1;
                        tag0   <= ack_payload[REQ_LBA +: 16];
                    end
                    fetch_inflight <= 1'b0;
                end
            end
            if (pending_ready && ready_hold == 0) begin
                tape_ready    <= 1'b1;
                pending_ready <= 1'b0;
            end
        end

        // cache read FSM: 0 -> 1 alternation, serving tape.sv (CSW) or
        // tape_conv's input reader (TAP/TZX)
        if (!fsm_en) begin
            c_rd_en <= 1'b0;
        end else if (!c_rd_en) begin
            c_rd_en <= 1'b1;
        end else if (!c_rd) begin
            c_rd_en <= 1'b0;
        end else if (hit_any) begin
            if (q_ok) begin
                c_din    <= qbuf;
                cur_slot <= hit_slot;
                c_rd_en  <= 1'b0;
                if (prefetch_ok) begin
                    req_payload    <= {gen, ~hit_slot, sec_next[15:0]};
                    req_tgl        <= ~req_tgl;
                    fetch_inflight <= 1'b1;
                    if (hit_slot) valid0 <= 1'b0;
                    else          valid1 <= 1'b0;
                end
            end
        end else if (!fetch_inflight) begin
            req_payload    <= {gen, ~cur_slot, sec};
            req_tgl        <= ~req_tgl;
            fetch_inflight <= 1'b1;
            if (cur_slot) valid0 <= 1'b0;
            else          valid1 <= 1'b0;
        end

        // the converter finished the last block; stop the player
        if (conv_done) tape_ready <= 1'b0;
    end

// No reset port: these are the power-up values of the outputs.
    initial begin
        sd_lba     = 32'd0;
        sd_rd      = 1'b0;
        tape_ready = 1'b0;
        tape_mode  = 2'd0;
        tape_size  = 25'd0;
    end

wire converter_active = conv & tape_ready;

tape_conv u_tape_conv (
    .clk(clk),
    .active(converter_active),
    .src_mode(src_mode),
    .in_size(src_size),
    .in_addr(conv_in_addr),
    .in_req(conv_in_req),
    .in_data(conv_data),
    .in_valid(conv_valid),
    .rd(rd),
    .din(conv_din),
    .rd_en(conv_rd_en),
    .done(conv_done),
    .prev(seek_prev),
    .next(seek_next),
    .blk_seek(blk_seek)
);

endmodule

`default_nettype wire