"""Teledisk TD0: the reference decoder and parser (the model of the core's).

A TD0 file is a 12-byte header ("TD" plain, "td" advanced compression: the
rest of the file is then LZSS with an adaptive Huffman code, Okumura's
LZHUF without a length word) followed by an optional comment block and the
tracks. This module is what rtl/disk/td0_lzh.sv and fdd_src's TD0 phase are
checked against (tools/tests/test_td0.py, sim/run_tb_td0.sh).
"""
import struct

N, F, THRESHOLD = 4096, 60, 2
N_CHAR = 256 - THRESHOLD + F          # 314
T = N_CHAR * 2 - 1                    # 627
R = T - 1                             # 626
MAX_FREQ = 0x8000


def _tables():
    d_code, d_len, sym = [], [], 0
    for length, per, nsym in ((3, 32, 1), (4, 16, 3), (5, 8, 8),
                              (6, 4, 12), (7, 2, 24), (8, 1, 16)):
        for _ in range(nsym):
            d_code += [sym] * per
            d_len += [length] * per
            sym += 1
    assert len(d_code) == 256 and sym == 64
    return d_code, d_len


D_CODE, D_LEN = _tables()


class LzhDecoder:
    """the LZHUF decoder, one output byte at a time (no length word)"""

    def __init__(self, data):
        self.data = data
        self.pos = 0
        self.bitbuf = 0
        self.nbits = 0
        self.freq = [0] * (T + 1)
        self.prnt = [0] * (T + N_CHAR)
        self.son = [0] * T
        for i in range(N_CHAR):
            self.freq[i] = 1
            self.son[i] = i + T
            self.prnt[i + T] = i
        i, j = 0, N_CHAR
        while j <= R:
            self.freq[j] = self.freq[i] + self.freq[i + 1]
            self.son[j] = i
            self.prnt[i] = self.prnt[i + 1] = j
            i += 2
            j += 1
        self.freq[T] = 0xFFFF
        self.prnt[R] = 0
        self.buf = bytearray(b" " * (N - F)) + bytearray(F)
        self.r = N - F
        self.pending = []          # bytes of a copy not yet delivered

    def getbit(self):
        if self.nbits == 0:
            if self.pos >= len(self.data):
                raise EOFError
            self.bitbuf = self.data[self.pos]
            self.pos += 1
            self.nbits = 8
        self.nbits -= 1
        return (self.bitbuf >> self.nbits) & 1

    def getbyte(self):
        v = 0
        for _ in range(8):
            v = (v << 1) | self.getbit()
        return v

    def _reconstruct(self):
        freq, son, prnt = self.freq, self.son, self.prnt
        j = 0
        for i in range(T):
            if son[i] >= T:
                freq[j] = (freq[i] + 1) // 2
                son[j] = son[i]
                j += 1
        i, j = 0, N_CHAR
        while j < T:
            k = i + 1
            f = freq[j] = freq[i] + freq[k]
            k = j - 1
            while f < freq[k]:
                k -= 1
            k += 1
            freq[k + 1:j + 1] = freq[k:j]
            freq[k] = f
            son[k + 1:j + 1] = son[k:j]
            son[k] = i
            i += 2
            j += 1
        for i in range(T):
            k = son[i]
            if k >= T:
                prnt[k] = i
            else:
                prnt[k] = prnt[k + 1] = i

    def _update(self, c):
        freq, son, prnt = self.freq, self.son, self.prnt
        if freq[R] == MAX_FREQ:
            self._reconstruct()
        c = prnt[c + T]
        while True:
            freq[c] += 1
            k = freq[c]
            lidx = c + 1
            if k > freq[lidx]:
                lidx += 1
                while k > freq[lidx]:
                    lidx += 1
                lidx -= 1
                freq[c] = freq[lidx]
                freq[lidx] = k
                i = son[c]
                prnt[i] = lidx
                if i < T:
                    prnt[i + 1] = lidx
                j = son[lidx]
                son[lidx] = i
                prnt[j] = c
                if j < T:
                    prnt[j + 1] = c
                son[c] = j
                c = lidx
            c = prnt[c]
            if c == 0:
                break

    def _decode_char(self):
        c = self.son[R]
        while c < T:
            c = self.son[c + self.getbit()]
        c -= T
        self._update(c)
        return c

    def _decode_position(self):
        i = self.getbyte()
        c = D_CODE[i] << 6
        j = D_LEN[i] - 2
        while j > 0:
            i = (i << 1) + self.getbit()
            j -= 1
        return c | (i & 0x3F)

    def read(self, n):
        """up to n decoded bytes (fewer at the end of the input)"""
        out = bytearray()
        try:
            while len(out) < n:
                if self.pending:
                    out.append(self.pending.pop(0))
                    continue
                c = self._decode_char()
                if c < 256:
                    self.buf[self.r] = c
                    self.r = (self.r + 1) & (N - 1)
                    out.append(c)
                else:
                    i = (self.r - self._decode_position() - 1) & (N - 1)
                    j = c - 255 + THRESHOLD
                    for k in range(j):
                        c = self.buf[(i + k) & (N - 1)]
                        self.buf[self.r] = c
                        self.r = (self.r + 1) & (N - 1)
                        self.pending.append(c)
        except EOFError:
            pass
        return bytes(out)


