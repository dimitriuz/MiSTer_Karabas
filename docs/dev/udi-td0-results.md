# UDI and TD0 floppy images (2026-11-18)

The `F1`/`F2` entries (`Floppy A/B (raw)`) take three more kinds of
file. The header decides, so one entry does all of them.

## UDI: raw tracks

`UDI!` files hold each track as raw MFM bytes plus a bitmap of the bytes whose
clock is missing (sync marks). The drive plays them as they are:

- `fdd_src` parses the stream, writes each track's bytes and bitmap to the DDR
  window back to back, and tells the store each track's offset and length (the
  FDI table block: DataOffset, count, and the length in record 0).
- `fdd_store` has a new track kind (`K_UDI`, config kind 3): it copies the
  bytes into the 8192 x 9 track buffer, `{sync, byte}`, sync from the bitmap.
  It announces the length with `trk_len` next to the ack.
- `floppy.sv` turns the revolution into that length: the byte rate stays 16
  ticks, so a 6400-byte track is a 2.4 % longer turn (`/INDEX` period moves,
  nothing else). A marked C2 is the index-mark sync `5224`; every other marked
  byte is `4489`. In the real files the odd marks (0A, 14, 52) are mis-aligned
  sync leaders in front of `A1 A1 FE`, so `4489` keeps them readable.
- Rejected, never half-loaded: compressed `udi!`, a version other than 0,
  more than 84 cylinders, an extension header above 64 KiB. A track that is not
  type 0 (MFM), is empty, is over 8191 bytes or does not fit the 2 MiB window
  becomes an unformatted track. A UDI drive is write-protected (as an FDI
  drive is): a raw track has no sector table to write back to.

Survey of the 48 `.udi` files in zxart offline 0.6: all MFM; track lengths
6016..6400, 7000 in four files, 0 for unformatted extra cylinders; a type-13
comment record after the tracks in eleven (ignored). Marked bytes: A1 (all), C2
(index mark, 27 files), and 0A/14/52 in six protected disks.

## TD0: Teledisk

- `td0_lzh.sv` decodes the "td" advanced compression (Okumura's LZHUF, N=4096,
  F=60, no length word) with the adaptive Huffman tree in block RAMs; the
  hardware twin of `tools/td0.py`, bit-exact on a stress stream with three tree
  rebuilds (`sim/run_tb_td0_lzh.sh`).
- `fdd_src` parses the record stream as it arrives (comment block, track
  header, sector header, data block with methods 0 raw, 1 two-byte pattern,
  2 runs), stores each sector's bytes in the window and writes the FDI-style
  table (track DataOffset, count, one record per sector), so the store's FDI
  builder makes the track. Every table block is emptied first (the file lists
  only the tracks it has). Config: FDI kind, 84 tracks.
- A sector flagged "no data" (0x10/0x20) or with a size code above 6 becomes an
  ID-only record. Sectors of 2048 bytes and up keep their first 1024 bytes
  (the store's ceiling). Deleted-data marks and CRC-error flags are not
  reproduced: tracks are rebuilt as standard MFM.
- 677 of 693 files in `Karabas_Profi/floppy` are "td", 16 plain "TD". About
  2 % of the files in the three collections (`floppy`, `scorpion_cd.zip`, the
  zxart TD0s) do not parse: the decompressed stream turns to garbage mid-way,
  identically in this decoder and in the independent Rust `retrocompressor`
  (checked byte for byte on ten files, including a failing one), so the file
  itself is damaged. The core refuses such a file (no ready) and the drive
  keeps its image.
- Validation of the model: on 66 572 sectors of real files, the data CRC byte
  matches after decompression and expansion for 66 566; every expanded sector
  has exactly its declared size (95 988 sectors).

## SCL: Sinclair archives

Main converts `.scl` (and `.fdi`, `.udi`) picked under the `(TRD)` rows to a TRD
itself, with a plain `open()` of the path, so a file inside a zip yields an empty
image and TR-DOS reports a disc error (MiSTer's `x2trd`; not a core fault). The
`(raw)` rows stream the file through Main's zip-aware loader instead, so they now
take `.scl` as well: `fdd_src` (`P_SCL`) builds the TRD in the window. The
catalog area (4 KiB) is cleared first, each 14-byte entry goes to `entry * 16`
with its first sector and track made up from the running sector count, the ID
sector gets first free sector/track, disk type 0x16, file count, free sectors and
the TR-DOS signature, and the file sectors follow from 0x1000. The 32-bit sum at
the end is not checked. Config: TRD kind, 80 cylinders, two sides; protected like
the other raw formats. More than 128 files, or more sectors than an 80-cylinder
disk holds, is refused (no ready). Reference: `tools/scl.py`; bench:
`sim/run_tb_fdd_scl.sh` (byte-exact window of a three-file image, stale catalog
cleared, both refusals; two mutants caught).

## Verification

| What | Result |
|---|---|
| `python3 -m unittest discover -s tools/tests` | 145 tests OK |
| `sim/run_tb_td0_lzh.sh` | decoder bit-exact on 19 537 bytes, tree rebuilt 3 times |
| `sim/run_tb_fdd_img.sh` | PASS: `udi_download` (A: 6250 and 6290-byte tracks; B: one side, extension, empty and short track; the store announces each length, mutant without the marks fails), `td0_download` (compressed and plain, comment, every sector shape, stale table blocks emptied) |
| `sim/run_tb_floppy_raw.sh` | PASS: period = length x 16 ticks for 6400/6250/6016, exactly one `5224`, `4489` present |
| `sim/run_tb_floppy.sh` | PASS, six speed/CPU combinations (73 min) with the variable revolution |
| Build 90 (seed 7) | `check_timing` OK with the SDRAM pin constraints (read path +1.215 ns, docs/dev/sdram-timing.md); boots; hotkeys, renamed rows; an SCL (loose and inside a zip) streamed through `Floppy A (raw)` runs its auto-run program under TR-DOS |
| Build 83 (seed 3) | `check_timing` OK, worst setup slack **+0.173 ns** (HDMI PLL domain); 81 % ALMs, 398 of 553 RAM blocks; boots |
| Board, standard TR-DOS UDI | `boot` runs: The Dizzy Editor loads |
| Board, UDI with 6400-byte tracks (a STEP demo) | runs the whole intro; the same disk converted to a sector TRD falls back to BASIC |
| Board, TD0 "td" and plain "TD" | boot programs run exactly as the TRD conversions of the same disks |
| Board, UDI without a TR-DOS format (two files) | TR-DOS "Disc Error Trk 0 sec 1 / 9", as for any non-TR-DOS disk |

Not covered: the protected UDI disks whose copy protection needs a real loader
(only boot and one demo were looked at), weak bits (a UDI cannot hold them),
TD0 CRC-error and deleted-mark sectors.
