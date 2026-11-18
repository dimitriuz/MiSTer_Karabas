"""mk_disk.py - the storage images the Karabas Profi's slots expect.

The SD slot (Z-Controller, DivMMC) wants an SD card image: an MBR and one
FAT partition. `sd` writes a FAT16 one from scratch, with the two test files
the board run loads and saves. The Karabas ROM's SD driver reads FAT32 only
(ROMain 2.83 "FAT32 partition detection"; a FAT16 card is not even taken as
a card - docs/dev/sd-card-results.md), so `sd32` writes the image the ROM
takes: an MBR, one type 0x0C FAT32 partition, long file names.

The IDE slots want an HDF: plain 512-byte sectors, with sector 0 carrying
an Amiga RDB whose geometry hdf_ata takes at mount (cylinders, sectors per
track, heads; it falls back to 16/63 and the image's size when the RDB does
not fit CHS).

`ls` and `cat` read the VHD's partition back, so a write made on the board
can be checked on the PC without mtools.

The floppy tasks add the VG93 images: a TR-DOS `.trd` writer plus the
catalog reader the board write verification uses, a raw CP/M drive, an
FDI writer, and `reftrack`, the byte-exact reference track (hex plus
sync flags) the FDD track-builder bench compares against.

CLI:
  mk_disk.py sd        OUT.vhd [--size-mb N]
  mk_disk.py sd32      OUT.vhd [--size-mb N] [--label L] [--file SRC[=NAME]]...
  mk_disk.py hdf       OUT.hdf [--sectors N]
  mk_disk.py trd       OUT.trd [--tracks N] [--boot]
  mk_disk.py cpm       OUT.cpm [--tracks N]
  mk_disk.py fdi       OUT.fdi [--layout trd|wide]
  mk_disk.py reffrom   OUT --image IMG --kind trd|cpm|fdi --track T --side S
  mk_disk.py fdistream OUT --image IMG T:S [T:S ...]
  mk_disk.py ls        IMG        (VHD partition or TRD catalog)
  mk_disk.py cat       IMG NAME
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

BOOT_SRC = (
    '10 PRINT "trdos ok"\n'
    '20 FOR I=0 TO 255: POKE 25000+I,I: NEXT I\n'
    '30 RANDOMIZE USR 15619: REM : SAVE "out" CODE 25000,256\n'
    '40 PRINT "saved"\n'
)


def boot_program() -> bytes:
    """BOOT_SRC as program bytes. Line 30's command sits in a REM, where
    TR-DOS wants *keyword tokens* (SAVE f8, CODE af); USR 15619 runs the REM command and returns to BASIC (15616 opens the shell and never returns) and plain digits, so
    that one line is built by hand; zxtap tokenises a REM body as text. A
    plain BASIC `SAVE` goes to the tape, not the disk."""
    lines = [zxtap.tokenize_line(raw) for raw in BOOT_SRC.splitlines()
             if raw[:2] != "30"]
    body = b"\xf9\xc015619\x0e\x00\x00\x03\x3d\x00:\xea:\xf8\"out\"\xaf25000,256\r"
    line30 = bytes([0, 30]) + struct.pack("<H", len(body)) + body
    lines.insert(2, line30)
    return b"".join(lines)


DISK_NAME = b"MiSTer"
TRD_SEC = 256
CPM_TRACK = 2 * 5 * 1024  # one track, both sides
TRACK_BYTES = 6250


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

SFN_OK = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'()-@^_`{}~")


def _short_name(name, taken):
    """(8.3 name, needs_lfn): the name as stored in the entry itself.

    A name that is already an upper-case 8.3 name is stored as it is; any
    other gets a long-name entry and a generated short name (the first six
    characters, ~N, the first three of the extension) like the usual
    formatters make, so `karabas_boot.$c` is `KARABA~1.$C`.
    """
    stem, dot, ext = name.rpartition(".")
    if not dot:
        stem, ext = name, ""
    exact = (name == name.upper() and 0 < len(stem) <= 8 and len(ext) <= 3
             and all(c in SFN_OK for c in stem + ext)
             and (stem + "." + ext if dot else stem) == name)
    if exact:
        return stem.ljust(8) + ext.ljust(3), False
    base = "".join(c for c in stem.upper() if c in SFN_OK)[:6] or "FILE"
    tail = "".join(c for c in ext.upper() if c in SFN_OK)[:3]
    for n in range(1, 1000000):
        suffix = "~%d" % n
        short = (base[:8 - len(suffix)] + suffix).ljust(8) + tail.ljust(3)
        if short not in taken:
            return short, True
    raise ValueError("mk_disk: no short name for " + name)


def _lfn_checksum(short):
    total = 0
    for b in short.encode("ascii"):
        total = (((total & 1) << 7) | (total >> 1)) + b & 0xFF
    return total


def _lfn_entries(name, short):
    """the long-name directory entries of `name`, last part first"""
    units = list(name.encode("utf-16-le"))
    chars = [units[i] | units[i + 1] << 8 for i in range(0, len(units), 2)]
    chars.append(0x0000)
    chars += [0xFFFF] * (-len(chars) % 13)
    check = _lfn_checksum(short)
    parts = [chars[i:i + 13] for i in range(0, len(chars), 13)]
    out = []
    for index, part in enumerate(parts, 1):
        entry = bytearray(32)
        entry[0] = index | (0x40 if index == len(parts) else 0)
        entry[11] = 0x0F
        entry[13] = check
        for slot, ch in zip((1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30),
                            part):
            struct.pack_into("<H", entry, slot, ch)
        out.append(entry)
    return out[::-1]


def sd_vhd32(path, size_mb=256, files=(), label="KARABAS"):
    """write a FAT32 image for the SD slot: an MBR, one type 0x0C partition
    from sector 2048, 32 reserved sectors (FSInfo at 1, the boot copy at 6),
    two FATs, the root directory in cluster 2. `files` are (name, bytes);
    names that are not upper-case 8.3 get long-name entries. The image is
    written sparse, so a 256 MiB card does not cost 256 MiB of memory."""
    path = Path(path)
    total = size_mb * SECTORS_PER_MB
    part = total - PART_START
    reserved, fats = 32, 2
    spc = None
    for candidate in (8, 4, 2, 1):
        if (part - reserved) // candidate >= 65525 + 64:
            spc = candidate
            break
    if spc is None:
        raise ValueError(f"mk_disk: {size_mb} MiB is too small for FAT32")
    fat = 1
    for _ in range(64):
        clusters = (part - reserved - fats * fat) // spc
        need = -(-((clusters + 2) * 4) // SECTOR)
        if need <= fat:
            break
        fat = need
    cluster_bytes = spc * SECTOR
    label = label.upper().ljust(11)[:11]

    fat_image = bytearray(fat * SECTOR)
    struct.pack_into("<I", fat_image, 0, 0x0FFFFFF8)
    struct.pack_into("<I", fat_image, 4, 0x0FFFFFFF)
    struct.pack_into("<I", fat_image, 8, 0x0FFFFFFF)     # the root directory

    root = bytearray()
    entry = bytearray(32)
    entry[0:11] = label.encode("ascii")
    entry[11] = 0x08
    root += entry
    chunks = []                      # (first cluster, bytes)
    cluster = 3
    taken = set()
    for name, content in files:
        short, lfn = _short_name(name, taken)
        taken.add(short)
        if lfn:
            for part_entry in _lfn_entries(name, short):
                root += part_entry
        count = -(-len(content) // cluster_bytes) if content else 0
        first = cluster if count else 0
        for k in range(count):
            nxt = 0x0FFFFFFF if k == count - 1 else cluster + k + 1
            struct.pack_into("<I", fat_image, (cluster + k) * 4, nxt)
        if count:
            chunks.append((cluster, bytes(content)))
        entry = bytearray(32)
        entry[0:11] = short.encode("ascii")
        entry[11] = 0x20
        struct.pack_into("<H", entry, 16, 0x0021)         # created 1980-01-01
        struct.pack_into("<H", entry, 20, first >> 16)
        struct.pack_into("<H", entry, 24, 0x0021)
        struct.pack_into("<H", entry, 26, first & 0xFFFF)
        struct.pack_into("<I", entry, 28, len(content))
        root += entry
        cluster += count
    if cluster - 3 > (part - reserved - fats * fat) // spc - 1:
        raise ValueError(f"mk_disk: {size_mb} MiB is too small for the files")
    if len(root) > cluster_bytes:
        raise ValueError("mk_disk: the root directory outgrew one cluster")
    root += bytes(cluster_bytes - len(root))
    free = (part - reserved - fats * fat) // spc - (cluster - 2)

    boot = bytearray(SECTOR)
    boot[0:3] = b"\xeb\x58\x90"
    boot[3:11] = b"MSWIN4.1"
    struct.pack_into("<H", boot, 11, SECTOR)
    boot[13] = spc
    struct.pack_into("<H", boot, 14, reserved)
    boot[16] = fats
    boot[21] = 0xF8
    struct.pack_into("<H", boot, 24, SPT)
    struct.pack_into("<H", boot, 26, HEADS)
    struct.pack_into("<I", boot, 28, PART_START)
    struct.pack_into("<I", boot, 32, part)
    struct.pack_into("<I", boot, 36, fat)
    struct.pack_into("<I", boot, 44, 2)                   # root cluster
    struct.pack_into("<H", boot, 48, 1)                   # FSInfo
    struct.pack_into("<H", boot, 50, 6)                   # boot sector copy
    boot[64] = 0x80
    boot[66] = 0x29
    struct.pack_into("<I", boot, 67, 0x4B415241)
    boot[71:82] = label.encode("ascii")
    boot[82:90] = b"FAT32   "
    boot[510:512] = b"\x55\xaa"

    info = bytearray(SECTOR)
    struct.pack_into("<I", info, 0, 0x41615252)
    struct.pack_into("<I", info, 484, 0x61417272)
    struct.pack_into("<I", info, 488, free)
    struct.pack_into("<I", info, 492, cluster)
    struct.pack_into("<I", info, 508, 0xAA550000)

    mbr = bytearray(SECTOR)
    entry = bytearray(16)
    entry[0] = 0x80
    entry[1:4] = b"\xfe\xff\xff"
    entry[4] = 0x0C
    entry[5:8] = b"\xfe\xff\xff"
    struct.pack_into("<I", entry, 8, PART_START)
    struct.pack_into("<I", entry, 12, part)
    mbr[446:462] = entry
    mbr[510:512] = b"\x55\xaa"

    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.truncate(total * SECTOR)

        def put(sector, data):
            f.seek(sector * SECTOR)
            f.write(data)

        base = PART_START
        put(0, mbr)
        put(base, boot)
        put(base + 1, info)
        put(base + 6, boot)
        put(base + 7, info)
        put(base + reserved, fat_image)
        put(base + reserved + fat, fat_image)
        data0 = base + reserved + fats * fat
        put(data0, root)
        for first, content in chunks:
            put(data0 + (first - 2) * spc, content)



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


def _is_fat32(image):
    part_start = struct.unpack_from("<I", image, 446 + 8)[0]
    boot = image[part_start * SECTOR:(part_start + 1) * SECTOR]
    return (struct.unpack_from("<H", boot, 17)[0] == 0
            and struct.unpack_from("<H", boot, 22)[0] == 0)


def _fat32_walk(image):
    """(long_or_short_name, short_name, first_cluster, size, chain reader)
    of the root directory's files, and the data reader, for a FAT32 image"""
    part_start = struct.unpack_from("<I", image, 446 + 8)[0]
    base = part_start * SECTOR
    boot = image[base:base + SECTOR]
    if struct.unpack_from("<H", boot, 11)[0] != SECTOR:
        raise ValueError("mk_disk: only 512-byte sectors are supported")
    spc = boot[13]
    reserved = struct.unpack_from("<H", boot, 14)[0]
    fats = boot[16]
    fat = struct.unpack_from("<I", boot, 36)[0]
    root = struct.unpack_from("<I", boot, 44)[0]
    fat_off = base + reserved * SECTOR
    data_off = base + (reserved + fats * fat) * SECTOR

    def chain(cluster):
        while 2 <= cluster < 0x0FFFFFF8:
            yield cluster
            cluster = struct.unpack_from(
                "<I", image, fat_off + cluster * 4)[0] & 0x0FFFFFFF

    def cluster_bytes(cluster):
        off = data_off + (cluster - 2) * spc * SECTOR
        return image[off:off + spc * SECTOR]

    directory = b"".join(bytes(cluster_bytes(c)) for c in chain(root))
    longname = []
    entries = []
    for i in range(0, len(directory), 32):
        entry = directory[i:i + 32]
        if entry[0] == 0x00:
            break
        if entry[0] == 0xE5:
            longname = []
            continue
        if entry[11] & 0x3F == 0x0F:
            chars = b"".join(entry[o:o + n] for o, n in
                             ((1, 10), (14, 12), (28, 4)))
            longname.insert(0, chars.decode("utf-16-le"))
            continue
        if entry[11] & 0x18:
            longname = []
            continue
        short = (entry[0:8].decode("ascii", "replace").rstrip()
                 + ("." + entry[8:11].decode("ascii", "replace").rstrip()
                    if entry[8:11].strip() else ""))
        name = "".join(longname).split("\x00")[0].split("\uffff")[0] or short
        longname = []
        cluster = (struct.unpack_from("<H", entry, 20)[0] << 16
                   | struct.unpack_from("<H", entry, 26)[0])
        entries.append((name, short, cluster,
                        struct.unpack_from("<I", entry, 28)[0]))

    def read(cluster, size):
        out = bytearray()
        for c in chain(cluster):
            out += cluster_bytes(c)
            if len(out) >= size:
                break
        if len(out) < size:
            raise ValueError("mk_disk: short cluster chain")
        return bytes(out[:size])

    return entries, read


