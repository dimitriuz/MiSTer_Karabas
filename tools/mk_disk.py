"""mk_disk.py - the storage images the Karabas Profi's slots expect.

The SD slot (Z-Controller, DivMMC) wants an SD card image: an MBR and one
FAT16 partition. This writes one from scratch, with the two test files the
board run loads and saves.

The IDE slots want an HDF: plain 512-byte sectors, with sector 0 carrying
an Amiga RDB whose geometry hdf_ata takes at mount (cylinders, sectors per
track, heads; it falls back to 16/63 and the image's size when the RDB does
not fit CHS).

`ls` and `cat` read the VHD's partition back, so a write made on the board
can be checked on the PC without mtools.

CLI:
  mk_disk.py sd  OUT.vhd [--size-mb N]
  mk_disk.py hdf OUT.hdf [--sectors N]
  mk_disk.py ls  IMG.vhd
  mk_disk.py cat IMG.vhd NAME
"""
import argparse
import struct
import sys
from pathlib import Path

import zxtap

SECTOR = 512
SECTORS_PER_MB = 2048
PART_START = 2048
HEADS = 16
SPT = 63

LABEL = b"KARABAS SD "
FS_TYPE = b"FAT16   "
HDF_SIG = b"KARABAS HDF\n"


def _fat_sectors(part_sectors, spc, fats, root_sectors):
    """sectors per FAT: the smallest whose entries cover every cluster"""
    fat = 1
    for _ in range(64):
        clusters = (part_sectors - 1 - fats * fat - root_sectors) // spc
        need = -(-((clusters + 2) * 2) // SECTOR)
        if need <= fat:
            return fat
        fat = need
    raise ValueError("mk_disk: no FAT16 layout fits")


def _dir_entry(name, cluster, size, attr=0x20):
    base, _, ext = name.partition(".")
    entry = bytearray(32)
    entry[0:8] = base.encode("ascii").ljust(8)
    entry[8:11] = ext.encode("ascii").ljust(3)
    entry[11] = attr
    struct.pack_into("<H", entry, 24, 0x0021)  # 1980-01-01
    struct.pack_into("<H", entry, 26, cluster)
    struct.pack_into("<I", entry, 28, size)
    return entry


def sd_vhd(path, size_mb=16):
    """write a FAT16 VHD for the SD slot; returns None"""
    path = Path(path)
    total = size_mb * SECTORS_PER_MB
    part = total - PART_START
    spc = 4
    fats = 2
    root_entries = 512
    root_sectors = root_entries * 32 // SECTOR
    fat = _fat_sectors(part, spc, fats, root_sectors)
    cluster_bytes = spc * SECTOR
    clusters = (part - 1 - fats * fat - root_sectors) // spc

    files = [("TEST.TXT", b"sd ok\n"),
             ("TEST.BAS", zxtap.tokenize_program('10 PRINT "sd ok"'))]

    fat_image = bytearray(fat * SECTOR)
    struct.pack_into("<H", fat_image, 0, 0xFFF8)
    struct.pack_into("<H", fat_image, 2, 0xFFFF)

    root = bytearray(root_sectors * SECTOR)
    root[0:11] = LABEL
    root[11] = 0x08

    data = bytearray()
    cluster = 2
    for i, (name, content) in enumerate(files):
        count = max(1, -(-len(content) // cluster_bytes))
        for k in range(count):
            nxt = 0xFFFF if k == count - 1 else cluster + k + 1
            struct.pack_into("<H", fat_image, (cluster + k) * 2, nxt)
        data += content + bytes(count * cluster_bytes - len(content))
        root[(i + 1) * 32:(i + 2) * 32] = _dir_entry(name, cluster, len(content))
        cluster += count
    if cluster - 2 > clusters:
        raise ValueError(f"mk_disk: {size_mb} MiB is too small for the files")

    boot = bytearray(SECTOR)
    boot[0:3] = b"\xeb\x3c\x90"
    boot[3:11] = b"MSWIN4.1"
    struct.pack_into("<H", boot, 11, SECTOR)
    boot[13] = spc
    struct.pack_into("<H", boot, 14, 1)
    boot[16] = fats
    struct.pack_into("<H", boot, 17, root_entries)
    struct.pack_into("<H", boot, 19, part if part < 0x10000 else 0)
    boot[21] = 0xF8
    struct.pack_into("<H", boot, 22, fat)
    struct.pack_into("<H", boot, 24, SPT)
    struct.pack_into("<H", boot, 26, HEADS)
    struct.pack_into("<I", boot, 28, PART_START)
    struct.pack_into("<I", boot, 32, part)
    boot[36] = 0x80
    boot[38] = 0x29
    struct.pack_into("<I", boot, 39, 0x4B415241)
    boot[43:54] = LABEL
    boot[54:62] = FS_TYPE
    boot[510:512] = b"\x55\xaa"

    mbr = bytearray(SECTOR)
    entry = bytearray(16)
    entry[0] = 0x80
    entry[1:4] = b"\xfe\xff\xff"
    entry[4] = 0x06
    entry[5:8] = b"\xfe\xff\xff"
    struct.pack_into("<I", entry, 8, PART_START)
    struct.pack_into("<I", entry, 12, part)
    mbr[446:462] = entry
    mbr[510:512] = b"\x55\xaa"

    image = bytearray(total * SECTOR)
    image[0:SECTOR] = mbr
    off = PART_START * SECTOR
    image[off:off + SECTOR] = boot
    off += SECTOR
    image[off:off + len(fat_image)] = fat_image
    off += len(fat_image)
    image[off:off + len(fat_image)] = fat_image
    off += len(fat_image)
    image[off:off + len(root)] = root
    off += len(root)
    image[off:off + len(data)] = data
    _write(path, image)


def hdf(path, sectors=2048):
    """write an IDE image with an RDSK sector 0; returns None"""
    path = Path(path)
    cyl = sectors // (HEADS * SPT)
    if sectors < HEADS * SPT or cyl > 0xFFFF:
        raise ValueError(
            f"hdf: {sectors} sectors give {cyl} cylinders; at least "
            f"{HEADS * SPT} are needed for a geometry")
    image = bytearray(sectors * SECTOR)
    image[0:4] = b"RDSK"
    struct.pack_into(">I", image, 4, SECTOR)
    struct.pack_into(">I", image, 64, cyl)
    struct.pack_into(">I", image, 68, SPT)
    struct.pack_into(">I", image, 72, HEADS)
    image[SECTOR:SECTOR + len(HDF_SIG)] = HDF_SIG
    for i in range(len(HDF_SIG), SECTOR):
        image[SECTOR + i] = (i * 7 + 3) & 0xFF
    _write(path, image)


def _write(path, image):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(image)


def _layout(image):
    """partition start and the BPB fields the reader needs"""
    part_start = struct.unpack_from("<I", image, 446 + 8)[0]
    boot = image[part_start * SECTOR:(part_start + 1) * SECTOR]
    bpb = struct.unpack_from("<H", boot, 11)[0]
    spc = boot[13]
    reserved = struct.unpack_from("<H", boot, 14)[0]
    fats = boot[16]
    root_entries = struct.unpack_from("<H", boot, 17)[0]
    fat = struct.unpack_from("<H", boot, 22)[0]
    fat_off = (part_start + reserved) * SECTOR
    root_off = (part_start + reserved + fats * fat) * SECTOR
    data_off = root_off + root_entries * 32
    if bpb != SECTOR:
        raise ValueError(f"mk_disk: {bpb}-byte sectors are not supported")
    return root_entries, fat_off, root_off, data_off, spc


def _entries(image, root_entries, root_off):
    for i in range(root_entries):
        entry = image[root_off + i * 32:root_off + (i + 1) * 32]
        if entry[0] == 0x00:
            return
        if entry[0] == 0xE5 or entry[11] & 0x18 or entry[11] & 0x3F == 0x0F:
            continue
        name = entry[0:8].decode("ascii", "replace").rstrip()
        ext = entry[8:11].decode("ascii", "replace").rstrip()
        yield (name + ("." + ext if ext else ""),
               struct.unpack_from("<H", entry, 26)[0],
               struct.unpack_from("<I", entry, 28)[0])


def fat_list(path):
    """the VHD partition's files, in root-directory order"""
    image = Path(path).read_bytes()
    root_entries, _, root_off, _, _ = _layout(image)
    return [(name, size)
            for name, _, size in _entries(image, root_entries, root_off)]


def fat_read(path, name):
    """one file of the VHD partition, exactly its directory size"""
    image = Path(path).read_bytes()
    root_entries, fat_off, root_off, data_off, spc = _layout(image)
    want = name.upper()
    for entry_name, cluster, size in _entries(image, root_entries, root_off):
        if entry_name != want:
            continue
        out = bytearray()
        while len(out) < size and 2 <= cluster < 0xFFF8:
            off = data_off + (cluster - 2) * spc * SECTOR
            out += image[off:off + spc * SECTOR]
            cluster = struct.unpack_from("<H", image, fat_off + cluster * 2)[0]
        if len(out) < size:
            raise ValueError(f"mk_disk: {name}: short cluster chain")
        return bytes(out[:size])
    raise KeyError(name)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="mk_disk.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sd = sub.add_parser("sd", help="write a FAT16 VHD for the SD slot")
    sd.add_argument("path")
    sd.add_argument("--size-mb", type=int, default=16)
    hd = sub.add_parser("hdf", help="write an RDSK HDF for an IDE slot")
    hd.add_argument("path")
    hd.add_argument("--sectors", type=int, default=2048)
    ls = sub.add_parser("ls", help="list a VHD's partition")
    ls.add_argument("path")
    cat = sub.add_parser("cat", help="write one VHD file to stdout")
    cat.add_argument("path")
    cat.add_argument("name")
    args = parser.parse_args(argv)

    if args.cmd == "sd":
        sd_vhd(args.path, args.size_mb)
        print(args.path)
    elif args.cmd == "hdf":
        hdf(args.path, args.sectors)
        print(args.path)
    elif args.cmd == "ls":
        for name, size in fat_list(args.path):
            print(f"{size:8d}  {name}")
    else:
        try:
            data = fat_read(args.path, args.name)
        except KeyError:
            print(f"mk_disk.py: {args.name}: no such file", file=sys.stderr)
            return 1
        sys.stdout.buffer.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())