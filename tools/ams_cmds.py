#!/usr/bin/env python3
"""Fixtures for sim/tb_fdd_ams.sv: replay of a PicoSpeccy WD1793 trace against an FDI.

usage: ams_cmds.py TRACE FDI OUTDIR [KEEP_BYTES]

TRACE is a PicoSpeccy FDD_PORT_TRACE excerpt ([FDC SYS] / [FDC CMD] lines, see
sim/data/ams_loader.trace). Writes into OUTDIR:
  dl.hex    the FDI, truncated to its header + table + KEEP_BYTES of data (one byte per line)
  cmds.hex  two 32-bit words per trace line: {op,cmd,trk,sec} {dat,0,expidx}
            op 1 = write #FF, 2 = a command (registers loaded first), 3 = RDSEC (expected data)
  exp.hex   the sectors every RDSEC must return, 1024 bytes each (shorter ones padded with 0)
"""
import re, struct, sys
from pathlib import Path

trace, fdi, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
keep = int(sys.argv[4]) if len(sys.argv) > 4 else 0x8000
out.mkdir(parents=True, exist_ok=True)
d = fdi.read_bytes()
cyl, heads, to, do, xl = struct.unpack('<HHHHH', d[4:14])
p = 14 + xl
tracks = []
for t in range(cyl * heads):
    tof = struct.unpack('<I', d[p:p + 4])[0]; spt = d[p + 6]; p += 7
    secs = []
    for i in range(spt):
        c, h, r, n, fl, so = struct.unpack('<BBBBBH', d[p:p + 7]); p += 7
        secs.append((c, h, r, n, do + tof + so))
    tracks.append(secs)

cut = d[:do + keep]
(out / 'dl.hex').write_text('\n'.join(f'{b:02x}' for b in cut) + '\n')

words, exp = [], bytearray()
side, phys = 0, 0
nrd = 0
for line in trace.read_text().splitlines():
    m = re.match(r'\[FDC SYS\] data=([0-9A-F]+)', line)
    if m:
        v = int(m.group(1), 16)
        side = 0 if v & 0x10 else 1
        words += [(1 << 24) | (v << 16), 0]
        continue
    m = re.match(r'\[FDC CMD\] ([0-9A-F]{2}) (\S+)\s+trk=(\d+) sec=(\d+) side=\d+ dataReg=(\d+)', line)
    if not m:
        continue
    cmd, name, trk, sec, dat = int(m.group(1), 16), m.group(2), int(m.group(3)), int(m.group(4)), int(m.group(5))
    if name == 'RESTORE':
        phys = 0
    elif name == 'SEEK':
        phys += dat - trk
    op, idx = 2, 0
    if name == 'RDSEC':
        t = tracks[phys * heads + side]
        hit = [s for s in t if s[0] == trk and s[2] == sec]
        assert hit, f'{line}: no sector in the FDI'
        c, h, r, n, a = hit[0]
        data = d[a:a + (128 << n)]
        assert a + len(data) <= do + keep, f'{line}: its data is past KEEP_BYTES'
        op, idx = 3, nrd
        exp += data.ljust(1024, b'\0'); nrd += 1
    words += [(op << 24) | (cmd << 16) | (trk << 8) | sec, (dat << 24) | idx]
(out / 'cmds.hex').write_text('\n'.join(f'{w:08x}' for w in words) + '\n')
(out / 'exp.hex').write_text('\n'.join(f'{b:02x}' for b in exp) + '\n')
print(f'{len(words) // 2} entries, {nrd} sector reads, {len(cut)} FDI bytes')
