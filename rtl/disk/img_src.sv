// img_src.sv - the two IDE images of hps_io's disk slots 2 and 3 as the
// sector engine of the machine. On clk the ATA core (hdf_ata) raises
// sdc_rd[4] or sdc_wr[4] for device 0, [5] for device 1, and gets the sector
// back as img_sdc's 512 strobe bytes, or hands one over to be written; on
// clk_sys the engine fetches the sector from (or pushes it to) the HPS
// through hps_io's disk block interface. Only one 512-byte buffer and one
// request at a time, as the upstream img_sdc (the file mounter's sector
// engine this replaces) had it: a request is a level on sdc_rd/sdc_wr until
// sdc_busy rises, the engine latches it and raises sdc_busy with sdc_slot,
// and sdc_done (with sdc_error when it failed) is a one-clock pulse at the
// end. The lowest set index is served first; an index that is not mounted
// (bits 0..3 have no image yet, and 4/5 only with a mount) ends with
// sdc_error and no bytes.
//
// Domains. clk_sys (50 MHz) owns the hps_io side and the buffer's HPS port;
// clk (CLK_BUS, 28.125 MHz) owns the sdc interface and the buffer's stream
// port. Every crossing is a toggle with a two-flop synchroniser on the
// receiving side, and multi-bit payloads are registered by the sender before
// its toggle moves and sampled by the receiver after the synchronised toggle
// changes: the mount {mounted[1:0], size[63:0]} clk_sys -> clk, the request
// {slot, wr, sector[31:0]} clk -> clk_sys, and the completion (a bare toggle:
// the engine has one request in flight, so no payload is needed).
//
// Reads. The clk side crosses the request, then streams the buffer as 512
// sdc_byte_in_strobe pulses with sdc_byte_addr counting 0..511 (one pulse per
// two clk clocks, the address and data held with it); the bytes come out of
// the buffer's clk port, registered. The clk_sys side raises sd_rd on the
// slot's bit with sd_lba, holds it until sd_ack rises, stores each byte on
// sd_buff_wr while sd_ack is high, drops sd_rd as soon as it sees sd_ack, and
// crosses the completion when sd_ack falls. Bytes past the end of the file
// arrive as 0 from hps_io, so a short image still fills a sector.
//
// Writes. The clk side first copies the 512 bytes of sdc_byte_out_data into
// the buffer, addressing each byte and sampling it three clocks later (as
// hps_io's img_sdc did; hdf_ata registers its word and the byte select, so
// its data is valid after two). Then the clk_sys side raises sd_wr and
// hps_io reads the bytes of the buffer's clk_sys port, registered, with
// sd_buff_addr; the write is complete when sd_ack falls.
//
// Mounts. Each img_mounted burst crosses with the new mounted bits and
// img_size (one size for both slots, as the main module has one img_size
// input), taken when the burst ends so the size is complete. The machine
// side needs a strobe, not a level: upstream img_sdc passed the MCU's
// img_mounted pulse straight through to hdf_ata, which re-takes a held bit
// as a fresh mount every clock (geo_ok is cleared and the drive answers BSY
// forever). So sdc_img_mounted is a strobe of 8 clk carrying the event bits
// (bit 4 = disk 2/device 0, bit 5 = disk 3/device 1) with sdc_img_size, and 0
// otherwise; a single-clock pulse was not observed by the drive on the board
// (builds 61-64) while a level was (build 55). A mount never disturbs a transfer in
// flight: the sector already fetched is streamed and the sector already
// copied is pushed, and the new image is what the next request reads or
// writes. An eject (img_size = 0) takes effect the same way, so a following
// request for that slot ends with sdc_error. A request that is in flight
// when its image is replaced still ends; it does not hang.
`default_nettype none

module img_src (
    // hps_io side (clk_sys): slot a = disk 2 = IDE device 0,
    // slot b = disk 3 = IDE device 1
    input  wire        clk_sys,
    input  wire        reset_sys,
    input  wire  [1:0] img_mounted,     // {b, a}, a pulse per mount event
    input  wire [63:0] img_size,        // bytes, one size for both slots
    output reg  [31:0] lba_a,
    output reg         rd_a,
    output reg         wr_a,
    input  wire        ack_a,
    output reg  [31:0] lba_b,
    output reg         rd_b,
    output reg         wr_b,
    input  wire        ack_b,
    input  wire  [8:0] sd_buff_addr,
    input  wire  [7:0] sd_buff_dout,
    output wire  [7:0] sd_buff_din_a,
    output wire  [7:0] sd_buff_din_b,
    input  wire        sd_buff_wr,
    // machine side (clk = CLK_BUS): img_sdc's interface, indices 4 and 5
    input  wire        clk,
    input  wire        reset,
    input  wire  [7:0] sdc_rd,
    input  wire  [7:0] sdc_wr,
    input  wire [31:0] sdc_sector,
    output reg         sdc_busy,
    output reg         sdc_done,
    output reg         sdc_error,
    output wire  [2:0] sdc_slot,
    output reg         sdc_byte_in_strobe,
    output reg   [8:0] sdc_byte_addr,
    output reg   [7:0] sdc_byte_in_data,
    input  wire  [7:0] sdc_byte_out_data,
    output wire  [7:0] sdc_img_mounted,   // one clk: {2'b00, b, a, 4'b0000}
    output wire [63:0] sdc_img_size
);

    // payload layouts
    //   mount {events[1:0], mounted[1:0], size[63:0]}
    //   request {slot, wr, sector[31:0]} = [33:0], slot the top bit
    localparam RQ_SLOT = 33, RQ_WR = 32;

    // ---------------- the 512-byte dual-clock buffer ----------------
    // One M10K block with two independent clocked ports, the way the card's
    // own sector buffer is built (sys/sd_card.sv): port A on clk_sys is
    // hps_io's byte port - its address (sd_buff_addr) and its output are
    // unregistered, so sd_buff_din follows the address, and a fetched
    // sector is written through it; port B on clk is the stream's - the
    // address is registered on CLOCK1 (q_b is the word of the previous
    // clock's address, which is what the strobe states sample), and a
    // sector being pushed is written through it. Quartus cannot infer this
    // shape from an array (two clocks, read and write on both ports:
    // "Cannot synthesize dual-port RAM logic"), so it is an instance.
    wire [8:0] b_addr = b_we ? b_wa : wpos;
    wire [7:0] q_sys, q_bus;

    altsyncram u_buf (
        .clock0    (clk_sys),
        .clock1    (clk),

        .address_a (sd_buff_addr),
        .data_a    (sd_buff_dout),
        .wren_a    (sd_buff_wr && h_state == H_DATA),
        .q_a       (q_sys),

        .address_b (b_addr),
        .data_b    (b_wd),
        .wren_b    (b_we),
        .q_b       (q_bus),

        .aclr0(1'b0),
        .aclr1(1'b0),
        .addressstall_a(1'b0),
        .addressstall_b(1'b0),
        .byteena_a(1'b1),
        .byteena_b(1'b1),
        .clocken0(1'b1),
        .clocken1(1'b1),
        .clocken2(1'b1),
        .clocken3(1'b1),
        .eccstatus(),
        .rden_a(1'b1),
        .rden_b(1'b1)
    );
    defparam
        u_buf.numwords_a = 512,
        u_buf.widthad_a  = 9,
        u_buf.width_a    = 8,
        u_buf.numwords_b = 512,
        u_buf.widthad_b  = 9,
        u_buf.width_b    = 8,
        u_buf.address_reg_b = "CLOCK1",
        u_buf.clock_enable_input_a = "BYPASS",
        u_buf.clock_enable_input_b = "BYPASS",
        u_buf.clock_enable_output_a = "BYPASS",
        u_buf.clock_enable_output_b = "BYPASS",
        u_buf.indata_reg_b = "CLOCK1",
        u_buf.intended_device_family = "Cyclone V",
        u_buf.lpm_type = "altsyncram",
        u_buf.operation_mode = "BIDIR_DUAL_PORT",
        u_buf.outdata_aclr_a = "NONE",
        u_buf.outdata_aclr_b = "NONE",
        u_buf.outdata_reg_a = "UNREGISTERED",
        u_buf.outdata_reg_b = "UNREGISTERED",
        u_buf.power_up_uninitialized = "FALSE",
        u_buf.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        u_buf.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        u_buf.width_byteena_a = 1,
        u_buf.width_byteena_b = 1,
        u_buf.wrcontrol_wraddress_reg_b = "CLOCK1";

    reg [8:0] b_wa = 9'd0;
    reg [7:0] b_wd = 8'd0;
    reg       b_we = 1'b0;
    reg [8:0] wpos = 9'd0;

    wire sd_ack = ack_a | ack_b;

    // ================= clk_sys: the hps_io side =================
    localparam [1:0] H_IDLE = 2'd0, H_WAIT = 2'd1, H_DATA = 2'd2, H_END = 2'd3;

    reg [1:0]  h_state = H_IDLE;
    reg        h_wr = 1'b0;

    // request crossing in
    reg        req_s1 = 1'b0, req_s2 = 1'b0, req_seen = 1'b0;
    reg [33:0] rq_payload = 34'd0;
    reg        pending_req = 1'b0;

    // completion crossing out
    reg        ack_tgl = 1'b0;

    // Mount crossing out: {event bits, mounted level, size}.
    //
    // hps_io raises img_mounted on Main's `0x1c` command and clears it when
    // the next command starts, while the `0x1d` size words follow the mount
    // command: a size sampled on the pulse is the previous one - 0 at the
    // first mount - so the image reads as an eject and the drive never
    // examines it (board, builds 61-66). The event is therefore latched and
    // crossed once img_size has stopped changing for 20 us; if the size never
    // changes in that event's short life (an eject to 0, or a mount whose
    // size is already right) it crosses after 82 us with the value it has.
    localparam [11:0] MNT_SETTLE = 12'd1023;  // 1024 clk_sys, 20 us quiet
    localparam [12:0] MNT_WAIT   = 13'd4095;  // 4096 clk_sys, 82 us since the event
    reg  [1:0] mounted_sys = 2'b00;
    reg  [1:0] old_mounted = 2'b00;
    reg  [1:0] ev_pend = 2'b00;
    reg [63:0] size_see = 64'd0;
    reg        size_chg = 1'b0;         // img_size moved since the event
    reg [11:0] settle = 12'd0;
    reg [12:0] ev_age = 13'd0;
    reg [67:0] mount_payload = 68'd0;
    reg        mount_tgl = 1'b0;

    wire [1:0] mount_ev = img_mounted & ~old_mounted;

    always @(posedge clk_sys) begin
        // ---- mount: one {mounted, size} payload per burst ----
        old_mounted <= img_mounted;
        if (|mount_ev) begin
            ev_pend  <= ev_pend | mount_ev;
            size_chg <= 1'b0;
            settle   <= 12'd0;
            ev_age   <= 13'd0;
        end

        if (ev_pend != 2'b00) begin
            if (img_size != size_see) begin
                size_see <= img_size;      // still being written
                settle   <= 12'd0;
                size_chg <= 1'b1;
            end
            else begin
                if (settle != MNT_SETTLE) settle <= settle + 1'd1;
                if (ev_age != MNT_WAIT)   ev_age <= ev_age + 1'd1;
                if ((size_chg && settle == MNT_SETTLE - 1'd1) || ev_age == MNT_WAIT) begin
                    mounted_sys   <= {ev_pend[1] ? (img_size != 64'd0) : mounted_sys[1],
                                      ev_pend[0] ? (img_size != 64'd0) : mounted_sys[0]};
                    mount_payload <= {ev_pend,
                                      ev_pend[1] ? (img_size != 64'd0) : mounted_sys[1],
                                      ev_pend[0] ? (img_size != 64'd0) : mounted_sys[0],
                                      img_size};
                    mount_tgl     <= ~mount_tgl;
                    ev_pend       <= 2'b00;
                    size_chg      <= 1'b0;
                    settle        <= 12'd0;
                    ev_age        <= 13'd0;
                end
            end
        end
        else begin
            size_see <= img_size;
            settle   <= 12'd0;
            ev_age   <= 13'd0;
        end

        // ---- request crossing in ----
        req_s1 <= req_tgl;
        req_s2 <= req_s1;
        if (req_s2 != req_seen) begin
            req_seen    <= req_s2;
            rq_payload  <= req_payload;
            pending_req <= 1'b1;
        end

        if (reset_sys) begin
            h_state <= H_IDLE;
            pending_req <= 1'b0;
            rd_a <= 1'b0; rd_b <= 1'b0;
            wr_a <= 1'b0; wr_b <= 1'b0;
        end else
        // ---- the one-at-a-time hps_io FSM ----
        case (h_state)
            H_IDLE: if (pending_req) begin
                pending_req <= 1'b0;
                h_wr <= rq_payload[RQ_WR];
                if (rq_payload[RQ_SLOT]) begin
                    lba_b <= rq_payload[31:0];
                    if (rq_payload[RQ_WR]) wr_b <= 1'b1;
                    else                   rd_b <= 1'b1;
                end else begin
                    lba_a <= rq_payload[31:0];
                    if (rq_payload[RQ_WR]) wr_a <= 1'b1;
                    else                   rd_a <= 1'b1;
                end
                h_state <= H_WAIT;
            end
            H_WAIT: if (sd_ack) begin
                rd_a <= 1'b0; rd_b <= 1'b0;
                wr_a <= 1'b0; wr_b <= 1'b0;
                h_state <= h_wr ? H_END : H_DATA;
            end
            H_DATA: if (!sd_ack)
                h_state <= H_END;
            H_END: if (!sd_ack) begin
                ack_tgl <= ~ack_tgl;
                h_state <= H_IDLE;
            end
            default: h_state <= H_IDLE;
        endcase
    end

    assign sd_buff_din_a = q_sys;
    assign sd_buff_din_b = q_sys;

    // ================= clk: the sdc interface and the stream =================
    localparam [3:0] S_IDLE = 4'd0,
                     S_REQ  = 4'd1,   // cross the request
                     S_WAIT = 4'd2,   // the request is with the HPS
                     S_OUTA = 4'd3,   // read: buffer address
                     S_OUTD = 4'd4,   // read: the strobe
                     S_INA  = 4'd5,   // write: the requester's byte address
                     S_INW  = 4'd6,   // write: sample it into the buffer
                     S_WPOST= 4'd7,   // write: let the last buffer write settle
                     S_DONE = 4'd8,
                     S_ERR  = 4'd9;

    reg [3:0]  s_state = S_IDLE;
    reg [2:0]  slot = 4'd0;
    reg        rq_slot = 1'b0, rq_wr = 1'b0;
    reg [31:0] rq_sector = 32'd0;
    reg  [1:0] wlat = 2'd0;

    // request crossing out
    reg [33:0] req_payload = 34'd0;
    reg        req_tgl = 1'b0;

    // completion crossing in
    reg        ack_s1 = 1'b0, ack_s2 = 1'b0, ack_seen = 1'b0;

    // mount crossing in
    reg        mount_s1 = 1'b0, mount_s2 = 1'b0, mount_seen = 1'b0;
    reg  [1:0] mounted_bus = 2'b00;
    reg  [1:0] ev_bus = 2'b00;          // a mount event waiting for its strobe
    reg  [1:0] mnt_q = 2'b00;           // the strobe, mnt_cnt clk wide
    reg  [2:0] mnt_cnt = 3'd0;
    reg [63:0] size_bus = 64'd0;

    wire [7:0] rq = sdc_rd | sdc_wr;
    wire [2:0] rq_idx = rq[0] ? 3'd0 : rq[1] ? 3'd1 : rq[2] ? 3'd2 : rq[3] ? 3'd3 :
                        rq[4] ? 3'd4 : rq[5] ? 3'd5 : rq[6] ? 3'd6 : 3'd7;
    wire       rq_is_wr = sdc_wr[rq_idx];
    wire       rq_mounted = (rq_idx == 4'd4) ? mounted_bus[0] :
                            (rq_idx == 4'd5) ? mounted_bus[1] : 1'b0;

    assign sdc_slot = slot;
    assign sdc_img_mounted = {2'b00, mnt_q[1], mnt_q[0], 4'b0000};
    assign sdc_img_size = size_bus;

    always @(posedge clk) begin
        sdc_done <= 1'b0;
        sdc_byte_in_strobe <= 1'b0;
        b_we <= 1'b0;

        // ---- crossings ----
        // hdf_ata takes img_mounted as a strobe, as upstream img_sdc passed the
        // MCU's pulse through: it re-reads the size and restarts the geometry
        // examination on every clock the bit is up. One clk, after the size it
        // carries is stable; the HPS's own one-clk_sys img_mounted is crossed
        // with the toggle below, never sampled directly, so nothing shorter
        // than a clk can be lost.
        // The strobe is held 8 clk: hdf_ata examines the image once per clock
        // the bit is up, which is harmless, but a single-clock pulse was not
        // observed by the drive on the board (builds 61-64) while a level was
        // (build 55), and a wider strobe removes that uncertainty.
        if (ev_bus != 2'b00) begin
            mnt_q   <= ev_bus;
            ev_bus  <= 2'b00;
            mnt_cnt <= 3'd7;
        end
        else if (mnt_cnt != 3'd0) begin
            mnt_cnt <= mnt_cnt - 1'd1;
        end
        else begin
            mnt_q <= 2'b00;
        end

        mount_s1 <= mount_tgl;
        mount_s2 <= mount_s1;
        if (mount_s2 != mount_seen) begin
            mount_seen  <= mount_s2;
            mounted_bus <= mount_payload[64 +: 2];
            size_bus    <= mount_payload[63:0];
            // events accumulate: two mounts closer together than the
            // crossing's latency must both reach the machine (the size is one
            // register, so they share the last one - Main's commands are
            // microseconds apart, far more than this window)
            ev_bus      <= ev_bus | mount_payload[66 +: 2];
        end
        ack_s1 <= ack_tgl;
        ack_s2 <= ack_s1;

        if (reset) begin
            s_state <= S_IDLE;
            sdc_busy <= 1'b0;
            sdc_error <= 1'b0;
        end else
        case (s_state)
            S_IDLE: if (rq != 8'd0) begin
                slot      <= rq_idx;
                rq_slot   <= (rq_idx == 4'd5);
                rq_wr     <= rq_is_wr;
                rq_sector <= sdc_sector;
                wpos      <= 9'd0;
                sdc_busy  <= 1'b1;
                if (!rq_mounted)          s_state <= S_ERR;
                else if (rq_is_wr)        s_state <= S_INA;
                else                      s_state <= S_REQ;
            end
            S_REQ: begin
                req_payload <= {rq_slot, rq_wr, rq_sector};
                req_tgl     <= ~req_tgl;
                s_state     <= S_WAIT;
            end
            S_WAIT: if (ack_s2 != ack_seen) begin
                ack_seen <= ack_s2;
                s_state  <= rq_wr ? S_DONE : S_OUTA;
            end
            S_OUTA: s_state <= S_OUTD;
            S_OUTD: begin
                sdc_byte_addr     <= wpos;
                sdc_byte_in_data  <= q_bus;
                sdc_byte_in_strobe <= 1'b1;
                if (wpos == 9'd511) begin
                    wpos    <= 9'd0;
                    s_state <= S_DONE;
                end else begin
                    wpos    <= wpos + 9'd1;
                    s_state <= S_OUTA;
                end
            end
            S_INA: begin
                sdc_byte_addr <= wpos;
                wlat          <= 2'd2;      // data valid three clocks after the address
                s_state       <= S_INW;
            end
            S_INW: if (wlat != 2'd0)
                wlat <= wlat - 2'd1;
            else begin
                b_we <= 1'b1;
                b_wa <= wpos;
                b_wd <= sdc_byte_out_data;
                if (wpos == 9'd511) begin
                    wpos    <= 9'd0;
                    s_state <= S_WPOST;
                end else begin
                    wpos    <= wpos + 9'd1;
                    s_state <= S_INA;
                end
            end
            S_WPOST: s_state <= S_REQ;
            S_DONE: begin
                sdc_busy  <= 1'b0;
                sdc_done  <= 1'b1;
                sdc_error <= 1'b0;
                s_state   <= S_IDLE;
            end
            S_ERR: begin
                sdc_busy  <= 1'b0;
                sdc_done  <= 1'b1;
                sdc_error <= 1'b1;
                s_state   <= S_IDLE;
            end
            default: s_state <= S_IDLE;
        endcase
    end

    // No reset port on the hps side at power-up in the top: these are the
    // power-up values of the outputs (Quartus initialises registers with
    // them, as tape_src does).
    initial begin
        lba_a = 32'd0; rd_a = 1'b0; wr_a = 1'b0;
        lba_b = 32'd0; rd_b = 1'b0; wr_b = 1'b0;
        sdc_busy = 1'b0; sdc_done = 1'b0; sdc_error = 1'b0;
        sdc_byte_in_strobe = 1'b0;
        sdc_byte_addr = 9'd0;
        sdc_byte_in_data = 8'd0;
    end

endmodule

`default_nettype wire