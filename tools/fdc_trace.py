#!/usr/bin/env python3
"""Decode the FDC trace the core sends out of the HPS UART (rtl/host/fdc_trace.sv).

On the board (OSD `Serial channel` is forced to USB while `FDC trace to UART` is On):

    ssh root@<board> 'stty -F /dev/ttyS1 115200 raw -echo; timeout 120 cat /dev/ttyS1' | python3 tools/fdc_trace.py

Records are three bytes: b0 = 0x80 | kind<<3 | ff<<2 | reg, then data hi, lo. kind 0 is a write
(reg 0 command, 1 track, 2 sector, 3 data; ff = the system port #FF), kind 1 a status read,
kind 2 a summary of a run of data reads (count, first four bytes, last byte). Bytes that are not a b0 are skipped to resync.
Also reads a file or `-` (stdin); `--hex` prints the raw bytes next to each record.
"""
import sys

CMDS = {0x0: "RESTORE", 0x1: "SEEK", 0x2: "STEP", 0x3: "STEP", 0x4: "STEP_IN", 0x5: "STEP_IN",
        0x6: "STEP_OUT", 0x7: "STEP_OUT", 0x8: "RDSEC", 0x9: "RDSEC_M", 0xA: "WRSEC", 0xB: "WRSEC_M",
        0xC: "RDADDR", 0xD: "FORCE_INT", 0xE: "RDTRK", 0xF: "WRTRK"}
REGS = ["CMD", "TRK", "SEC", "DAT"]


def sys_text(v):
    return "drv=%d %s hlt=%d side=%d" % (v & 3, "run" if v & 4 else "RESET", (v >> 3) & 1,
                                         0 if v & 0x10 else 1)


def status_text(v):
    bits = ["BUSY", "DRQ/IDX", "TR00/LOST", "CRC", "RNF/SEEKERR", "HLD/RECTYPE", "WPRT", "NOTRDY"]
    return " ".join(n for i, n in enumerate(bits) if v & (1 << i)) or "-"


def decode(data, raw=False):
    out, i, n = [], 0, 0
    while i + 2 < len(data):
        b0, hi, lo = data[i], data[i + 1], data[i + 2]
        if not b0 & 0x80:
            i += 1
            continue
        kind, ff, reg = (b0 >> 3) & 3, (b0 >> 2) & 1, b0 & 3
        n += 1
        if kind == 1:
            text = "status %02X  %s" % (lo, status_text(lo))
        elif kind == 2:
            text = ["data burst: %d reads" % ((hi << 8) | lo),
                    "  first bytes %02X %02X" % (hi, lo),
                    "  then        %02X %02X" % (hi, lo),
                    "  last byte   %02X" % hi][reg]
        elif ff:
            text = "SYS    %02X  %s" % (lo, sys_text(lo))
        elif reg == 0:
            text = "CMD    %02X  %s" % (lo, CMDS[lo >> 4])
        else:
            text = "%s    %02X" % (REGS[reg], lo)
        out.append("%4d  %s%s" % (n, text, ("   [%02X %02X %02X]" % (b0, hi, lo)) if raw else ""))
        i += 3
    return out


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--hex"]
    src = sys.stdin.buffer if not args or args[0] == "-" else open(args[0], "rb")
    print("\n".join(decode(src.read(), "--hex" in sys.argv)))
