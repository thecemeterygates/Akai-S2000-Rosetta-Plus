"""CHOP on the full emulator (s2kemu = the real OS + Rosetta 0.28 from the floppy image)."""
import os, subprocess, sys
W = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rosetta", "work", "build")
EMU = "/root/s2k/emu/s2kemu"
AK = "0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ#+-."
LO = {k[3:]: int(v, 16) for k, v in (l.split(" equ ") for l in open(os.path.join(W, "lo_syms.inc")) if " equ " in l)}
FXB = 0x3EA00 + LO["fxbuf"]


def name(b):
    return "".join(AK[c] if c < len(AK) else "?" for c in b)


def run(body, env_extra=None):
    d = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dump.bin")
    script = "ms 26000\n" + body + f"\ndump {d}\n"
    env = dict(os.environ, DISK=os.path.join(W, "S2K_ROSETTA.img"), **(env_extra or {}))
    r = subprocess.run([EMU, os.path.join(W, "S2K_ROSETTA_os.bin")], input=script, capture_output=True, text=True,
                       env=env, timeout=900)
    scr = []
    for l in r.stdout.splitlines():
        if l.startswith(f"peek {FXB:05x}"):
            b = bytes(int(x, 16) for x in l.split()[2:])
            scr.append((b[:16].decode("latin1"), b[16:32].decode("latin1")))
    return open(d, "rb").read(), scr, r


def catalog(d):
    np_ = d[0x74F4]
    ns = d[0x74F6] | d[0x74F7] << 8
    segs = [d[0xB0D0 + 2 * i] | d[0xB0D1 + 2 * i] << 8 for i in range(np_ + ns)]
    progs, samps = [], []
    for i, s in enumerate(segs):
        h = d[s * 16:s * 16 + 192]
        if i < np_:
            kgs = []
            k = h[1] | h[2] << 8
            for _ in range(h[0x2A]):
                kh = d[k * 16:k * 16 + 192]
                kgs.append(dict(lo=kh[3], hi=kh[4], zone=name(kh[0x22:0x2E]), sseg=kh[0x38] | kh[0x39] << 8))
                k = kh[1] | kh[2] << 8
            progs.append(dict(name=name(h[3:15]), num=h[0xF], kgs=kgs, seg=s))
        else:
            g = lambda o: int.from_bytes(h[o:o + 4], "little")
            samps.append(dict(name=name(h[3:15]), loc=g(0x16), len=g(0x1A), st=g(0x1E), en=g(0x22), pitch=h[2],
                              ptype=h[0x13], seg=s))
    return progs, samps


TO_CHOP = "key 4 1\nms 600\nwheel 1\nms 300\nkey 5 1\nms 400\n"
GO = "key 5 1\nms 300\nkey 5 1\nms 300\n"          # cursor -> value -> GO
PK = f"peek {FXB:x} 32\n"