def fat_list(path):
    """the VHD partition's files, in root-directory order (a FAT32 image
    lists the long name where a file has one)"""
    image = Path(path).read_bytes()
    if _is_fat32(image):
        entries, _ = _fat32_walk(image)
        return [(name, size) for name, _, _, size in entries]
    root_entries, _, root_off, _, _ = _layout(image)
    return [(name, size)
            for name, _, size in _entries(image, root_entries, root_off)]


def fat_read(path, name):
    """one file of the VHD partition, exactly its directory size"""
    image = Path(path).read_bytes()
    if _is_fat32(image):
        entries, read = _fat32_walk(image)
        for long, short, cluster, size in entries:
            if name.lower() in (long.lower(), short.lower()):
                return read(cluster, size) if size else b""
        raise KeyError(name)
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


def trd(path, tracks=80, files=None):
    """write a TR-DOS image; `files` defaults to the auto-run boot program

    TR-DOS numbering is flat: logical track = cylinder * 2 + side, file
    offset = (logical track * 16 + 0-based sector) * 256. Logical track
    0 holds the catalog in (1-based) sectors 1-8 and the ID sector 9;
    file data starts at logical track 1, sector 0 (file offset 16 *
    256), allocated sector by sector across track bounds.
    """
    path = Path(path)
    if files is None:
        files = [("boot", "B", boot_program())]
    image = bytearray(tracks * 2 * 16 * TRD_SEC)
    if len(files) > 128:
        raise ValueError(f"mk_disk: {len(files)} files do not fit the catalog")
    alloc = 0
    room = (tracks - 1) * 2 * 16
    for i, (name, ftype, payload) in enumerate(files):
        sectors = -(-len(payload) // TRD_SEC)
        if alloc + sectors > room:
            raise ValueError("mk_disk: no space left on the TRD image")
        entry = bytearray(16)
        entry[0:8] = name.encode("ascii").ljust(8)[:8]
        entry[8] = ord(ftype)
        # real TR-DOS entry: 9-10 start/param (a B file's program length),
        # 11-12 length, 13 sector count, 14 first sector, 15 first track
        struct.pack_into("<H", entry, 9, len(payload) if ftype == "B" else 0)
        struct.pack_into("<H", entry, 11, len(payload))
        entry[13] = sectors
        entry[14] = alloc % 16
        entry[15] = 1 + alloc // 16
        image[i * 16:(i + 1) * 16] = entry
        for k in range(sectors):
            off = (16 + alloc + k) * TRD_SEC
            image[off:off + TRD_SEC] = \
                payload[k * TRD_SEC:(k + 1) * TRD_SEC].ljust(TRD_SEC, b"\0")
        alloc += sectors

    idsec = 8 * TRD_SEC
    image[idsec + 0xE1] = alloc % 16
    image[idsec + 0xE2] = 1 + alloc // 16
    image[idsec + 0xE3] = 0x16
    image[idsec + 0xE4] = len(files)
    struct.pack_into("<H", image, idsec + 0xE5, tracks * 2 * 16 - 16)
    image[idsec + 0xE7] = 0x10
    image[idsec + 0xF4] = 0
    image[idsec + 0xF5:idsec + 0xFD] = DISK_NAME.ljust(8)[:8]
    _write(path, image)


def _trd_entries(image):
    """catalog entries in order: name, type, start, length, sectors

    The start is flat: logical track * 16 + the 0-based sector byte. A
    zero first byte ends the catalog, 0x01 is TR-DOS's deleted-entry
    marker."""
    for i in range(128):
        e = image[i * 16:(i + 1) * 16]
        if e[0] == 0x00:
            return
        if e[0] == 0x01:
            continue
        size = struct.unpack_from("<H", e, 11)[0]
        sectors = e[13]
        yield (e[0:8].decode("ascii", "replace").rstrip(), chr(e[8]),
               e[15] * 16 + e[14], size, sectors)


def trd_ls(path):
    """the catalog of a TRD image: (name, type, length bytes)"""
    image = Path(path).read_bytes()
    return [(name, ftype, size)
            for name, ftype, _, size, _ in _trd_entries(image)]


def trd_read(path, name):
    """one file of a TRD image, exactly its catalog length"""
    image = Path(path).read_bytes()
    want = name.lower()
    for entry, _, start, size, sectors in _trd_entries(image):
        if entry.lower() != want:
            continue
        count = sectors or -(-size // TRD_SEC)
        off = start * TRD_SEC
        data = image[off:off + count * TRD_SEC]
        if len(data) < size:
            raise ValueError(f"mk_disk: {name}: short file extents")
        return bytes(data[:size])
    raise KeyError(name)


def cpm(path, tracks=80):
    """write a raw CP/M drive: tracks*2*5*1024, per-track pattern

    No CP/M system: booting CP/M needs an owner-supplied image. Each
    track carries the pattern (i*7+3)&0xFF at its own offset i."""
    path = Path(path)
    track = bytes(((i * 7 + 3) & 0xFF) for i in range(CPM_TRACK))
    _write(path, bytearray(track * tracks))


def fdi(path, tracks=80, sides=2, layout="trd", source=None):
    """write an FDI image; its sector records really carry H = side

    Header: "FDI", version 0, u16 cyl, u16 sides, off_text, off_data,
    size_ext 0 (all LE). From 0x0E the track table runs, cylinder-major
    and side-minor: each 7-byte header (u32 DataOffset relative to
    off_data, u16 reserved 0, u8 sector count) is immediately followed
    by its 7-byte sector records C,H,R,N,flags,u16 offset (relative to
    the track's data; sector size 128 << N). The data area from
    off_data holds only the payloads, track after track; a flags 0x40
    ("no data") sector has none. `trd`: 16 x 256. `wide`: cylinder 0
    is 8 x 512 plus one 0x40 sector, the rest 16 x 256. With `source` (a
    TRD path, `trd` layout, 80 x 2 tracks) the sector payloads are the TRD's
    bytes, so the FDI is a real TR-DOS disk (cylinder t side s sector r is
    logical track 2t+s, sector r-1)."""
    path = Path(path)
    src = Path(source).read_bytes() if source else None
    if src is not None and (layout != "trd" or len(src) != tracks * sides * 4096):
        raise ValueError("mk_disk: fdi source needs a trd layout and a full TRD")
    if layout not in ("trd", "wide"):
        raise ValueError(f"mk_disk: unknown FDI layout {layout!r}")
    blocks = []
    for t in range(tracks):
        for side in range(sides):
            if layout == "wide" and t == 0:
                specs = [(t, side, r, 2, 0) for r in range(1, 9)]
                specs.append((t, side, 9, 1, 0x40))
            else:
                specs = [(t, side, r, 1, 0) for r in range(1, 17)]
            blocks.append(specs)
    table_size = sum(7 + 7 * len(specs) for specs in blocks)
    off_data = 0x0E + table_size  # size_ext = 0, and no text follows
    if off_data > 0xFFFF:
        raise ValueError("mk_disk: too many tracks for the FDI header")
    header = bytearray(0x0E)
    header[0:3] = b"FDI"
    struct.pack_into("<H", header, 4, tracks)
    struct.pack_into("<H", header, 6, sides)
    struct.pack_into("<H", header, 8, off_data)
    struct.pack_into("<H", header, 0x0A, off_data)
    table = bytearray()
    data = bytearray()
    pos = 0
    for specs in blocks:
        table += struct.pack("<IHB", pos, 0, len(specs))
        track_data = bytearray()
        for (c, h, r, n, flags) in specs:
            table += struct.pack("<5BH", c, h, r, n, flags, len(track_data))
            if flags & 0x40:
                continue
            base = off_data + pos + len(track_data)
            if src is not None:
                o = ((c * 2 + h) * 16 + r - 1) * 256
                track_data += src[o:o + 256]
                continue
            track_data += bytes(((base + j) * 7 + 3) & 0xFF
                                for j in range(128 << n))
        data += track_data
        pos += len(track_data)
    _write(path, bytearray(header) + table + bytes(data))


def _ccitt(data):
    """the MFM record CRC: CCITT poly 0x1021, seed 0xFFFF, no reflection"""
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def reftrack(path, track, side, sectors, cpm=False, fdi=False):
    """write the reference track as hex (one byte per line) and <path>.sync

    Per sector: 10x4E, 12x00, 3xA1 + FE + C,H,R,N + CRC, 22x4E, 12x00,
    3xA1 + FB + data + CRC, 60x4E; CCITT-FFFF over the three A1s, the
    mark and the payload, high byte first (MakeVGCRC); padded with 4E
    to 6250. TR-DOS writes H = 0 on both sides, CP/M H = side, and for
    `fdi` the ID's H is the sector tuple's own. Sync flags are 1 at
    exactly the six A1 positions. `sectors` entries are (C, H, R, N,
    data); for the non-FDI kinds the ID record's H is `side` (CP/M) or 0
    (TR-DOS) and the tuple's H is ignored. A tuple with data=None is an
    FDI "no data" sector (flags 0x40): ID only, no data mark, and the
    trailing 4E gap follows the ID's CRC.
    """
    path = Path(path)
    image = bytearray()
    sync = []
    for (c, h, r, n, data) in sectors:
        idh = h if fdi else (side if cpm else 0)
        head = bytearray(b"\x4e" * 10 + b"\x00" * 12 + b"\xa1\xa1\xa1\xfe")
        head += bytes([c, idh, r, n])
        crc = _ccitt(bytes(head[-8:]))
        head += bytes([crc >> 8, crc & 0xFF])
        if data is None:
            image += head + b"\x4e" * 60
            sync += [0] * 22 + [1, 1, 1] + [0] * 7 + [0] * 60
            continue
        if len(data) != 128 << n:
            raise ValueError(f"mk_disk: reftrack: sector R{r} holds "
                             f"{len(data)} bytes, N = {n} means "
                             f"{128 << n}")
        body = bytearray(b"\x4e" * 22 + b"\x00" * 12 + b"\xa1\xa1\xa1\xfb")
        body += data
        crc = _ccitt(bytes(body[-(len(data) + 4):]))
        body += bytes([crc >> 8, crc & 0xFF])
        image += head + body + b"\x4e" * 60
        sync += ([0] * 22 + [1, 1, 1] + [0] * 7 + [0] * 22 + [0] * 12 +
                 [1, 1, 1] + [0] * (len(data) + 3) + [0] * 60)
    pad = TRACK_BYTES - len(image)
    if pad < 0:
        raise ValueError(f"mk_disk: reftrack: {len(image)} > {TRACK_BYTES}")
    image += b"\x4e" * pad
    sync += [0] * pad
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{b:02X}\n" for b in image))
    Path(str(path) + ".sync").write_text("".join(f"{s}\n" for s in sync))


def _ref_sectors(track, cpm):
    """the CLI reference track's sector contents"""
    count, n, size = (5, 3, 1024) if cpm else (16, 1, 256)
    return [(track, 0, r, n,
             bytes((((r - 1) * size + j) * 7 + 3) & 0xFF
                   for j in range(size)))
            for r in range(1, count + 1)]


def _fdi_walk(image):
    """(tracks, sides, off_data, blocks) of an FDI image

    blocks is the track table in its file order (cylinder-major, side-
    minor): each entry is (DataOffset, [(C, H, R, N, flags, offset), ...]).
    """
    tracks = struct.unpack_from("<H", image, 4)[0]
    sides = struct.unpack_from("<H", image, 6)[0]
    off_data = struct.unpack_from("<H", image, 0x0A)[0]
    pos = 0x0E
    blocks = []
    for _ in range(tracks * sides):
        data_off, _, count = struct.unpack_from("<IHB", image, pos)
        pos += 7
        secs = [struct.unpack_from("<5BH", image, pos + 7 * i)
                for i in range(count)]
        pos += 7 * count
        blocks.append((data_off, secs))
    return tracks, sides, off_data, blocks


def reffrom(path, image, track, side, kind):
    """the reference track of a real image: kind is trd, cpm or fdi

    The sector data are the image's own bytes at the offsets the drive's
    track builder reads, so the reference and the hardware see the very
    same contents (the CLI's pattern sectors only match a pattern image:
    a TRD track 0 carries the catalog, and CP/M's side 1 sits at an odd
    multiple of 5120 inside its two-side track block).
    """
    image = Path(image).read_bytes()
    if kind == "trd":
        lt = track * 2 + side
        sectors = [(track, 0, r, 1,
                    image[lt * 4096 + (r - 1) * 256: lt * 4096 + r * 256])
                   for r in range(1, 17)]
        reftrack(path, track, side, sectors)
    elif kind == "cpm":
        lt = track * 2 + side
        sectors = [(track, side, r, 3,
                    image[lt * 5120 + (r - 1) * 1024: lt * 5120 + r * 1024])
                   for r in range(1, 6)]
        reftrack(path, track, side, sectors, cpm=True)
    elif kind == "fdi":
        tracks, sides, off_data, blocks = _fdi_walk(image)
        data_off, secs = blocks[track * sides + side]
        sectors = []
        for (c, h, r, n, flags, off) in secs:
            if flags & 0x40:
                sectors.append((c, h, r, n, None))
            else:
                base = off_data + data_off + off
                sectors.append((c, h, r, n,
                                image[base: base + (128 << n)]))
        reftrack(path, track, side, sectors, fdi=True)
    else:
        raise ValueError(f"mk_disk: reffrom: unknown kind {kind!r}")


def fdistream(path, image, pairs):
    """the fill program of the store's table and data ports, for FDI images

    Lines of address and data (one hex value per line): the bytes a host
    fills a drive with — the table block of each requested (track, side)
    (header and sector records) and the data-area bytes of its sectors.
    The addresses are the store's table layout: bit 21 tags a table byte,
    bit 20 selects its header ({1, track, byte}) from its sector records
    ({0, track, sector, byte}); a data byte is addressed by its index in
    the data area. A flags-0x40 sector streams no data.
    """
    image = Path(image).read_bytes()
    tracks, sides, off_data, blocks = _fdi_walk(image)
    lines = []
    pos_table = 0x0E
    for idx, (data_off, secs) in enumerate(blocks):
        t, s = divmod(idx, sides)
        if (t, s) in pairs:
            for i in range(7 * (1 + len(secs))):
                b = i % 7
                rec = i // 7
                val = image[pos_table + i]
                if rec == 0:
                    if b == 5:               # the reserved u16's low half
                        continue
                    addr = 0x300000 | (idx << 3) | (4 if b == 6 else b)
                else:
                    addr = 0x200000 | (idx << 8) | ((rec - 1) << 3) | b
                lines.append((addr, val))
        pos_table += 7 + 7 * len(secs)
    for (t, s) in pairs:
        data_off, secs = blocks[t * sides + s]
        for (c, h, r, n, flags, off) in secs:
            if flags & 0x40:
                continue
            base = off_data + data_off + off
            for j in range(128 << n):
                lines.append((data_off + off + j, image[base + j]))
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text("".join(f"{a:08X}\n{b:02X}\n" for a, b in lines))


def main(argv=None):
    parser = argparse.ArgumentParser(prog="mk_disk.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sd = sub.add_parser("sd", help="write a FAT16 VHD for the SD slot")
    sd.add_argument("path")
    sd.add_argument("--size-mb", type=int, default=16)
    s32 = sub.add_parser("sd32", help="write a FAT32 image for the SD slot")
    s32.add_argument("path")
    s32.add_argument("--size-mb", type=int, default=256)
    s32.add_argument("--label", default="KARABAS")
    s32.add_argument("--file", action="append", default=[],
                     metavar="SRC[=NAME]",
                     help="put a file in the root (NAME defaults to SRC's)")
    hd = sub.add_parser("hdf", help="write an RDSK HDF for an IDE slot")
    hd.add_argument("path")
    hd.add_argument("--sectors", type=int, default=2048)
    tr = sub.add_parser("trd", help="write a TR-DOS image")
    tr.add_argument("path")
    tr.add_argument("--tracks", type=int, default=80)
    tr.add_argument("--boot", action="store_true",
                    help="include the auto-run boot program")
    cp = sub.add_parser("cpm", help="write a raw CP/M drive image")
    cp.add_argument("path")
    cp.add_argument("--tracks", type=int, default=80)
    fd = sub.add_parser("fdi", help="write an FDI image")
    fd.add_argument("path")
    fd.add_argument("--layout", choices=("trd", "wide"), default="trd")
    fd.add_argument("--from-trd", help="fill the sectors from a full TRD")
    rt = sub.add_parser("reftrack",
                        help="write a reference track and its sync file")
    rt.add_argument("path")
    rt.add_argument("--track", type=int, required=True)
    rt.add_argument("--side", type=int, required=True)
    rt.add_argument("--cpm", action="store_true")
    rf = sub.add_parser("reffrom",
                        help="reference track from a real image")
    rf.add_argument("path")
    rf.add_argument("--image", required=True)
    rf.add_argument("--kind", choices=("trd", "cpm", "fdi"), required=True)
    rf.add_argument("--track", type=int, required=True)
    rf.add_argument("--side", type=int, required=True)
    fs = sub.add_parser("fdistream",
                        help="the store fill program of an FDI image")
    fs.add_argument("path")
    fs.add_argument("--image", required=True)
    fs.add_argument("pairs", nargs="+", metavar="TRACK:SIDE")
    ls = sub.add_parser("ls", help="list a VHD partition or a TRD catalog")
    ls.add_argument("path")
    cat = sub.add_parser("cat", help="write one image file to stdout")
    cat.add_argument("path")
    cat.add_argument("name")
    args = parser.parse_args(argv)

    if args.cmd == "sd":
        sd_vhd(args.path, args.size_mb)
        print(args.path)
    elif args.cmd == "sd32":
        files = []
        for item in args.file:
            src, _, name = item.partition("=")
            files.append((name or Path(src).name, Path(src).read_bytes()))
        sd_vhd32(args.path, args.size_mb, files, args.label)
        print(args.path)
    elif args.cmd == "hdf":
        hdf(args.path, args.sectors)
        print(args.path)
    elif args.cmd == "trd":
        trd(args.path, args.tracks, [] if not args.boot else None)
        print(args.path)
    elif args.cmd == "cpm":
        cpm(args.path, args.tracks)
        print(args.path)
    elif args.cmd == "fdi":
        fdi(args.path, layout=args.layout, source=args.from_trd)
        print(args.path)
    elif args.cmd == "reftrack":
        reftrack(args.path, args.track, args.side,
                 _ref_sectors(args.track, args.cpm), cpm=args.cpm)
        print(args.path)
    elif args.cmd == "reffrom":
        reffrom(args.path, args.image, args.track, args.side, args.kind)
        print(args.path)
    elif args.cmd == "fdistream":
        pairs = [tuple(int(v) for v in p.split(":")) for p in args.pairs]
        fdistream(args.path, args.image, pairs)
        print(args.path)
    elif args.cmd == "ls":
        if Path(args.path).suffix == ".trd":
            for name, ftype, size in trd_ls(args.path):
                print(f"{size:8d}  {name}.{ftype}")
        else:
            for name, size in fat_list(args.path):
                print(f"{size:8d}  {name}")
    else:
        try:
            if Path(args.path).suffix == ".trd":
                data = trd_read(args.path, args.name)
            else:
                data = fat_read(args.path, args.name)
        except KeyError:
            print(f"mk_disk.py: {args.name}: no such file", file=sys.stderr)
            return 1
        sys.stdout.buffer.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())