#!/usr/bin/env python3
"""Make device/files/SecSettings-ead-<build>.patch for a firmware's SecSettings.apk (colortone).
Finds SecEADPreferenceController.getAvailabilityStatus() in the APK's (stored) dex files, checks it ends
in 'const/4 v0, 3; return v0', changes the 3 to 0 and fixes the dex SHA-1 and adler32 and the zip CRCs.
Usage: eadpatch.py SecSettings.apk <build> [out.patch]     (prints the stock and patched MD5)"""
import hashlib, struct, sys, zlib

def uleb(d, p):
    r = s = 0
    while True:
        b = d[p]; p += 1; r |= (b & 0x7f) << s; s += 7
        if b < 0x80: return r, p

def find_insns(d):
    """Offset inside the dex of the method's last two instructions, or None if the class isn't in it."""
    u32 = lambda o: struct.unpack_from('<I', d, o)[0]
    nstr, strs, ntyp, typs = u32(56), u32(60), u32(64), u32(68)
    meths, ncls, clss = u32(92), u32(96), u32(100)
    def string(i):
        n, p = uleb(d, u32(strs + 4 * i)); return d[p:d.index(b'\0', p)].decode('utf-8', 'replace')
    for c in range(ncls):
        o = clss + 32 * c
        if not string(u32(typs + 4 * u32(o))).endswith('/SecEADPreferenceController;'): continue
        p = u32(o + 24); assert p, 'class has no data'
        ns, p = uleb(d, p); ni, p = uleb(d, p); nd, p = uleb(d, p); nv, p = uleb(d, p)
        for _ in range(2 * (ns + ni)): _, p = uleb(d, p)
        for n in (nd, nv):
            m = 0
            for _ in range(n):
                diff, p = uleb(d, p); _, p = uleb(d, p); code, p = uleb(d, p); m += diff
                if string(u32(meths + 8 * m + 4)) == 'getAvailabilityStatus':
                    assert code, 'method has no code'; n = 2 * u32(code + 12)   # instruction bytes
                    assert 4 <= n <= 8, 'method is %d bytes, expected a bare return 3' % n; return code + 16 + n - 4
        raise SystemExit('SecEADPreferenceController has no getAvailabilityStatus()')
    return None

apk = bytearray(open(sys.argv[1], 'rb').read()); build = sys.argv[2]
stock = hashlib.md5(apk).hexdigest(); orig = bytes(apk)
eocd = apk.rindex(b'PK\x05\x06'); ncd, _, cd = struct.unpack_from('<HII', apk, eocd + 10)
done = False
for _ in range(ncd):
    assert apk[cd:cd + 4] == b'PK\x01\x02'
    method, = struct.unpack_from('<H', apk, cd + 10)
    size, = struct.unpack_from('<I', apk, cd + 24)
    nl, el, cl = struct.unpack_from('<HHH', apk, cd + 28); lh, = struct.unpack_from('<I', apk, cd + 42)
    name = apk[cd + 46:cd + 46 + nl].decode()
    if name.endswith('.dex') and '/' not in name:
        assert method == 0, name + ' is compressed; this patch format needs stored dex files'
        lnl, lel = struct.unpack_from('<HH', apk, lh + 26); start = lh + 30 + lnl + lel
        dex = apk[start:start + size]; at = find_insns(dex)
        if at is not None:
            assert dex[at:at + 4] == b'\x12\x30\x0f\x00', 'unexpected code: ' + dex[at:at + 8].hex()
            dex[at + 1] = 0x00                                       # const/4 v0, 3 -> const/4 v0, 0
            dex[12:32] = hashlib.sha1(dex[32:]).digest()
            dex[8:12] = struct.pack('<I', zlib.adler32(bytes(dex[12:])))
            apk[start:start + size] = dex
            crc = struct.pack('<I', zlib.crc32(bytes(dex)))
            apk[lh + 14:lh + 18] = crc; apk[cd + 16:cd + 20] = crc
            print('%s: getAvailabilityStatus at file offset %d' % (name, start + at)); done = True
    cd += 46 + nl + el + cl
assert done, 'SecEADPreferenceController not found in any dex'
new = hashlib.md5(apk).hexdigest()
out = ['# Adaptive Color Tone: SecSettings.apk (%s, md5 %s) -> md5 %s' % (build, stock, new),
       "# SecEADPreferenceController.getAvailabilityStatus() is compiled to 'return 3' on the S23; one byte in its dex",
       '# (const/4 v0, 3 -> 0) makes it available. The other bytes are that dex\'s SHA-1 and adler32 and the zip CRCs.',
       '# Made by tools/eadpatch.py. Format: <zero-based file offset> <new byte in octal>']
out += ['%d %o' % (i, b) for i, (a, b) in enumerate(zip(orig, apk)) if a != b]
open(sys.argv[3] if len(sys.argv) > 3 else 'SecSettings-ead-%s.patch' % build, 'w').write('\n'.join(out) + '\n')
print('stock md5  ', stock); print('patched md5', new); print(len(out) - 4, 'bytes changed')