def body(data):
    """the file's bytes after the header, decompressed when need be"""
    if data[:2] == b"td":
        d = LzhDecoder(data[12:])
        out = bytearray()
        while True:
            chunk = d.read(65536)
            out += chunk
            if len(chunk) < 65536:
                break
        return bytes(out)
    return data[12:]


def parse(data):
    """(header, tracks): tracks is a list of (cyl, head, [sector]); a sector
    is (cyl, head, sec, sizecode, flags, bytes or None)"""
    if data[:2] not in (b"TD", b"td"):
        raise ValueError("not a TD0 file")
    hdr = dict(seq=data[2], ver=data[4], rate=data[5], drive=data[6],
               step=data[7], dos=data[8], sides=data[9])
    b = body(data)
    o = 0
    if hdr["step"] & 0x80:                       # a comment block
        ln = struct.unpack_from("<H", b, 2)[0]
        o = 10 + ln
    tracks = []
    while o + 4 <= len(b):
        nsec, cyl, head = b[o], b[o + 1], b[o + 2]
        if nsec == 255:
            break
        o += 4
        secs = []
        for _ in range(nsec):
            c, h, s, sz, fl = b[o], b[o + 1], b[o + 2], b[o + 3], b[o + 4]
            o += 6
            payload = None
            if not fl & 0x30 and sz <= 6:        # a size code past 6 has no data block
                ln = struct.unpack_from("<H", b, o)[0]
                method = b[o + 2]
                src = b[o + 3:o + 2 + ln]
                o += 2 + ln
                payload = _expand(method, src, 128 << sz)
            secs.append((c, h, s, sz, fl, payload))
        tracks.append((cyl, head, secs))
    return hdr, tracks


def _expand(method, src, size):
    if method == 0:
        return bytes(src[:size])
    out = bytearray()
    if method == 1:
        cnt = struct.unpack_from("<H", src, 0)[0]
        out += bytes(src[2:4]) * cnt
    elif method == 2:
        i = 0
        while i < len(src) and len(out) < size:
            k = src[i]
            if k == 0:
                n = src[i + 1]
                out += src[i + 2:i + 2 + n]
                i += 2 + n
            else:
                n = src[i + 1]
                pat = src[i + 2:i + 2 + (1 << k)]
                out += bytes(pat) * n
                i += 2 + (1 << k)
    else:
        raise ValueError("unknown sector method %d" % method)
    return bytes(out[:size])


