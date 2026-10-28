"""Minimal PDF reader for the MTA diagram: opens it with the empty user password (as any viewer does) and inflates streams.

The PDF's permission flags allow content extraction; we only read it and never modify the file."""
import hashlib
import re
import zlib

PAD = bytes.fromhex("28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A")


def rc4(key, data):
    S = list(range(256))
    j = 0
    for i in range(256):
        j = (j + S[i] + key[i % len(key)]) & 0xFF
        S[i], S[j] = S[j], S[i]
    out = bytearray(len(data))
    i = j = 0
    for n, ch in enumerate(data):
        i = (i + 1) & 0xFF
        j = (j + S[i]) & 0xFF
        S[i], S[j] = S[j], S[i]
        out[n] = ch ^ S[(S[i] + S[j]) & 0xFF]
    return bytes(out)


def parse_pdf_string(raw):
    """Decode a literal (...) PDF string body with escapes."""
    out, i = bytearray(), 0
    while i < len(raw):
        c = raw[i]
        if c == 0x5C:  # backslash
            i += 1
            e = raw[i]
            if e in b"nrtbf":
                out.append({ord("n"): 10, ord("r"): 13, ord("t"): 9, ord("b"): 8, ord("f"): 12}[e])
            elif 0x30 <= e <= 0x37:
                j = i
                while j < len(raw) and j < i + 3 and 0x30 <= raw[j] <= 0x37:
                    j += 1
                out.append(int(raw[i:j], 8) & 0xFF)
                i = j - 1
            elif e in b"\r\n":
                pass
            else:
                out.append(e)
        else:
            out.append(c)
        i += 1
    return bytes(out)


class PDF:
    def __init__(self, path):
        self.b = open(path, "rb").read()
        self.objs = {}  # num -> (dict_bytes, raw_stream_bytes or None)
        for m in re.finditer(rb"(?<![0-9])(\d+)\s+(\d+)\s+obj\b", self.b):
            num = int(m.group(1))
            start = m.end()
            end = self.b.find(b"endobj", start)
            body = self.b[start:end]
            si = re.search(rb"stream\r?\n", body)
            if si and body[: si.start()].rstrip().endswith(b">>"):
                d = body[: si.start()]
                lm = re.search(rb"/Length\s+(\d+)(?!\s+\d+\s+R)", d)
                data_start = start + si.end()
                if lm:
                    data = self.b[data_start: data_start + int(lm.group(1))]
                else:
                    data = self.b[data_start: self.b.find(b"endstream", data_start)].rstrip(b"\r\n")
                self.objs[num] = (d, data)
            else:
                self.objs[num] = (body, None)
        self._key()
        self._objstms()

    def _key(self):
        # Standard security handler, revision 4, RC4 128-bit: derive the file key from the empty user password.
        i = self.b.find(b"/Filter/Standard")
        oi = self.b.find(b"/O(", i) + 3
        depth, j = 1, oi
        while depth:
            if self.b[j] == 0x5C:
                j += 2
                continue
            if self.b[j] == 0x28:
                depth += 1
            elif self.b[j] == 0x29:
                depth -= 1
            j += 1
        O = parse_pdf_string(self.b[oi: j - 1])
        P = int(re.search(rb"/P (-?\d+)", self.b[i: i + 400]).group(1))
        ID0 = bytes.fromhex(re.search(rb"/ID\s*\[\s*<([0-9A-Fa-f]+)>", self.b).group(1).decode())
        enc_meta = b"/EncryptMetadata false" not in self.b[i - 200: i + 400]
        h = hashlib.md5(PAD + O + (P & 0xFFFFFFFF).to_bytes(4, "little") + ID0 + (b"" if enc_meta else b"\xff\xff\xff\xff")).digest()
        for _ in range(50):
            h = hashlib.md5(h[:16]).digest()
        self.key = h[:16]
        self.P = P

    def stream(self, num):
        d, data = self.objs[num]
        k = hashlib.md5(self.key + num.to_bytes(3, "little") + (0).to_bytes(2, "little")).digest()[:16]
        dec = rc4(k, data)
        if b"/FlateDecode" in d:
            dec = zlib.decompress(dec)
        return dec

    def _objstms(self):
        for num, (d, data) in list(self.objs.items()):
            if data is not None and b"/ObjStm" in d:
                s = self.stream(num)
                n = int(re.search(rb"/N (\d+)", d).group(1))
                first = int(re.search(rb"/First (\d+)", d).group(1))
                hdr = list(map(int, s[:first].split()))
                offs = [(hdr[2 * k], hdr[2 * k + 1]) for k in range(n)]
                for k, (onum, off) in enumerate(offs):
                    endo = offs[k + 1][1] if k + 1 < n else len(s) - first
                    self.objs.setdefault(onum, (s[first + off: first + endo], None))

    def dict_of(self, num):
        return self.objs[num][0]
