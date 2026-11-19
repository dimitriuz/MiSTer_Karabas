// hotkeys.sv - the core's keyboard shortcuts, decoded from hps_io's ps2_key
// (the same event word ps2_hid takes): the OSD items Reset, NMI and Turbo
// from the keyboard, as the Karabas Go has them (its Ctrl+Alt+Del / Menu+F12 /
// Menu+F11; the MiSTer F12 key belongs to its OSD and Menu is not a key here).
//
//   Ctrl+Alt+Del   reset   -> `reset` for HOLD clk (the OSD Reset item's level)
//   Ctrl+Alt+End   NMI     -> `nmi` for HOLD clk (the OSD NMI trigger bit)
//   Ctrl+Alt+PgUp  turbo   -> next Off/2x/4x/8x, written back to the OSD
//                             status through hps_io's status_in/status_set,
//                             so the menu shows the new value
//
// Either Ctrl and either Alt count. A shortcut fires on the press of its key
// while both modifiers are down, once per press (held keys do not repeat it).
// The keys themselves still reach the machine through ps2_hid.
`default_nettype none

module hotkeys #(
    parameter [23:0] HOLD = 24'd250000      // 5 ms at 50 MHz
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [10:0] ps2_key,             // [10] toggles per event, [9] press,
                                            // [8] extended, [7:0] set-2 code
    input  wire  [1:0] turbo_now,           // the OSD's Turbo field (status[9:8])
    output wire        hk_reset,
    output wire        hk_nmi,
    output reg   [1:0] turbo_new,
    output reg         turbo_set            // one clk: turbo_new is to be written
);
    reg        tog = 1'b0;
    reg  [1:0] ctrl = 2'b00, alt = 2'b00;   // [0] left, [1] right
    reg        k_del = 1'b0, k_end = 1'b0, k_pgup = 1'b0;
    reg [23:0] t_rst = 24'd0, t_nmi = 24'd0;

    assign hk_reset = (t_rst != 24'd0);
    assign hk_nmi   = (t_nmi != 24'd0);

    wire mods = (|ctrl) && (|alt);
    wire ext  = ps2_key[8];
    wire prs  = ps2_key[9];
    wire [7:0] code = ps2_key[7:0];

    always @(posedge clk) begin
        turbo_set <= 1'b0;
        if (t_rst != 24'd0) t_rst <= t_rst - 1'd1;
        if (t_nmi != 24'd0) t_nmi <= t_nmi - 1'd1;
        if (reset) begin
            tog <= ps2_key[10];
            ctrl <= 2'b00; alt <= 2'b00;
            k_del <= 1'b0; k_end <= 1'b0; k_pgup <= 1'b0;
            t_rst <= 24'd0; t_nmi <= 24'd0;
        end
        else if (ps2_key[10] != tog) begin
            tog <= ps2_key[10];
            if (code == 8'h14) begin
                if (ext) ctrl[1] <= prs; else ctrl[0] <= prs;
            end
            if (code == 8'h11) begin
                if (ext) alt[1] <= prs; else alt[0] <= prs;
            end
            if (ext && code == 8'h71) begin               // Delete
                k_del <= prs;
                if (prs && !k_del && mods) t_rst <= HOLD;
            end
            if (ext && code == 8'h69) begin               // End
                k_end <= prs;
                if (prs && !k_end && mods) t_nmi <= HOLD;
            end
            if (ext && code == 8'h7D) begin               // Page Up
                k_pgup <= prs;
                if (prs && !k_pgup && mods) begin
                    turbo_new <= turbo_now + 2'd1;
                    turbo_set <= 1'b1;
                end
            end
        end
    end
endmodule