# ---------------------------------------------------------------- the encoder
class LzhEncoder(LzhDecoder):
    """Okumura's LZHUF encoder on the decoder's tree: only the tests make
    Teledisk files, so this is plain and slow (a hash of 3-byte prefixes)."""

    def __init__(self):
        super().__init__(b"")
        self.out = bytearray()
        self.acc = 0
        self.nacc = 0
        # the encoder's side of the position code: the first 8-bit prefix
        # that decodes to each of the 64 symbols
        self.pcode = [0] * 64
        self.plen = [0] * 64
        for i in range(255, -1, -1):
            self.pcode[D_CODE[i]] = i
            self.plen[D_CODE[i]] = D_LEN[i]

    def putcode(self, n, value):
        """the top n bits of the 16-bit value, MSB first"""
        for b in range(n):
            self.acc = (self.acc << 1) | ((value >> (15 - b)) & 1)
            self.nacc += 1
            if self.nacc == 8:
                self.out.append(self.acc)
                self.acc = 0
                self.nacc = 0

    def flush(self):
        if self.nacc:
            self.out.append((self.acc << (8 - self.nacc)) & 0xFF)
            self.acc = self.nacc = 0

    def encode_char(self, c):
        i = j = 0
        k = self.prnt[c + T]
        while True:
            i >>= 1
            if k & 1:
                i += 0x8000
            j += 1
            k = self.prnt[k]
            if k == R:
                break
        self.putcode(j, i)
        self._update(c)

    def encode_position(self, pos):
        s = pos >> 6
        self.putcode(self.plen[s], self.pcode[s] << 8)
        self.putcode(6, (pos & 0x3F) << 10)


def lzh_encode(data):
    """compress with the Teledisk "td" code (no length word)"""
    e = LzhEncoder()
    stream = bytearray(b" " * (N - F)) + bytearray(data)   # absolute positions
    base = N - F
    heads = {}
    for q in range(0, base - 2):
        heads.setdefault(bytes(stream[q:q + 3]), []).append(q)
    p = base
    end = len(stream)
    while p < end:
        best, bpos = 0, 0
        key = bytes(stream[p:p + 3])
        if len(key) == 3:
            for q in reversed(heads.get(key, [])[-64:]):
                if p - q - 1 > N - 1:
                    break
                m = 0
                while m < F and p + m < end and stream[q + m] == stream[p + m]:
                    m += 1
                if m > best:
                    best, bpos = m, p - q - 1
                    if m == F:
                        break
        if best >= 3:
            e.encode_char(255 - THRESHOLD + best)
            e.encode_position(bpos)
            for m in range(best):
                if p + m + 3 <= end:
                    heads.setdefault(bytes(stream[p + m:p + m + 3]), []).append(p + m)
            p += best
        else:
            e.encode_char(stream[p])
            heads.setdefault(key, []).append(p)
            p += 1
    e.flush()
    return bytes(e.out)


