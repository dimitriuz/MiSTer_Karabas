# SD card on the board (2026-11-18)

The owner reported that SD images do not work: a mounted `.vhd` either keeps
the Karabas GO loader on its logo (SD icon lit, no menu) or hangs the file
manager boot, and the file explorer says the SD card failed. Tried:
`tests/blank.vhd`, `emptyroot.vhd`, `test.vhd` (the FAT16 images of stage 4b)
and TSConf's `vhd-example.vhd` (FAT16, 500 MB).

Two independent causes.

## 1. The hang: the card sampled sck on the wrong clock (fixed, build 78)

`sd_card`'s `clk_spi` was `clk_sys` (50 MHz), while the machine's `zc_spi`
makes sck, mosi and its miso sampling from `clk_bus` (28.125 MHz, sck at
14 MHz). The card sampled an unsynchronised 14 MHz clock at 50 MHz.

Measured with a BASIC program on the Z-Controller ports (`sdp.trd`, CS held
low, CMD0/8/55/41/58/17 and twelve reads each; the card mounted 90 s after the
core start by the MGL's `delay` so the loader's own probe was out of the way):

| command | expected | board, `clk_spi = clk_sys` |
|---|---|---|
| CMD0 | R1 01 | 01 (fine) |
| CMD8 | R1 01, then 00 00 01 AA | 01, then 00 00 00 3A AF; 00 00 00 D5 7F; or no tail at all (three runs, three answers) |
| CMD55 (second one) | 01 | 04 7F (an illegal command: the command byte itself was misread) |
| CMD58 | R1 00, then C0 00 00 00 | right, with a stray 07 after it |

The wrong tails are the right bit stream with bits repeated, which is what a
card that misses some sck edges produces. The bench (`sim/tb_sd_spi.sv`,
`async_host`) never showed it: it checks only the R1 of the init commands, and a
simulator with ideal clocks reads intact with the card on either clock, with
any wire delay and per-edge random jitter (tried, `sim/tb_sd_zc.sv` history).
So the cause is inferred from the symptom and the clocking, not reproduced in
simulation.

Fix (`Karabas_Profi.sv`): `.clk_spi(clk_bus)`, and the card's `sd_rd`/`sd_wr`
cross to `clk_sys` through two flops. `sim/tb_sd_zc.sv` is the real `zc_spi`
against the card on that clocking: init with the R7 and OCR tails, a CS
toggle, and a CMD17 sector.

Result on the board (build 78, the same images): the loader reaches its menu
every time, and with a FAT32 image the status line reads `Drive: SD`.
`Loading boot` on `karabas.img` opens the file manager with `E:ZC SDC:FAT32`
and lists `KARABA~1.$C` and `ISDOSHDD.$C` from the card.

## 2. "SD card failed" on FAT16 images: the ROM takes FAT32 only (not a core fault)

Two 128 MB images with the same MBR layout and one file, made with
`mkfs.fat -F 16` and `-F 32`: the FAT16 image leaves the loader on
`Drive: CF` (and `Loading boot` says `Initialize CF... Failed`), the FAT32
image gives `Drive: SD`. `karabas.img` (the image pico-speccy uses) is FAT32
too. The two checks the ROM makes are separate, found by crossing the
partition type byte with the filesystem (same image, one byte changed):

| filesystem | partition type | status line | `Loading boot` with `karabas_boot.$c` on the card |
|---|---|---|---|
| FAT16 | 0x06 | `Drive: CF` | not reached |
| FAT16 | 0x0C | `Drive: SD` | back to the menu, nothing loaded |
| FAT32 | 0x06 | `Drive: CF` | not reached |
| FAT32 | 0x0C | `Drive: SD` | file manager opens, `E:ZC SDC:FAT32`, lists both files |

So the loader decides "an SD card is present" from the MBR's partition type
(0x0B/0x0C), and its FAT driver (FATALL v0.26, labelled `SDC:FAT32`) reads
FAT32 volumes only. Changing the type byte of a FAT16 image makes the card
show but does not make its files readable. Why the ROM's authors chose
FAT32 only is not in the repository (the ROM is a binary; its only FAT
string is `FAT32`): the Karabas Go uses SDHC cards, which are FAT32.
The three FAT16 VHDs the owner tried cannot work with this ROM whatever
the core does; they need a FAT32 volume in a type 0x0B/0x0C partition.

## Builds

| build | what | result |
|---|---|---|
| 77 | the clock fix and the regrouped OSD, SEED 1 | `check_timing: FAIL`, -0.420 ns setup on `pll_hdmi` (the HDMI PLL's counter clock); the RBF showed a striped picture and did not boot, with or without an image |
| 78 | the same sources, SEED 2 | `build: exit 0`, `check_timing: OK`, worst setup slack +0.370 ns; boots |

## Not verified

- The regrouped OSD on screen: the HDMI capture card was in use, so the new
  row order is checked only by the `CONF_STR` parse in `test_board_drive.py`.
  `mister.ROWS`/`zx.TAPE_ROW` (now 9) and the pixel arithmetic
  `(top - 174)/16` have not been re-read from a capture.
- Writing to the card (CMD24) and a multi-sector read through the ROM's own
  driver beyond the file manager's listing.
- DivMMC/esxDOS on the SD card.
