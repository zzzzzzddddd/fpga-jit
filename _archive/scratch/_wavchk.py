import struct, glob, os
for p in sorted(glob.glob("sd_assets/*.wav")):
    b = open(p,"rb").read()
    i = 12
    data = None
    while i + 8 <= len(b):
        cid = b[i:i+4]; csz = struct.unpack("<I", b[i+4:i+8])[0]
        if cid == b"data":
            data = b[i+8:i+8+csz]; break
        i += 8 + csz + (csz & 1)
    if data is None: print(p, "NO DATA"); continue
    s = struct.unpack("<%dh" % (len(data)//2), data[:len(data)//2*2])
    pk = max(abs(x) for x in s)
    rms = (sum(x*x for x in s)/len(s))**0.5
    nz = sum(1 for x in s if x != 0)
    print("%-20s n=%6d peak=%6d rms=%7.1f nonzero=%5.1f%% first20=%s" % (os.path.basename(p), len(s), pk, rms, 100.0*nz/len(s), s[:20]))
