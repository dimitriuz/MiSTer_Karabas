// fdd_src.sv - the host path of the two VG93 floppy drives (stage 4c): the
// hps_io disk slots of the drives and their FDI downloads, in one clock
// domain (clk_sys, the hps_io one). It sits between hps_io and fdd_store:
//
//   mount    each img_mounted burst crosses with the size and the read-only
//            flag of the event's drives, taken once img_size has stopped
//            changing for 1024 clk (the img_src settle: hps_io raises
//            img_mounted on Main's `0x1c` and writes the `0x1d` size words
//            inside the same burst, so a size sampled on the pulse is the
//            previous one - 0 at the first mount - and the drive then looks
//            empty forever). The crossing is what the geometry is resolved
//            from and what arms a fill, so a mount always carries its own
//            size. wprt is the latched img_readonly, high also for a drive
//            with no image: an empty drive cannot be written.
//
//   geometry tracks_trd = size/8192, tracks_cpm = size/10240. Auto: TRD when
//            size % 8192 == 0 && tracks_trd <= 84, else CP/M when
//            size % 10240 == 0 && tracks_cpm <= 84, else no image (no config
//            ever reaches the store, so the drive stays empty). status[35:34]
//            forces TRD (1) or CP/M (2); a forced kind the size does not fit
//            is no image either. 655360 -> TRD-80, 819200 -> too many tracks
//            for TRD -> CP/M-80, 409600 -> TRD-50 (the ambiguous case the OSD
//            item fixes). Sides: 2 for both kinds; an FDI takes them from its
//            header. The division by 10240 is an exact divide-by-10 of the
//            size in 1024-byte blocks, so no image is ever accepted on a
//            rounded geometry.
//
//   fill     config, then the image sector by sector - sd_rd with the sector
//            number, the 512 bytes in through the hps byte port into the
//            fill buffer, then one store fill byte at a time - then ready.
//            The read here and the write in the drain wait for the slot to be
//            free (sd_ack low) before they raise sd_rd / sd_wr: hps_io answers
//            one request per transfer and does not see a request that goes up
//            while another one is in flight, so the rule is what keeps a block
//            from being acked and lost.
//            The sizes a geometry can produce are multiples of 512 (8192 and
//            10240 both are), so every sector is a whole one. A new mount of
//            the drive being filled drops the transfer (the 4b rule) and its
//            config clears the drive; the mount of the other drive waits,
//            because the store's byte port belongs to the drive its last
//            config named. A fill returns to the dispatcher between sectors,
//            so a mount or a drain never waits for more than 512 bytes.
//
//   drain    on the store's block presentation, copy the 512 bytes of its
//            drain buffer (its far side is clk_sys: present, wait, take) into
//            ours and hand them to hps_io with sd_wr, lba = block, then ack
//            the store. A read-only image is never written back (the block is
//            dropped and acked, so the store keeps running), and a block
//            whose drive was remounted since it was presented is dropped too:
//            those bytes belong to an image that is gone, and putting them at
//            the same LBA of the new file would corrupt it.
//
//   download ioctl_download with index 1 or 2 is drive A's / B's FDI file
//            (index 0 is boot.rom and stays with mcu_emu). ioctl_wait is
//            raised from the claim until the download is over and dropped
//            only in the byte-wait state with nothing pending - the mcu_emu
//            ownership rule - so the source holds its next byte while the
//            store's ack for the previous one is on its way, and no strobe is
//            ever lost. The 14-byte header is validated ("FDI", version 0,
//            cylinders 1..84 = the store's cap, sides 1..2, and an off_data
//            far enough past the header for one table group), then
//            config{FDI, cyl, sides} goes out and the track table is
//            transformed as it streams: the store's table block
//            ti = track*2+side gets its DataOffset in bytes 0..3 and its
//            sector count in byte 4 (the reserved u16 of the file's block
//            header is skipped), and each 7-byte sector record
//            C,H,R,N,flags,offset goes through unchanged. The data area from
//            off_data streams as image bytes addressed by their index in the
//            data area; the table's own DataOffsets are what the vendor tool
//            wrote for that layout, and the bench checks byte for byte that
//            what lands at an address is the file's byte at off_data + that
//            address. Bytes between the last declared block and off_data
//            (the FDI extension or comment area, whose length the header's
//            size_ext would give and which the core never reads) are skipped.
//            A bad header, a table whose 7-byte groups do not fit before
//            off_data, or a record whose data leaves the store's 2 MiB window
//            aborts the download with ioctl_wait low and no ready, so the
//            drive stays empty and the rest of the host's stream is ignored
//            rather than hung; a bad header is caught before the config, so
//            the image a drive already had survives it. ready goes out when
//            the download window closes with the data area streaming - the
//            file's length is not known before that - and a window that
//            closes earlier leaves the drive empty as well.
//
// The engine is one clock-domain state machine that runs one activity at a
// time: a mount event, a fill sector, a drain block, or a download. Every
// crossing to the store (gs_clk) is a toggle with a two-flop synchroniser:
// the fill word and its ack, the drain block and its ack. One driver per
// register: the reset synchroniser, the settle (mounts, geometry, wprt) and
// the engine own their registers alone.
`default_nettype none

module fdd_src (
    input  wire        clk_sys,
    input  wire        reset_sys,          // async in, synchronised here

    // the hps_io disk slots of the two drives (the top's indices 4 and 5)
    input  wire  [1:0] img_mounted,        // one clk_sys pulse per mount
    input  wire [63:0] img_size,           // bytes; valid for the event
    input  wire        img_readonly,       // idem
    output reg  [1:0]  sd_rd,
    output reg  [1:0]  sd_wr,
    output reg  [31:0] sd_lba,             // the sector of the one request
    input  wire  [1:0] sd_ack,
    input  wire  [8:0] sd_buff_addr,
    input  wire  [7:0] sd_buff_dout,
    output wire  [7:0] sd_buff_din,
    input  wire        sd_buff_wr,

    // the OSD: status[35:34] = 0 auto, 1 force TRD, 2 force CP/M
    input  wire [127:0] status,

    // the hps_io ioctl download: index 1 = drive A, 2 = drive B
    input  wire        ioctl_download,
    input  wire [15:0] ioctl_index,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,         // the stream is taken in file
    input  wire [7:0]  ioctl_dout,         // order: the address is not used
    output reg         ioctl_wait,

    // the drives' write-protect: a clk_sys level, the top synchronises it
    output reg  [1:0]  wprt,

    // fdd_store's fill port (gs_clk; the toggle crosses it)
    output reg         fill_tgl,
    output reg  [31:0] fill_word,
    input  wire        fill_ack_tgl,

    // fdd_store's drain port (its buffer's far side is clk_sys)
    output reg  [8:0]  drn_addr_b,
    input  wire  [7:0] drn_q_b,
    input  wire        drn_tgl,
    input  wire [11:0] drn_info,           // {drive, block[10:0]}
    output reg         drn_ack_tgl
);

    localparam [1:0] K_TRD = 2'd0, K_CPM = 2'd1, K_FDI = 2'd2;

    // ---------------- reset synchroniser ----------------
    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk_sys or posedge reset_sys) begin
        if (reset_sys) rst_sync <= 2'b11;
        else           rst_sync <= {rst_sync[0], 1'b0};
    end
    wire rst = rst_sync[1];

    // ================= the geometry of a size =================
    // An exact divide by 10 of the size in 1024-byte blocks: a CP/M drive is
    // k * 10240 bytes, so the remainder has to be zero and k <= 84.
    function [15:0] div10(input [10:0] n);         // {r[4:0], q[10:0]}
        integer i;
        reg [10:0] q;
        reg [4:0]  r;
        begin
            q = 11'd0;
            r = 5'd0;
            for (i = 10; i >= 0; i = i - 1) begin
                r = {r[3:0], n[i]};               // r < 10, so r[3:0] == r
                if (r >= 5'd10) begin
                    r    = r - 5'd10;
                    q[i] = 1'b1;
                end
            end
            div10 = {r, q};
        end
    endfunction

    wire [15:0] g_dm      = div10(img_size[20:10]);
    wire [10:0] g_q       = g_dm[10:0];
    wire [4:0]  g_r       = g_dm[15:11];
    wire        g_fits    = (img_size[63:21] == 43'd0);     // the 2 MiB window
    wire [6:0]  g_trd     = img_size[19:13];
    wire        g_ok_trd  = g_fits && (img_size[12:0] == 13'd0) &&
                            (g_trd != 7'd0) && (g_trd <= 7'd84);
    wire        g_ok_cpm  = g_fits && (img_size[9:0] == 10'd0) && (g_r == 5'd0) &&
                            (g_q != 11'd0) && (g_q <= 11'd84);
    wire [1:0]  g_sel     = status[35:34];
    wire [1:0]  g_kind    = (g_sel == 2'd2) ? K_CPM :
                            (g_sel == 2'd1) ? K_TRD :
                            (g_ok_cpm && !g_ok_trd) ? K_CPM : K_TRD;
    wire        g_ok      = (g_kind == K_CPM) ? g_ok_cpm : g_ok_trd;
    wire [6:0]  g_tracks  = (g_kind == K_CPM) ? g_q[6:0] : g_trd;
    wire [18:0] g_sectors = img_size[28:9];

    // ================= the mount settle (the img_src pattern) ============
    localparam [11:0] MNT_SETTLE = 12'd1023;    // 1024 clk_sys of quiet
    localparam [12:0] MNT_WAIT   = 13'd4095;    // or 4096 clk_sys of waiting

    reg  [1:0] old_mounted = 2'b00;
    reg  [1:0] ev_pend     = 2'b00;
    reg [63:0] size_see    = 64'd0;
    reg        size_chg    = 1'b0;
    reg [11:0] settle      = 12'd0;
    reg [12:0] ev_age      = 13'd0;
    reg [1:0]  chg_ev      = 2'b00;
    reg        chg_tgl     = 1'b0;

    reg        mnt_lvl    [0:1];
    reg        mnt_ro     [0:1];
    reg        mnt_valid  [0:1];
    reg [1:0]  mnt_kind   [0:1];
    reg [6:0]  mnt_tracks [0:1];
    reg        mnt_sides  [0:1];
    reg [11:0] mnt_sectors[0:1];

    wire [1:0] mount_ev = img_mounted & ~old_mounted;

    integer sv;

    always @(posedge clk_sys) begin
        if (rst) begin
            old_mounted <= 2'b00;
            ev_pend     <= 2'b00;
            size_see    <= 64'd0;
            size_chg    <= 1'b0;
            settle      <= 12'd0;
            ev_age      <= 13'd0;
            chg_ev      <= 2'b00;
            chg_tgl     <= 1'b0;
            wprt        <= 2'b11;
            for (sv = 0; sv <= 1; sv = sv + 1) begin
                mnt_lvl[sv]     <= 1'b0;
                mnt_ro[sv]      <= 1'b0;
                mnt_valid[sv]   <= 1'b0;
                mnt_kind[sv]    <= K_TRD;
                mnt_tracks[sv]  <= 7'd0;
                mnt_sides[sv]   <= 1'b0;
                mnt_sectors[sv] <= 12'd0;
            end
        end
        else begin
            old_mounted <= img_mounted;
            if (|mount_ev) begin
                ev_pend  <= ev_pend | mount_ev;
                size_chg <= 1'b0;
                settle   <= 12'd0;
                ev_age   <= 13'd0;
            end

            if (ev_pend != 2'b00) begin
                if (img_size != size_see) begin
                    size_see <= img_size;         // still being written
                    settle   <= 12'd0;
                    size_chg <= 1'b1;
                end
                else begin
                    if (settle != MNT_SETTLE) settle <= settle + 1'd1;
                    if (ev_age  != MNT_WAIT)  ev_age <= ev_age + 1'd1;
                    if ((size_chg && settle == MNT_SETTLE - 1'd1) ||
                        ev_age == MNT_WAIT) begin
                        for (sv = 0; sv <= 1; sv = sv + 1)
                            if (ev_pend[sv]) begin
                                mnt_lvl[sv]     <= (img_size != 64'd0);
                                mnt_ro[sv]      <= img_readonly;
                                mnt_valid[sv]   <= (img_size != 64'd0) && g_ok;
                                mnt_kind[sv]    <= g_kind;
                                mnt_tracks[sv]  <= g_tracks;
                                mnt_sides[sv]   <= 1'b1;
                                mnt_sectors[sv] <= g_sectors[11:0];
                                wprt[sv]        <= (img_size == 64'd0) |
                                                   img_readonly;
                            end
                        chg_ev   <= ev_pend;
                        chg_tgl  <= ~chg_tgl;
                        ev_pend  <= 2'b00;
                        size_chg <= 1'b0;
                        settle   <= 12'd0;
                        ev_age   <= 13'd0;
                    end
                end
            end
            else begin
                size_see <= img_size;
                settle   <= 12'd0;
                ev_age   <= 13'd0;
            end
        end
    end

    // ================= the buffers =================
    // hps_io's byte port is unregistered on both sides (it addresses a byte
    // and reads sd_buff_din a strobe later), so the hps side of both buffers
    // is the altsyncram port with the unregistered output, as img_src's
    // sector buffer has it; the engine's side of both is the port with the
    // registered address, where a read takes three clocks.
    wire       fb_we;                   // the gated strobe, assigned below
    reg [8:0]  fb_addr;
    reg        db_we;
    reg [8:0]  db_waddr;
    reg [7:0]  db_wd;
    wire [7:0] fb_q, db_q;

    altsyncram u_fb (
        .clock0(clk_sys), .clock1(clk_sys),
        .address_a(sd_buff_addr), .data_a(sd_buff_dout), .wren_a(fb_we), .q_a(),
        .address_b(fb_addr), .data_b(8'd0), .wren_b(1'b0), .q_b(fb_q),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .byteena_a(1'b1), .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
        .clocken2(1'b1), .clocken3(1'b1), .eccstatus(),
        .rden_a(1'b1), .rden_b(1'b1)
    );
    // the drain buffer: port A is hps_io's byte port (read only), port B the
    // engine's writes as the block is copied out of the store.
    altsyncram u_db (
        .clock0(clk_sys), .clock1(clk_sys),
        .address_a(sd_buff_addr), .data_a(8'd0), .wren_a(1'b0), .q_a(db_q),
        .address_b(db_waddr), .data_b(db_wd), .wren_b(db_we), .q_b(),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .byteena_a(1'b1), .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
        .clocken2(1'b1), .clocken3(1'b1), .eccstatus(),
        .rden_a(1'b1), .rden_b(1'b1)
    );
    defparam
        u_fb.numwords_a = 512, u_fb.widthad_a = 9, u_fb.width_a = 8,
        u_fb.numwords_b = 512, u_fb.widthad_b = 9, u_fb.width_b = 8,
        u_fb.address_reg_b = "CLOCK1",
        u_fb.clock_enable_input_a = "BYPASS",
        u_fb.clock_enable_input_b = "BYPASS",
        u_fb.clock_enable_output_a = "BYPASS",
        u_fb.clock_enable_output_b = "BYPASS",
        u_fb.indata_reg_b = "CLOCK1",
        u_fb.intended_device_family = "Cyclone V",
        u_fb.lpm_type = "altsyncram",
        u_fb.operation_mode = "BIDIR_DUAL_PORT",
        u_fb.outdata_aclr_a = "NONE", u_fb.outdata_aclr_b = "NONE",
        u_fb.outdata_reg_a = "UNREGISTERED",
        u_fb.outdata_reg_b = "UNREGISTERED",
        u_fb.power_up_uninitialized = "FALSE",
        u_fb.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        u_fb.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        u_fb.width_byteena_a = 1, u_fb.width_byteena_b = 1,
        u_fb.wrcontrol_wraddress_reg_b = "CLOCK1",
        u_db.numwords_a = 512, u_db.widthad_a = 9, u_db.width_a = 8,
        u_db.numwords_b = 512, u_db.widthad_b = 9, u_db.width_b = 8,
        u_db.address_reg_b = "CLOCK1",
        u_db.clock_enable_input_a = "BYPASS",
        u_db.clock_enable_input_b = "BYPASS",
        u_db.clock_enable_output_a = "BYPASS",
        u_db.clock_enable_output_b = "BYPASS",
        u_db.indata_reg_b = "CLOCK1",
        u_db.intended_device_family = "Cyclone V",
        u_db.lpm_type = "altsyncram",
        u_db.operation_mode = "BIDIR_DUAL_PORT",
        u_db.outdata_aclr_a = "NONE", u_db.outdata_aclr_b = "NONE",
        u_db.outdata_reg_a = "UNREGISTERED",
        u_db.outdata_reg_b = "UNREGISTERED",
        u_db.power_up_uninitialized = "FALSE",
        u_db.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        u_db.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        u_db.width_byteena_a = 1, u_db.width_byteena_b = 1,
        u_db.wrcontrol_wraddress_reg_b = "CLOCK1";

    assign sd_buff_din = db_q;

    // ================= the engine =================
    localparam [4:0] E_IDLE  = 5'd0,
                     E_P_SET = 5'd1,    // a fill word goes out
                     E_P_ACK = 5'd2,    // the store took it
                     E_F_BEG = 5'd3,    // the fill: a sector, or ready
                     E_F_SET = 5'd4,    // sd_rd for the sector
                     E_F_ACK = 5'd5,    // its ack rose
                     E_F_END = 5'd6,    // its ack fell
                     E_F_RD0 = 5'd7,    // the buffer address
                     E_F_RDW = 5'd8,    // its registered output
                     E_F_RD1 = 5'd9,    // the byte
                     E_F_PSH = 5'd10,   // push it
                     E_F_INC = 5'd11,   // the next byte or sector
                     E_F_OK  = 5'd12,   // the last byte: ready
                     E_F_DONE= 5'd13,   // the fill is over
                     E_D_RD0 = 5'd14,   // the drain: the store's buffer
                     E_D_RD1 = 5'd15,
                     E_D_WR0 = 5'd16,   // the byte into ours
                     E_D_CHK = 5'd17,
                     E_D_REQ = 5'd18,   // sd_wr
                     E_D_ACK = 5'd19,
                     E_D_END = 5'd20,
                     E_D_ACKS= 5'd21,   // the store's ack toggle
                     E_L_WT  = 5'd22,   // the download: a byte from the host
                     E_L_B   = 5'd23,   // ... transformed
                     E_L_HDR = 5'd24,   // the header is complete
                     E_L_ADV = 5'd25,   // the table walk's next group
                     E_L_END = 5'd26;   // the window closed

    localparam [1:0] P_HDR = 2'd0, P_TBL = 2'd1, P_DAT = 2'd2;

    reg [4:0]  st     = E_IDLE;
    reg [4:0]  p_ret  = E_IDLE;
    reg [31:0] p_word = 32'd0;
    reg        p_seen = 1'b0;

    // who owns the store's fill port
    reg        jb     = 1'b0;
    reg        fl_act = 1'b0;
    reg        fl_drv = 1'b0;
    reg        dl_act = 1'b0;

    // the image fill
    reg [11:0] f_sec  = 12'd0;
    reg [11:0] f_nsec = 12'd0;
    reg [8:0]  f_pos  = 9'd0;
    reg [7:0]  f_val  = 8'd0;
    reg        rd_gate= 1'b0;
    // hps_io's byte port is unregistered on both sides: the address, the data
    // and the strobe belong to the same clock, so the write enable has to be
    // the strobe itself and not a registered copy of it (a copy lands one byte
    // late, and the sector would sit shifted by one in the buffer).
    assign fb_we = sd_buff_wr && rd_gate;
    wire [20:0] f_img = {f_sec, 9'd0} + {12'd0, f_pos};

    // the drain
    reg        dn_drv  = 1'b0;
    reg [10:0] dn_blk  = 11'd0;
    reg [8:0]  dn_pos  = 9'd0;
    reg        dn_snap = 1'b0;

    // the download
    reg        dl_req  = 1'b0;
    reg        dl_own  = 1'b0;
    reg        dl_drv  = 1'b0;
    reg        dl_prev = 1'b0;
    reg        dl_have = 1'b0;
    reg        dl_kill = 1'b0;
    reg [15:0] dl_widx = 16'd1;
    reg [7:0]  dl_b    = 8'd0;
    reg [7:0]  hdr     [0:13];
    reg [1:0]  dl_phase= P_HDR;
    reg [23:0] t_pos   = 24'd0;
    reg [15:0] off_data= 16'd0;
    reg        dl_s2   = 1'b1;        // the file carries both sides
    reg [15:0] t_exp   = 16'd14;      // where the group being streamed starts
    reg [7:0]  t_blk   = 8'd0;
    reg [8:0]  t_nblk  = 9'd0;
    reg        t_walk  = 1'b0;        // the block walk still has groups
    reg [7:0]  t_rec   = 8'd0;        // 0 = the block header, else 1-based
    reg [7:0]  t_cnt   = 8'd0;
    reg [2:0]  t_idx   = 3'd0;
    reg [31:0] blk_doff= 32'd0;       // the block's DataOffset, little endian
    reg        max_bad = 1'b0;
    reg [7:0]  rc_n    = 8'd0;        // the record fields seen so far
    reg [7:0]  rc_ol   = 8'd0;

    // events and crossings
    reg [1:0]  chg_pend = 2'b00;
    reg [1:0]  gen      = 2'b00;
    reg        drn_evt  = 1'b0;
    reg [11:0] dr_pay   = 12'd0;
    reg        fa_s1 = 1'b0, fa_s2 = 1'b0, fa_seen = 1'b0;
    reg        dr_s1 = 1'b0, dr_s2 = 1'b0, dr_seen = 1'b0;
    reg        cg_s1 = 1'b0, cg_s2 = 1'b0, cg_seen = 1'b0;

    wire       dl_sel  = ioctl_download &&
                         (ioctl_index == 16'd1 || ioctl_index == 16'd2);
    wire       dl_win  = ioctl_download && (ioctl_index == dl_widx);
    wire       dl_rise = dl_sel && !dl_prev;

    // the drive of a pending event: the event's bit index, drive B first when
    // a burst carried both (drive A is then the next dispatch)
    wire       chg_d    = chg_pend[1];
    wire       chg_free = (!fl_act || fl_drv == chg_d) &&
                          (!dl_act || dl_drv == chg_d);
    wire       fl_go    = (|chg_pend) && chg_free;
    wire       dl_go    = dl_req && !dl_act && (!fl_act || fl_drv == dl_drv);

    // the header fields, straight out of the collected bytes
    wire [7:0]  h_cyl   = {hdr[5], hdr[4]};
    wire [15:0] h_offd  = {hdr[11], hdr[10]};
    wire        h_ok    = (hdr[0] == 8'h46) && (hdr[1] == 8'h44) &&
                          (hdr[2] == 8'h49) &&                  // "FDI"
                          (hdr[3] == 8'h00) &&                  // the version
                          (hdr[5] == 8'h00) &&
                          (h_cyl >= 8'd1) && (h_cyl <= 8'd84) && // the cap
                          (hdr[7] == 8'h00) &&                  // u16 sides
                          (hdr[6] == 8'h01 || hdr[6] == 8'h02) &&
                          (h_offd >= 16'd21);                   // 0x0E + group
    // a one-side file holds cyl blocks, a two-side one cyl*2 (the store
    // indexes them track*2+side regardless)
    wire [8:0]  h_nblk  = hdr[6][0] ? {2'd0, h_cyl} : {1'b0, h_cyl, 1'b0};

    // the data area offset of the byte being streamed
    wire [23:0] dat_pos = t_pos - {8'd0, off_data};

    // the table walk, one group at a time (see E_L_ADV)
    wire        a_gend  = (t_idx == 3'd6);
    wire        a_bend  = (t_rec == 8'd0) ? (t_cnt == 8'd0)
                                          : (t_rec >= t_cnt);
    wire        a_last  = a_bend && ({1'b0, t_blk} + 9'd1 >= t_nblk);

    // this byte completes the declared table
    wire       a_done = a_gend && a_last;

    // The store's table is indexed by track*2+side whatever the image says,
    // so a one-side image's block n lives at 2n (a request for its side 1 is
    // refused by cfg_sides, so 2n is the only index that is ever read).
    wire [7:0] tbl_ti = dl_s2 ? t_blk : {t_blk[6:0], 1'b0};

    // a record's last data byte against the store's 2 MiB window: the record
    // is C,H,R,N,flags,off_lo,off_hi, so N is there since byte 3, off_lo since
    // byte 5, and off_hi is the byte being streamed
    wire [2:0]  rc_N    = (rc_n[2:0] > 3'd3) ? 3'd3 : rc_n[2:0];
    wire [22:0] rc_base = (|blk_doff[31:21]) ? 23'h7FFFFF
                                             : {2'd0, blk_doff[20:0]};
    wire [22:0] rc_end  = rc_base + {6'd0, dl_b, rc_ol} + (23'd128 << rc_N);
    wire        rc_bad  = (rc_end > 23'h200000);

    integer si;

    always @(posedge clk_sys) begin
        db_we <= 1'b0;

        // ---- the crossings from the store's gs_clk domain ----
        fa_s1 <= fill_ack_tgl;  fa_s2 <= fa_s1;
        dr_s1 <= drn_tgl;       dr_s2 <= dr_s1;
        cg_s1 <= chg_tgl;       cg_s2 <= cg_s1;
        if (dr_s2 != dr_seen) begin
            dr_seen <= dr_s2;
            dr_pay  <= drn_info;
            drn_evt <= 1'b1;
            // the image this block belongs to is the one that was mounted
            // when the store asked for it back: a mount that lands before the
            // block is served makes those bytes somebody else's
            dn_snap <= gen[drn_info[11]];
        end
        if (cg_s2 != cg_seen) begin
            cg_seen  <= cg_s2;
            chg_pend <= chg_pend | chg_ev;
            for (si = 0; si <= 1; si = si + 1)
                if (chg_ev[si]) gen[si] <= ~gen[si];
        end

        // ---- the download claim (hps_io opens one window per file) ----
        dl_prev <= dl_sel;
        if (dl_rise && !dl_own) begin
            dl_own  <= 1'b1;
            dl_req  <= 1'b1;
            dl_drv  <= ioctl_index[1];
            dl_widx <= ioctl_index;
        end

        if (rst) begin
            st <= E_IDLE;   p_ret <= E_IDLE;  p_word <= 32'd0; p_seen <= 1'b0;
            jb <= 1'b0;  fl_act <= 1'b0;  fl_drv <= 1'b0;
            dl_act <= 1'b0; dl_req <= 1'b0; dl_own <= 1'b0; dl_drv <= 1'b0;
            dl_prev <= 1'b0; dl_have <= 1'b0; dl_kill <= 1'b0;
            dl_widx <= 16'd1; dl_b <= 8'd0;  dl_phase <= P_HDR;
            f_sec <= 12'd0; f_nsec <= 12'd0; f_pos <= 9'd0; f_val <= 8'd0;
            fb_addr <= 9'd0; db_waddr <= 9'd0; db_wd <= 8'd0; rd_gate <= 1'b0;
            dn_drv <= 1'b0; dn_blk <= 11'd0; dn_pos <= 9'd0; dn_snap <= 1'b0;
            off_data <= 16'd0; blk_doff <= 32'd0; max_bad <= 1'b0;
            t_pos <= 24'd0; t_exp <= 16'd14; t_blk <= 8'd0; t_nblk <= 9'd0;
            t_walk <= 1'b0; t_rec <= 8'd0; t_cnt <= 8'd0; t_idx <= 3'd0;
            dl_s2 <= 1'b1;
            rc_n <= 8'd0; rc_ol <= 8'd0;
            chg_pend <= 2'b00; gen <= 2'b00; drn_evt <= 1'b0; dr_pay <= 12'd0;
            fa_s1 <= 1'b0; fa_s2 <= 1'b0; fa_seen <= 1'b0;
            dr_s1 <= 1'b0; dr_s2 <= 1'b0; dr_seen <= 1'b0;
            cg_s1 <= 1'b0; cg_s2 <= 1'b0; cg_seen <= 1'b0;
            sd_rd <= 2'b00; sd_wr <= 2'b00; sd_lba <= 32'd0;
            fill_tgl <= 1'b0; fill_word <= 32'd0;
            drn_ack_tgl <= 1'b0; drn_addr_b <= 9'd0;
            ioctl_wait <= 1'b0;
        end
        else begin
            // The ioctl discipline (the mcu_emu ownership rule, and what
            // sys/hps_io.sv's read machine expects of a core): ioctl_wr is a
            // one-clock strobe that carries the byte - hps_io never looks at
            // the wait, so a strobe that is not taken here is lost for good.
            // The wait therefore stands up for the whole time the core owns the
            // window and falls only in the byte-wait state with nothing pending:
            // the source consults it between bytes, so the core is ready by the
            // time a strobe arrives, and a byte sits in dl_b until the FSM takes it.
            if (dl_own) ioctl_wait <= 1'b1;
            if (!dl_own) ioctl_wait <= 1'b0;
            if (st == E_L_WT && dl_act && dl_win && !dl_have)
                ioctl_wait <= 1'b0;
            if (ioctl_download && ioctl_wr && !dl_have &&
                (dl_own || dl_rise)) begin
                dl_b       <= ioctl_dout;
                dl_have    <= 1'b1;
                ioctl_wait <= 1'b1;
            end

            case (st)
            // ==================== the dispatcher ====================
            E_IDLE: begin
                if (fl_go) begin
                    chg_pend[chg_d] <= 1'b0;
                    fl_act <= 1'b0;
                    dl_act <= 1'b0;          // a remount ends a download too
                    dl_own <= 1'b0;
                    jb     <= 1'b1;
                    if (mnt_lvl[chg_d] && mnt_valid[chg_d]) begin
                        fl_act <= 1'b1;
                        fl_drv <= chg_d;
                        f_sec  <= 12'd0;
                        f_pos  <= 9'd0;
                        f_nsec <= mnt_sectors[chg_d];
                        p_word <= {2'd0, chg_d, mnt_kind[chg_d],
                                   mnt_tracks[chg_d], mnt_sides[chg_d], 19'd0};
                        p_ret  <= E_F_BEG;
                    end
                    else begin            // an eject, or no usable geometry
                        p_word <= {2'd0, chg_d, K_TRD, 7'd0, 1'b0, 19'd0};
                        p_ret  <= E_IDLE;
                    end
                    st <= E_P_SET;
                end
                else if (dl_go) begin
                    dl_req   <= 1'b0;
                    dl_act   <= 1'b1;
                    fl_act   <= 1'b0;        // a download replaces a fill
                    jb       <= 1'b1;
                    // dl_b/dl_have keep whatever the claim clock took: that
                    // byte is the header's first one, not something to discard
                    dl_kill  <= 1'b0;
                    dl_phase <= P_HDR;
                    t_pos    <= 24'd0;
                    t_exp    <= 16'd14;
                    t_blk    <= 8'd0;
                    t_idx    <= 3'd0;
                    t_rec    <= 8'd0;
                    t_walk   <= 1'b0;
                    max_bad  <= 1'b0;
                    st       <= E_L_WT;
                end
                else if (drn_evt) begin
                    drn_evt <= 1'b0;
                    dn_drv  <= dr_pay[11];
                    dn_blk  <= dr_pay[10:0];
                    // dn_snap is the generation at the event, taken above
                    dn_pos  <= 9'd0;
                    // a read-only image, or one that is gone, is not written
                    st      <= (mnt_lvl[dr_pay[11]] && !mnt_ro[dr_pay[11]])
                                 ? E_D_RD0 : E_D_ACKS;
                end
                else if (fl_act)
                    st <= E_F_BEG;
            end

            // ==================== a fill word ====================
            E_P_SET: begin
                fill_word <= p_word;
                fill_tgl  <= ~fill_tgl;
                p_seen    <= fa_s2;
                st        <= E_P_ACK;
            end
            E_P_ACK: if (fa_s2 != p_seen)
                st <= p_ret;

            // ==================== the image fill ====================
            E_F_BEG: begin
                f_pos <= 9'd0;
                if (f_sec == f_nsec) st <= E_F_OK;
                else                 st <= E_F_SET;
            end
            // hps_io serves one request per slot at a time and samples the
            // request lines only between transfers: a request raised while the
            // slot is still busy is invisible to the host, and the ack that
            // belongs to the other transfer would be taken for one's own.
            E_F_SET: if (!sd_ack[fl_drv]) begin
                sd_lba        <= {21'd0, f_sec};
                sd_rd[fl_drv] <= 1'b1;
                rd_gate       <= 1'b1;
                st            <= E_F_ACK;
            end
            E_F_ACK: if (sd_ack[fl_drv]) begin
                sd_rd[fl_drv] <= 1'b0;
                st            <= E_F_END;
            end
            E_F_END: if (!sd_ack[fl_drv]) begin
                rd_gate <= 1'b0;
                st      <= E_F_RD0;
            end
            E_F_RD0: begin
                fb_addr <= f_pos;
                st      <= E_F_RDW;
            end
            E_F_RDW:
                st <= E_F_RD1;
            E_F_RD1: begin
                f_val <= fb_q;
                st    <= E_F_PSH;
            end
            E_F_PSH: begin
                p_word <= {2'd1, 1'b0, f_img, f_val};
                p_ret  <= E_F_INC;
                st     <= E_P_SET;
            end
            E_F_INC: begin
                if (f_pos == 9'd511) begin
                    f_sec <= f_sec + 12'd1;
                    st    <= E_IDLE;         // let a mount or a drain in
                end
                else begin
                    f_pos <= f_pos + 9'd1;
                    st    <= E_F_RD0;
                end
            end
            E_F_OK: begin
                p_word <= {2'd2, fl_drv, 29'd0};
                p_ret  <= E_F_DONE;
                st     <= E_P_SET;
            end
            E_F_DONE: begin
                fl_act <= 1'b0;
                jb     <= 1'b0;
                st     <= E_IDLE;
            end

            // ==================== the drain ====================
            E_D_RD0: begin
                drn_addr_b <= dn_pos;
                st         <= E_D_RD1;
            end
            E_D_RD1:
                st <= E_D_WR0;
            E_D_WR0: begin
                db_we    <= 1'b1;
                db_waddr <= dn_pos;
                db_wd    <= drn_q_b;
                if (dn_pos == 9'd511) st <= E_D_CHK;
                else begin
                    dn_pos <= dn_pos + 9'd1;
                    st     <= E_D_RD0;
                end
            end
            E_D_CHK:
                // the image behind this block may have been replaced while it
                // was copied: its bytes then belong to a file that is gone
                st <= (gen[dn_drv] != dn_snap || !mnt_lvl[dn_drv] ||
                       mnt_ro[dn_drv]) ? E_D_ACKS : E_D_REQ;
            E_D_REQ: if (!sd_ack[dn_drv]) begin
                sd_lba        <= {21'd0, dn_blk};
                sd_wr[dn_drv] <= 1'b1;
                st            <= E_D_ACK;
            end
            E_D_ACK: if (sd_ack[dn_drv]) begin
                sd_wr[dn_drv] <= 1'b0;
                st            <= E_D_END;
            end
            E_D_END: if (!sd_ack[dn_drv])
                st <= E_D_ACKS;
            E_D_ACKS: begin
                drn_ack_tgl <= ~drn_ack_tgl;
                st          <= E_IDLE;
            end

            // ==================== the FDI download ====================
            E_L_WT: begin
                if (chg_pend[dl_drv]) begin        // remounted: drop it and
                    dl_own  <= 1'b0;               // leave the event to the
                    dl_act  <= 1'b0;               // dispatcher
                    jb      <= 1'b0;
                    st      <= E_IDLE;
                end
                // a byte already taken belongs to the core: hps_io lowers
                // ioctl_download on the clock after its last strobe, so the
                // window closing is never a reason to drop what was accepted
                else if (dl_have) begin
                    dl_have <= 1'b0;
                    st      <= E_L_B;
                end
                else if (dl_kill || !dl_win)
                    st <= E_L_END;
            end

            // the header is complete: validate it, then mount the FDI
            E_L_HDR: begin
                if (!h_ok) begin
                    dl_own <= 1'b0;
                    dl_have <= 1'b0;
                    dl_act <= 1'b0;
                    jb     <= 1'b0;
                    st     <= E_IDLE;              // the drive keeps its image
                end
                else begin
                    off_data <= h_offd;
                    // the header's u16 sides: 1 or 2. The store's sides flag
                    // (and this module's tbl_ti remap) mean "there is a side
                    // 1", which is the odd value here being false
                    dl_s2    <= ~hdr[6][0];
                    t_nblk   <= h_nblk;
                    t_walk   <= 1'b1;
                    dl_phase <= P_TBL;
                    p_word   <= {2'd0, dl_drv, K_FDI, h_cyl[6:0],
                                 ~hdr[6][0], 19'd0};
                    p_ret    <= E_L_WT;
                    st       <= E_P_SET;
                end
            end

            // one file byte: a header byte, a table byte, or a data byte
            E_L_B: begin
                if (dl_phase == P_HDR) begin
                    hdr[t_pos[3:0]] <= dl_b;
                    t_pos           <= t_pos + 24'd1;
                    st              <= (t_pos == 24'd13) ? E_L_HDR : E_L_WT;
                end
                else if (dl_phase == P_TBL) begin
                    t_pos <= t_pos + 24'd1;
                    // t_idx (the byte's slot inside the 7-byte group) is
                    // counted by E_L_ADV: the index of the byte being streamed
                    // is what the store's slot means, and only the state after
                    // it may retire the group
                    st    <= E_L_ADV;
                    if (t_walk) begin
                        if (t_rec == 8'd0) begin             // the block header
                            if (t_idx < 3'd4) begin
                                blk_doff <= {dl_b, blk_doff[31:8]};
                                p_word   <= {2'd1, 2'b11, 9'd0, tbl_ti,
                                             t_idx, dl_b};
                                p_ret <= E_L_ADV;
                                st    <= E_P_SET;
                            end
                            else if (t_idx == 3'd6) begin
                                t_cnt  <= dl_b;
                                p_word <= {2'd1, 2'b11, 9'd0, tbl_ti,
                                           3'd4, dl_b};
                                p_ret <= E_L_ADV;
                                st    <= E_P_SET;
                            end
                        end
                        else begin                           // a sector record
                            // t_rec counts from 1 (0 marks the block header);
                            // the store's record slots count from 0
                            p_word <= {2'd1, 2'b10, 4'd0, tbl_ti,
                                       t_rec[4:0] - 5'd1, t_idx, dl_b};
                            p_ret  <= E_L_ADV;
                            st     <= E_P_SET;
                            if (t_idx == 3'd3) rc_n  <= dl_b;
                            if (t_idx == 3'd5) rc_ol <= dl_b;
                            if (t_idx == 3'd6 && rc_bad) max_bad <= 1'b1;
                        end
                    end
                end
                else begin                                  // the data area
                    t_pos  <= t_pos + 24'd1;
                    p_word <= {2'd1, 1'b0, dat_pos[20:0], dl_b};
                    p_ret  <= E_L_WT;
                    st     <= E_P_SET;
                end
            end

            // the table walk's next group, and the start of the data area
            E_L_ADV: begin
                st <= E_L_WT;
                if (t_pos >= {8'd0, off_data}) begin
                    dl_phase <= P_DAT;              // the table is behind us
                    if (t_walk && !a_done)          // fewer bytes than the
                        dl_kill <= 1'b1;            // header counted
                    t_walk   <= 1'b0;
                end
                else if (t_walk && a_gend) begin
                    t_idx <= 3'd0;
                    t_exp <= t_exp + 16'd7;         // where the next one lives
                    if (a_bend) begin
                        t_rec <= 8'd0;
                        if (a_last) t_walk <= 1'b0; // the extension area ends
                        else        t_blk  <= t_blk + 8'd1;
                    end
                    else if (t_rec == 8'd0) t_rec <= 8'd1;
                    else                    t_rec <= t_rec + 8'd1;
                    // a group of a table that is still walking has to fit
                    // before off_data; the last block's may end at it
                    if (!a_last && (t_exp + 16'd14 > off_data)) begin
                        dl_kill <= 1'b1;
                    end
                end
                else if (t_walk) t_idx <= t_idx + 3'd1;
            end

            // the window closed: ready only for a download that reached its
            // data area with every record inside the store's window
            E_L_END: begin
                dl_act  <= 1'b0;
                dl_own  <= 1'b0;
                jb      <= 1'b0;
                dl_kill <= 1'b0;
                dl_have <= 1'b0;
                if (!dl_kill && !max_bad && dl_phase == P_DAT) begin
                    p_word <= {2'd2, dl_drv, 29'd0};
                    p_ret  <= E_IDLE;
                    st     <= E_P_SET;
                end
                else
                    st <= E_IDLE;
            end
            default: st <= E_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