def main():
    ok = True

    def check(n, c, info=""):
        nonlocal ok
        print(("PASS " if c else "FAIL ") + n, info)
        ok &= bool(c)

    d0, _, _ = run("")
    p0, s0 = catalog(d0)
    # A: EQUAL 8 on NOISE BURST
    d, scr, r = run("poke 7639 1 0\n" + TO_CHOP + PK + GO + PK + "key 5 1\nms 2000\n" + PK + "key 5 1\nms 15000\n" + PK)
    p, s = catalog(d)
    new = [x for x in s if x["name"].startswith("NOISE BU-")]
    pr = [x for x in p if x["name"].startswith("NOISE BUCHOP")]
    print("  screens:", scr)
    check("EQUAL 8: 8 slices named NOISE BU-01..08", [x["name"] for x in new] == [f"NOISE BU-{i:02d} " for i in range(1, 9)])
    lens = [x["len"] for x in new]
    check("EQUAL 8: lengths ~13230/8 each, sum = 13230 (zero-cross snaps)", sum(lens) == 13230 and
          all(abs(l - 13230 / 8) < 260 for l in lens), f"({lens})")
    check("EQUAL 8: one-shot, pitch C3 up", [x["pitch"] for x in new] == list(range(60, 68)) and
          all(x["ptype"] == 3 and x["st"] == 0 and x["en"] == x["len"] for x in new))
    check("EQUAL 8: program 'NOISE BUCHOP' number 9, 8 keygroups C3..G3 on the slices", len(pr) == 1 and
          pr[0]["num"] == 9 and [(k["lo"], k["hi"], k["zone"]) for k in pr[0]["kgs"]] ==
          [(60 + i, 60 + i, f"NOISE BU-{i + 1:02d} ") for i in range(8)], f"({pr[0] if pr else None})")
    check("EQUAL 8: keygroups point at the slice headers", pr and [k["sseg"] for k in pr[0]["kgs"]] == [x["seg"] for x in new])
    src = [x for x in s if x["name"] == "NOISE BURST "][0]
    ram = d  # sample RAM isn't in the CPU dump: compare via sdump below
    check("EQUAL: messages", scr[-1][1].startswith("SLICES + PROGRAM") and "SLICES?" in scr[-2][1], f"{scr[-2:]}")
    check("EQUAL: the source sample selected again", d[0x7639] == 1)
    # sample data: slice k = source [mark_k, mark_k+1)
    sd = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sram.bin")
    d, scr, r = run("poke 7639 1 0\n" + TO_CHOP + GO + "key 5 1\nms 2000\nkey 5 1\nms 15000\n" + f"sdump 0 200000 {sd}\n")
    import numpy as np
    sr = np.fromfile(sd, dtype=np.uint16)
    p, s = catalog(d)
    new = [x for x in s if x["name"].startswith("NOISE BU-")]
    off, good = 0, True
    for x in new:
        a = sr[src["loc"] + off: src["loc"] + off + x["len"]]
        b = sr[x["loc"]: x["loc"] + x["len"]]
        good &= bool(np.array_equal(a, b))
        off += x["len"]
    check("EQUAL: slice audio = the source, back to back", good and sr[new[0]["loc"]:new[0]["loc"] + 100].any())
    # B: TRANS on CLICK
    d, scr, r = run("poke 7639 0 0\n" + TO_CHOP + "wheel 1\nms 300\nkey 5 1\nms 300\nwheel 4\nms 300\nkey 5 1\nms 300\n" + PK + "key 5 1\nms 3000\n" + PK + "key 5 1\nms 15000\n" + PK)
    p, s = catalog(d)
    new = [x for x in s if x["name"].startswith("CLICK   -")]
    print("  screens:", scr)
    check("TRANS: CLICK cut into slices", len(new) >= 2, f"({len(new)} slices, lens {[x['len'] for x in new]})")
    # C: LAZY on NOISE BURST (0.3 s): start, taps ~60 / ~130 ms in, it stops at the end, then F2 asks, F2 makes
    d, scr, r = run("poke 7639 1 0\n" + TO_CHOP + "wheel 2\nms 300\n" + GO + "key 5 1 40\nms 20\n" + PK +
                    "keydown 5 1\nms 20\nkeyup 5 1\nms 50\nkeydown 5 1\nms 20\nkeyup 5 1\nms 400\n" + PK +
                    "key 5 1\nms 300\n" + PK + "key 5 1\nms 12000\n" + PK, {"VCLOG": "1"})
    p, s = catalog(d)
    new = [x for x in s if x["name"].startswith("NOISE BU-")]
    print("  screens:", scr)
    starts = [l for l in r.stderr.splitlines() if "p84=134b" in l]
    check("LAZY: GO auditions the sample (a voice started at its address)", len(starts) > 0, f"({starts[:2]})")
    lens = [x["len"] for x in new]
    check("LAZY: 3 slices from 2 taps, the first ~60-100 ms long", len(new) == 3 and 2000 < lens[0] < 6000,
          f"({lens})")
    return ok


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
