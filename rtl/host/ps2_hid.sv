// PS/2 (hps_io ps2_key) to USB HID boot keyboard report converter for the
// Karabas Profi core.
//
// ps2_key is the hps_io keyboard word: bit 10 toggles on every event,
// bit 9 = pressed, bit 8 = the scancode carries the E0 extension, bits 7..0 =
// PS/2 set-2 code (hps_io resolves the F0 sequences: one event is one
// complete key press or release). E1 (Pause) and the PrintScreen double code
// never arrive as single events and are not handled.
//
// report is the boot-protocol 8-byte HID report: [7:0] modifier bits in usage
// order (bit 0 LCtrl .. bit 7 RGUI), [15:8] .. [55:48] = keys 1..6 in press
// order, 0x00 when free; `changed` is high for one clock whenever report
// changes. Events whose scancode has no usage, repeats of a key that is
// already in the report, and presses with no free slot change nothing.
//
// clk is the MiSTer CLK_50M (hps_io clock), reset the core-wide synchronous
// reset; both are the same domain hps_io delivers ps2_key in, so ps2_key
// needs no synchroniser.
`default_nettype none

module ps2_hid (
    input  wire        clk,
    input  wire        reset,
    input  wire [10:0] ps2_key,
    output reg  [55:0] report,
    output reg         changed
);

`include "ps2_hid_table.svh"

    reg [7:0] keys [0:5];   // usages in press order, 0x00 = slot free
    reg [7:0] mods;         // modifier usage 0xE0 + i -> bit i
    reg       tog;          // ps2_key[10] of the last processed event

    reg [7:0] nk [0:5];     // next keys / modifiers, committed on an event
    reg [7:0] nmods;
    reg [7:0] usage;
    reg       pressed;
    reg       present;
    integer   slot;
    integer   j;

    always @(*)
        report = {keys[5], keys[4], keys[3], keys[2], keys[1], keys[0], mods};

    always @(posedge clk) begin
        changed <= 1'b0;
        if (reset) begin
            mods <= 8'h00;
            for (j = 0; j < 6; j = j + 1)
                keys[j] <= 8'h00;
            tog <= ps2_key[10];
        end else if (ps2_key[10] !== tog) begin
            tog     <= ps2_key[10];
            usage   = ps2_to_hid(ps2_key[8], ps2_key[7:0]);
            pressed = ps2_key[9];
            nmods   = mods;
            for (j = 0; j < 6; j = j + 1)
                nk[j] = keys[j];
            if (usage != 8'h00) begin
                if (usage >= 8'hE0) begin
                    nmods[usage[2:0]] = pressed;
                end else if (pressed) begin
                    // Ignore typematic repeats (usage already held); else
                    // append to the first free slot, if any.
                    present = 1'b0;
                    slot    = -1;
                    for (j = 0; j < 6; j = j + 1)
                        if (keys[j] == usage) present = 1'b1;
                    for (j = 0; j < 6; j = j + 1)
                        if ((slot == -1) && (nk[j] == 8'h00)) slot = j;
                    if (!present && (slot >= 0))
                        nk[slot] = usage;
                end else begin
                    // Drop the usage and shift the later ones down; a
                    // release without a slot changes nothing.
                    slot = -1;
                    for (j = 0; j < 6; j = j + 1)
                        if ((slot == -1) && (keys[j] == usage)) slot = j;
                    if (slot >= 0)
                        for (j = 0; j < 6; j = j + 1)
                            nk[j] = (j < slot) ? keys[j]
                                  : ((j == 5) ? 8'h00 : keys[j + 1]);
                end
            end
            if (nmods != mods) begin
                mods    <= nmods;
                changed <= 1'b1;
            end
            for (j = 0; j < 6; j = j + 1)
                if (nk[j] != keys[j]) begin
                    keys[j] <= nk[j];
                    changed <= 1'b1;
                end
        end
    end

endmodule

`default_nettype wire
