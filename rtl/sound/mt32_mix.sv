//============================================================================
//
//  Karabas Profi for MiSTer - MT32-pi audio mix + MIDI TX mute + MidiLink
//  UART route. One module so tb_mt32_mix can test it all directly.
//
//  Audio: audio_x = sat16(emu_x + (pi_on ? pi_x : 0)),
//  pi_on = pi_available & ~pi_disable. emu_* is clk_bus (the machine's
//  samples) and passes two clk (CLK_AUDIO) registers before the summing
//  register, so the outputs lag the machine by three clocks and mt32pi's I2S
//  samples by one; equally on both channels and inaudible in the 24.576 MHz
//  sample stream. sat16 is the signed 17-bit sum clipped when its top two
//  bits disagree (ao486's style: overflow up -> 32767, down -> -32768).
//
//  midi_tx_to_pi = midi_tx | (pi_available & pi_disable): ao486's
//  mpu_tx | mt32_mute pattern - with the Pi present but disabled in the OSD
//  it sees an idle line, never the emulator's MIDI stream.
//
//  uart_txd = (uart_mode == 3) ? midi_tx : 1'b1: the MidiLink route.
//  uart_mode is hps_io's OSD "UART mode" select; Main_MiSTer sends 3 only
//  for "MIDI" (menu.cpp SetUARTMode maps PPP/Modem/UDP/SNI to 1 and Console
//  to 2, and Linux owns ttyS1 in those modes, so only mode 3 may carry our
//  bytes). It carries the UNMUTED line: "Use MT32-pi = No" mutes only the Pi
//  on the USER port, never MidiLink on the HPS UART. Idle high in every
//  other mode.
//
//============================================================================

module mt32_mix (
    input  wire               clk,           // CLK_AUDIO
    input  wire signed [15:0] emu_l, emu_r,  // profi AUDIO_L/R (clk_bus domain)
    input  wire signed [15:0] pi_l,  pi_r,   // mt32pi mt32_i2s_l/r (CLK_AUDIO)
    input  wire               pi_available,  // mt32pi mt32_available
    input  wire               pi_disable,    // status[27]: 1 = "Use MT32-pi: No"
    input  wire               midi_tx,       // profi MIDI_TX
    input  wire        [ 7:0] uart_mode,     // hps_io uart_mode (3 = MIDI)
    output reg  signed [15:0] audio_l, audio_r,
    output wire               midi_tx_to_pi,
    output wire               uart_txd       // UART_TXD, idle high
);

wire pi_on = pi_available & ~pi_disable;

reg signed [15:0] emu_l_s1, emu_r_s1;
reg signed [15:0] emu_l_s2, emu_r_s2;

wire signed [16:0] pi_l_on = pi_on ? {pi_l[15], pi_l} : 17'sd0;
wire signed [16:0] pi_r_on = pi_on ? {pi_r[15], pi_r} : 17'sd0;
wire signed [16:0] sum_l = {emu_l_s2[15], emu_l_s2} + pi_l_on;
wire signed [16:0] sum_r = {emu_r_s2[15], emu_r_s2} + pi_r_on;

always @(posedge clk) begin
    emu_l_s1 <= emu_l;
    emu_r_s1 <= emu_r;
    emu_l_s2 <= emu_l_s1;
    emu_r_s2 <= emu_r_s1;
    audio_l <= (sum_l[16] == sum_l[15]) ? sum_l[15:0]
                                        : (sum_l[16] ? 16'h8000 : 16'h7FFF);
    audio_r <= (sum_r[16] == sum_r[15]) ? sum_r[15:0]
                                        : (sum_r[16] ? 16'h8000 : 16'h7FFF);
end

assign midi_tx_to_pi = midi_tx | (pi_available & pi_disable);

assign uart_txd = (uart_mode == 8'd3) ? midi_tx : 1'b1;

endmodule