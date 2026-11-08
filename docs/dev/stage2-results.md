# Stage 2 board results

Board: DE10-Nano MiSTer at 192.168.1.13. Dates: 2026-11-07 (Tasks 4-5, builds 24/26)
and 2026-11-08 (Task 6 on build 27, the full run on build 28, commit 150a7c8).

How it was driven: as in stage 1 (`load_core`, the 16-byte status file, uinput keys from
`mkeys2.py`, `screenshot`). A uinput mouse (`mmouse.py`: REL_X/REL_Y/REL_WHEEL and the
three buttons) moved the mouse. Its button events never reach MiSTer's mouse report
(Linux sees them on `/dev/input/mice`, but the core's button bits do not change), so
the owner checked the buttons with the board's Logitech K400 touchpad, and the
joysticks with an Xbox 360 pad. Status bits: ROM bank [2:1], VSync [7] (128), Turbo
[9:8] (256/512/768), Joystick L [12:10], Mode [26]. Screenshots are in `stage2-shots/`.

| Check | Result | Evidence |
|---|---|---|
| Turbo without waits (PQ-DOS BIOS "Z80 clock") | PASS | `pqdos-turbo-{off,2x,4x,8x}.png`: 3.0 / 6.0 / 12.0 / 24.0 MHz. The BIOS runs in DS80 mode on the 24.107 MHz bus, so these are the full no-wait rates; stage 1 with waits measured 8.3 MHz at 8x |
| ROMain (DS80 608x272) at each turbo | PASS | `romain-turbo-{off,2x,4x,8x}.png`, status bar "Turbo: Off/2x/4x/8x" |
| DS80 → Spectrum switch, 128 BASIC `10 PRINT 1` / `RUN` at each turbo | PASS | `basic128-turbo-{off,2x,4x,8x}.png` (the ROMain menu starts Sinclair 128K, which leaves DS80) |
| Pentagon / 48k, 50 / 60 Hz | PASS | `pentagon-50hz.png` 376x304, `pentagon-60hz.png` 376x248, `48k-50hz.png` 384x304, `48k-60hz.png` 384x248; `PRINT 1` runs in all four |
| 48k timing and contention | PASS | BASIC `FOR i=1 TO 3000: NEXT i` counted with FRAMES: 922 frames Pentagon (`pentagon-loop-922.png`), 948 frames 48k (`48k-loop-948.png`). The frame length alone (71680 vs 69888 T) gives 945.6; the rest is contention |
| Mode switched in the OSD at run time | PASS | `runtime-to-pentagon.png` (376), `runtime-to-48k.png` (384), the program keeps running |
| Pause | PASS | a FRAMES counter loop: `pause-on-1.png` and `pause-on-2.png` (15 s apart) both 112/12; `pause-off.png` counts again at about 49 frames/s |
| NMI | PASS (upstream behaviour) | with DivMMC off, profi pages TR-DOS for the NMI: in 128 BASIC the program stops in the TR-DOS NMI handler (`nmi-basic128.png`); in the DS80 ROMain menu nothing visible happens (`nmi-romain.png`) |
| RTC | PASS | BASIC reads of the RTC ports (DFFD bit 5 = 1, address #BF, data #9F): 20:17:08 Sat 07.11.26, B = 02, D = 80; read again 22 s later 22 s on (`rtc-basic-2.png`, `rtc-basic-3.png`), so the FPGA clock ticks between MiSTer's updates. The ROMain status bar shows `08.11.26 08 16` at 08:16:31 board time (`romain-turbo-8x.png`). The PQ-DOS BIOS reports "RTC: Ok" |
| Mouse X/Y | PASS | Kempston ports #FBDF/#FFDF follow the uinput mouse: X +20 → +20, up 10 → Y +10 (`mouse-move.png`); build 28: X +10, up 5 → Y +5 (`mouse-build28.png`) |
| Mouse buttons | PASS | owner, K400 touchpad: left clears bit 1, right clears bit 0 of #FADF (127 → 125 / 126) |
| Mouse wheel | FAIL: inverted, finding 1 | wheel up 3 lowers the #FADF wheel nibble by 3 |
| Joystick, Kempston | PASS | owner, Xbox pad: A → `IN 31` = 32 (upstream maps A to bit 5, B to bit 4 fire) |
| Joystick, Sinclair | PASS | owner, Joystick L = Sinclair2: d-pad and B (fire) on keys 6-0 (`IN 61438`); upstream's "Sinclair1" is keys 1-5 and "Sinclair2" keys 6-0, and only B fires |
| CP/M paging | deferred to stage 4 | needs a CP/M disk |

## Findings

1. **The mouse wheel runs backwards.** MiSTer reads mice through `/dev/input/mice`
   (mousedev ImPS/2), which reports wheel up as a negative step, and hps_io passes that
   in `ps2_mouse_ext[7:0]`. The real board's MCU sends the USB HID wheel, where up is
   positive, and profi's `kg_cursor` (Z_NEG 0) adds it as is. Fix: `mcu_emu` negates the
   wheel delta (Task 9).
2. **The Kempston mouse starts at X = Y = 0, not 127.** On every fresh core load, with no
   mouse activity, #FBDF/#FFDF read 0 0 while the wheel nibble reads its start value 7.
   `kg_cursor` declares `x`/`y` as `output reg ... = 8'h7F`; the likely cause is that
   synthesis (Power-Up Don't Care is on) does not keep those power-up values. Kempston
   mouse software works from the position's changes, so this is left as it is.
3. **uinput mouse buttons do not reach the core** (a test-tool limitation, not the
   core): movement and wheel from the same virtual device do. Button checks need a real
   mouse.
