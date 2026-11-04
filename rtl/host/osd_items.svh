// osd_items.svh - the OSD items of the Karabas Profi core in one place.
// Included by rtl/host/mcu_emu.sv (the switch values it sends over the MCU
// link) and by the MiSTer top (its CONF_STR): the item index, its position
// in the 128-bit MiSTer `status` vector and the value the item sends must
// stay together. Index = CMD_SWITCHES frame index = kg_soft_switches
// register (profi.vhd G_SOFTSW_GO: register n = OSD item n of core.json,
// the Karabas Go layout). Item 9 is the HDF file slot of that layout: no
// register, no frame, no field here.
//
// The value a switch sends is the option chosen in the Karabas OSD, in
// CONF_STR order (docs/protocol.md section 4: switches carry the selected
// option); three items do not store their value in the natural order:
//
//   idx item        status       value / CONF_STR options
//   0   ROM Bank    [2:1]        field
//   1   Covox       [3]          ~field: "On,Off"
//   2   PSG Mix     [6:4]        (field + 1) % 6:
//                                "AY ACB,AY Mono,YM ABC,YM ACB,YM Mono,AY ABC"
//   3   VSync       [7]          field
//   4   Turbo       [9:8]        field
//   5   Joystick L  [12:10]      field (<= 5)
//   6   Joystick R  [15:13]      (field + 1) % 6:
//                                "Sinclair1,Sinclair2,Cursor,QAOPM,QAOPS,Kempston"
//   7   DivMMC      [16]         field
//   8   HDD         -            constant 1 (Image; there is no CF card on
//                                MiSTer, the only option is the HDF image)
//   10  Keyboard    [17]         field
//   11  Pause       [18]         field
//   12  GS Reset    [19] trigger
//   13  NMI         [20] trigger
//   14  Reset       osd_reset    trigger
//
// Triggers are not status fields: mcu_emu sends their frames itself (1, then
// 0 after TRIGGER_CLKS), so osd_value is 0 for them and the run-loop value
// compare never fires for indices 12..14.

localparam int OSD_ROM_BANK = 0;
localparam int OSD_COVOX    = 1;
localparam int OSD_PSG_MIX  = 2;
localparam int OSD_VSYNC    = 3;
localparam int OSD_TURBO    = 4;
localparam int OSD_JOY_L    = 5;
localparam int OSD_JOY_R    = 6;
localparam int OSD_DIVMMC   = 7;
localparam int OSD_HDD      = 8;
localparam int OSD_KEYBOARD = 10;
localparam int OSD_PAUSE    = 11;
localparam int OSD_GS_RESET = 12;
localparam int OSD_NMI      = 13;
localparam int OSD_RESET    = 14;

// osd_value: the CMD_SWITCHES value of item idx for the status vector.
function automatic [7:0] osd_value(input int idx, input [127:0] status);
    reg [3:0] v;
    begin
        // note: the item index is not a bit position - each field is spelled out
        case (idx)
            OSD_ROM_BANK: v = {2'd0, status[2:1]};
            OSD_COVOX:    v = {3'd0, ~status[3]};
            OSD_PSG_MIX:  v = ({1'b0, status[6:4]} + 4'd1) % 4'd6;
            OSD_VSYNC:    v = {3'd0, status[7]};
            OSD_TURBO:    v = {2'd0, status[9:8]};
            OSD_JOY_L:    v = {1'b0, status[12:10]};
            OSD_JOY_R:    v = ({1'b0, status[15:13]} + 4'd1) % 4'd6;
            OSD_DIVMMC:   v = {3'd0, status[16]};
            OSD_HDD:      v = 4'd1;
            OSD_KEYBOARD: v = {3'd0, status[17]};
            OSD_PAUSE:    v = {3'd0, status[18]};
            default:      v = 4'd0;  // 9, and the triggers 12..14
        endcase
        osd_value = {4'd0, v};
    end
endfunction