# ----------------------------------------------------------- building a file
def _crc16(data, poly=0xA097):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ poly) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def sector_block(data, method):
    """a sector's data block (length, method, content) for a payload"""
    if method == 0:
        content = bytes(data)
    elif method == 1:                   # a repeated 2-byte pattern
        pat = bytes(data[:2])
        if bytes(data) != pat * (len(data) // 2):
            raise ValueError("td0: method 1 needs a repeating 2-byte pattern")
        content = struct.pack("<H", len(data) // 2) + pat
    elif method == 2:                   # runs, then literals
        content = bytearray()
        i = 0
        while i < len(data):
            run = 1
            while i + run < len(data) and data[i + run] == data[i] and run < 255:
                run += 1
            if run >= 4:
                n = min(run // 2, 255)                        # a 2-byte pattern, n times
                content += bytes([1, n, data[i], data[i]])
                i += 2 * n
            else:
                lit = bytearray()
                while i < len(data) and len(lit) < 255:
                    r = 1
                    while i + r < len(data) and data[i + r] == data[i] and r < 4:
                        r += 1
                    if r >= 4:
                        break
                    lit.append(data[i])
                    i += 1
                if lit:
                    content += bytes([0, len(lit)]) + lit
        content = bytes(content)
    else:
        raise ValueError("td0: method")
    return struct.pack("<H", len(content) + 1) + bytes([method]) + content


def build(tracks, compress=True, sides=2, comment=None):
    """a TD0 file. tracks: [(cyl, head, [sector])] with a sector
    (c, h, r, sizecode, flags, payload or None[, method])"""
    body = bytearray()
    step = 0
    if comment is not None:
        step = 0x80
        body += struct.pack("<HH", 0, len(comment)) + bytes(6) + comment
    for cyl, head, secs in tracks:
        th = bytes([len(secs), cyl, head])
        body += th + bytes([_crc16(th) & 0xFF])
        for sec in secs:
            c, h, r, sz, fl, payload = sec[:6]
            method = sec[6] if len(sec) > 6 else 0
            hdr = bytes([c, h, r, sz, fl])
            body += hdr + bytes([_crc16(hdr) & 0xFF])
            if payload is not None and not fl & 0x30 and sz <= 6:
                body += sector_block(payload, method)
    body += bytes([255]) + bytes(3)
    head = bytearray(b"td" if compress else b"TD")
    head += bytes([0, 0x15, 0x15, 0, 2, step, 0, sides])
    head = bytes(head[:12]) if len(head) >= 12 else bytes(head) + bytes(12 - len(head))
    head = bytearray(head)
    head[2], head[3], head[4], head[5], head[6], head[7], head[8], head[9] = 0, 0, 0x15, 0, 2, step, 0, sides
    struct.pack_into("<H", head, 10, _crc16(bytes(head[:10])))
    return bytes(head) + (lzh_encode(bytes(body)) if compress else bytes(body))


def bench_tracks():
    """the track set of the downloader bench: every sector shape the parser
    handles (raw, 2-byte pattern, runs, 128/256/512 bytes, a skipped sector, a
    size code past 6 with no data) over three tracks"""
    def pat(r, n):
        return bytes(((r * 31 + j * 7 + 3) & 255) for j in range(n))
    t00 = [(0, 0, 1, 1, 0, pat(1, 256), 0),
           (0, 0, 2, 1, 0, b"\xe5" * 256, 1),
           (0, 0, 3, 1, 0, bytes(100) + pat(3, 156), 2),
           (0, 0, 4, 1, 0x10, None),
           (0, 0, 5, 15, 0, None),
           (0, 0, 6, 0, 0, pat(6, 128), 0),
           (0, 0, 7, 2, 0, pat(7, 512), 2)]
    t01 = [(0, 1, r, 1, 0, pat(r + 20, 256), 0) for r in range(1, 4)]
    t10 = [(1, 0, r, 1, 0, pat(r + 40, 256), 0) for r in range(1, 17)]
    return [(0, 0, t00), (0, 1, t01), (1, 0, t10)]


def bench_fixtures(out_dir):
    """dlt.td0 (compressed, with a comment block), dlp.td0 (plain) and the
    reference tracks the store has to build from them"""
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import mk_disk
    d = Path(out_dir)
    d.mkdir(parents=True, exist_ok=True)
    tr = bench_tracks()
    (d / "dlt.td0").write_bytes(build(tr, compress=True, comment=b"bench disk"))
    (d / "dlp.td0").write_bytes(build(tr, compress=False))
    for cyl, head, secs in tr:
        ref = []
        for (c, h, r, sz, fl, payload, *_m) in secs:
            nodata = bool(fl & 0x30) or sz > 6
            ref.append((c, h, r, min(sz & 7, 3), None if nodata else payload))
        mk_disk.reftrack(d / f"ref_dlt_t{cyl}s{head}", cyl, head, ref, fdi=True)


def fixture(out_dir, nbytes):
    """the decoder bench's input: nbytes of compressed stream and the
    model's decode of it (a prefix, so the last symbol is cut mid-way)"""
    import random
    from pathlib import Path
    rnd = random.Random(7)
    data = bytearray()
    while len(data) < nbytes * 2:
        if data and rnd.random() < 0.3:
            a = rnd.randrange(len(data))
            data += data[a:a + rnd.randrange(3, 90)]
        else:
            data += bytes(rnd.randrange(256) for _ in range(rnd.randrange(1, 40)))
    comp = lzh_encode(bytes(data))[:nbytes]
    out = LzhDecoder(comp).read(10 ** 9)
    d = Path(out_dir)
    d.mkdir(parents=True, exist_ok=True)
    (d / "lzh.in").write_text("".join("%02X\n" % b for b in comp))
    (d / "lzh.out").write_text("".join("%02X\n" % b for b in out))
    print(len(comp), len(out))


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    fx = sub.add_parser("fixture")
    fx.add_argument("out")
    fx.add_argument("--bytes", type=int, default=36000)
    bf = sub.add_parser("benchfiles")
    bf.add_argument("out")
    a = ap.parse_args()
    if a.cmd == "fixture":
        fixture(a.out, a.bytes)
    else:
        bench_fixtures(a.out)
