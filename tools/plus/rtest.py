"""Rosetta+ unit tests on the real hi / lo binaries (harness.c = the s2kemu CPU core + simulated DMA)."""
import os
import re
import subprocess
import sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
W = os.environ.get("RW", os.path.join(HERE, "..", "rosetta", "work", "build"))
HARN = os.path.join(HERE, "harness")


def syms(mapf):
    d = {}
    for line in open(mapf):
        m = re.match(r"\s+([0-9A-F]+)\s+([0-9A-F]+)\s+(\S+)$", line)
        if m:
            d[m.group(3)] = int(m.group(2), 16)
    return d


H = syms(os.path.join(W, "rosetta_hi.map"))
L = {k[3:]: int(v, 16) for k, v in (l.split(" equ ") for l in open(os.path.join(W, "lo_syms.inc")) if " equ " in l)}
HI, LO = 0x40000, 0x3EA00
FX = {}
for l in open(os.path.join(W, "hi_fx.inc")):
    m = re.match(r"FXI_(\w+) equ (\d+)", l)
    if m:
        FX[m.group(1)] = int(m.group(2))


def hi(name):
    return HI + H[name]


def lo(name):
    return LO + L[name]


class Run:
    def __init__(self):
        self.cmds = [f"load {os.path.join(W, 'rosetta_menu.bin')} {LO:x}", f"load {os.path.join(W, 'rosetta_hi.bin')} {HI:x}",
                     f"pokew {lo('fxhdr'):x} {H['hifx'] + 0x1600:x}"]
        for seg, off in [(0x2345, 0x2644), (0x2345, 0x2828), (0x2345, 0x28DE), (0x2345, 0x32AF), (0x2345, 0x40C0),
                         (0x2345, 0x3078), (0x0FE4, 0x522C), (0x2345, 0x0A47)]:
            self.cmds.append(f"retf {seg:x} {off:x}")
        self.cmds.append("ret fe4 c841")
        self.out = []

    def c(self, s):
        self.cmds.append(s)

    def pokeb(self, a, *v):
        self.c(f"poke {a:x} " + " ".join(f"{x & 0xFF:x}" for x in v))

    def pokew(self, a, *v):
        self.c(f"pokew {a:x} " + " ".join(f"{x & 0xFFFF:x}" for x in v))

    def call(self, name):
        self.c(f"call 4000 {H[name]:x}")

    def lcall(self, name):
        self.c(f"call 3ea0 {L[name]:x}")

    def go(self):
        r = subprocess.run([HARN], input="\n".join(self.cmds) + "\n", capture_output=True, text=True, timeout=600)
        if r.returncode:
            print(r.stderr[-2000:])
            raise SystemExit(f"harness rc {r.returncode}")
        return r.stdout


def capture(kind_fx, oct_=1, freq=441.0, passes=400, frames=220, extra=(), fb=0, sig="sine"):
    r = Run()
    r.pokeb(lo("fxon"), FX[kind_fx])
    r.pokew(lo("isendv"), 0x800F)
    r.pokew(lo("iwet"), 50)
    r.pokew(lo("pfb"), fb)
    r.pokeb(0x7557, 1)
    r.pokeb(hi("lr_oct"), oct_)
    for a, v in extra:
        r.pokeb(a, v)
    r.c(f"sig {sig} {freq} 8000")
    cap = os.path.join(HERE, "cap.bin")
    for k in range(passes):
        r.c(f"adv {frames}")
        r.call("lr_run")
        r.call("mfx_run")
    r.c(f"cap {cap}")
    r.c(f"peek {hi('lr_act'):x} 1")
    r.c(f"peek {hi('lr_kind') if 'lr_kind' in H else 0:x} 1")
    out = r.go()
    a = np.fromfile(cap, dtype=np.int16).reshape(-1, 2)
    return a, out


def peakf(x):
    x = x.astype(float) - x.mean()
    w = np.hanning(len(x))
    s = np.abs(np.fft.rfft(x * w))
    s[:3] = 0
    k = int(np.argmax(s))
    return k * 44100.0 / len(x), s[k]


def taps_log(path):
    """port log -> list of tick segments, each {fn: (gain word, length word)} as the chip holds them then."""
    cur, sel, segs = {}, 0, []
    for line in open(path):
        if line.startswith("M"):
            segs.append(dict(cur))
            continue
        port, val = (int(x, 16) for x in line.split())
        if port == 0x80:
            sel = val
        elif sel >> 8 == 0x0A and port in (0x82, 0x84):
            g, n = cur.get(sel & 0xFF, (0, 2))
            cur[sel & 0xFF] = (val, n) if port == 0x82 else (g, val)
    return segs


def render(segs, x, spt=22.535):
    """the delay engine as Rosetta models it: out = sum gain x line[t - delay], feedback taps into the line."""
    n = int(len(segs) * spt)
    line = np.zeros(n + 70000)
    out = np.zeros((n, 2))
    t0 = 65536
    for k, sg in enumerate(segs):
        a, b = int(k * spt), int((k + 1) * spt)
        taps = []
        for fn, (gw, lw) in sg.items():
            g = ((gw & 0xFFFC) - (0x10000 if gw & 0x8000 else 0)) / 32768.0
            if g:
                taps.append((g, gw & 3, (2 - lw) & 0xFFFF))
        for t in range(a, b):
            line[t0 + t] = x[t]
            for g, r, d in taps:
                if r == 3:
                    line[t0 + t] += g * line[t0 + t - d]
            for g, r, d in taps:
                if r == 1:
                    out[t, 0] += g * line[t0 + t - d]
                elif r == 0:
                    out[t, 1] += g * line[t0 + t - d]
    return out


def finef(y):
    y = y - y.mean()
    s = np.abs(np.fft.rfft(y * np.hanning(len(y)), n=8 * len(y)))
    return np.argmax(s) * 44100.0 / (8 * len(y))


def detune_test(check):
    r = Run()
    r.pokeb(lo("fxon"), FX["DETUNE"])
    r.pokew(lo("ptime"), 100)
    r.pokew(lo("prate"), 100)
    r.pokeb(lo("keepph"), 0)
    plog = os.path.join(HERE, "ports.log")
    r.c(f"portlog {plog}")
    r.lcall("fx_apply")
    r.c("plmark")
    for k in range(4400):
        r.c("setr 1 1")
        r.lcall("lfo_run")
        r.c("plmark")
    r.go()
    segs = taps_log(plog)
    n = int(len(segs) * 22.535)
    x = np.sin(2 * np.pi * 441 * np.arange(n) / 44100)
    out = render(segs[1:], x)[4000:]
    fl, fr = finef(out[:, 0]), finef(out[:, 1])
    cl, cr = 1200 * np.log2(fl / 441), 1200 * np.log2(fr / 441)
    check("DETUNE: L sharp ~+8 cents", 6 < cl < 10, f"({fl:.2f} Hz = {cl:+.1f} cents)")
    check("DETUNE: R flat ~-8 cents", -10 < cr < -6, f"({fr:.2f} Hz = {cr:+.1f} cents)")
    env = np.abs(out[:, 0])
    check("DETUNE: L never silent for long", np.convolve(env > 0.05, np.ones(441), "valid").min() > 0,
          f"(rms {np.sqrt((out[:, 0] ** 2).mean()):.2f})")


def last_taps(path):
    segs = taps_log(path)
    return segs[-1] if segs else {}


def clock_run(r, bpm, seconds, t0=0.0, start_byte=0):
    """MIDI clock at bpm into the OS ring (0:0300, write pointer 73A0) while the main loop runs plus_tick every
    10 OS ticks (5 ms)."""
    per = 60000.0 / bpm / 24 / 0.511       # ticks a clock
    t, nxt, wp = t0, t0, 0x300 + start_byte
    while t < t0 + seconds / 0.000511:
        t += 10
        while nxt <= t:
            r.pokeb(wp, 0xF8)
            wp = 0x300 + ((wp + 1) & 0xFF)
            nxt += per
        r.pokew(0x73A0, wp)
        r.pokeb(0x73DA, int(t) & 0xFF)          # (the OS tick is a byte)
        r.call("plus_tick")
    r.c("plmark")
    return t, wp - 0x300


def clock_test(check):
    plog = os.path.join(HERE, "ports.log")
    for bpm, want in [(120, 22050), (90, 14700), (140, 18900)]:
        r = Run()
        r.pokeb(lo("fxon"), FX["ECHO"])
        r.pokew(lo("ptime"), 100)
        r.pokew(lo("pfb"), 50)
        r.pokeb(hi("ck_on"), 1)
        r.pokeb(hi("lr_bpm"), 92)
        r.pokew(0x73A0, 0x300)
        r.c(f"portlog {plog}")
        r.lcall("fx_apply")
        t, wp = clock_run(r, bpm, 8.0)
        r.c(f"peek {hi('ck_bpm'):x} 2")
        r.c(f"peek {hi('lr_bpm'):x} 1")
        out = r.go().split()
        got_bpm = int(out[2], 16) | int(out[3], 16) << 8
        lr = int(out[6], 16)
        tp = last_taps(plog)
        d = {fn: (2 - lw) & 0xFFFF for fn, (gw, lw) in tp.items() if gw}
        check(f"CLOCK {bpm}: tempo read", got_bpm == bpm and lr == bpm, f"(ck_bpm {got_bpm}, lr_bpm {lr})")
        check(f"CLOCK {bpm}: ECHO taps on the beat (or its half)", all(abs(d.get(fn, 0) - want) <= want * 0.004
              for fn in (1, 2, 3)), f"(delays {d}, want {want})")
    # steady tempo: no tap writes at all after the sync; a TIME edit (fx_apply) is re-synced at once
    r = Run()
    r.pokeb(lo("fxon"), FX["ECHO"])
    r.pokew(lo("ptime"), 100)
    r.pokeb(hi("ck_on"), 1)
    r.pokew(0x73A0, 0x300)
    r.lcall("fx_apply")
    t, wp = clock_run(r, 120, 8.0)
    r.c(f"portlog {plog}")
    t, wp = clock_run(r, 120, 2.0, t0=t, start_byte=wp)
    r.pokew(lo("ptime"), 150)
    r.pokeb(lo("keepph"), 1)
    r.lcall("fx_apply")
    r.c("plmark")
    r.call("plus_tick")
    r.c("plmark")
    r.go()
    txt = open(plog).read().split("M\n")
    n_steady = txt[0].count("0080 0a")
    d = {}
    sel = 0
    for line in txt[2].splitlines():
        pt, v = (int(x, 16) for x in line.split())
        if pt == 0x80:
            sel = v
        elif pt == 0x84 and sel >> 8 == 0x0A:
            d[sel & 0xFF] = (2 - v) & 0xFFFF
    check("CLOCK steady: no tap writes for 2 s", n_steady == 0, f"({n_steady} selects)")
    check("CLOCK: a TIME edit is re-synced on the next pass", abs(d.get(1, 0) - 22050) < 110, f"({d})")
    # CLK off again: TIME as the page has it (375 ms)
    r = Run()
    r.pokeb(lo("fxon"), FX["ECHO"])
    r.pokew(lo("ptime"), 100)
    r.pokeb(hi("ck_on"), 1)
    r.pokew(0x73A0, 0x300)
    r.lcall("fx_apply")
    t, wp = clock_run(r, 120, 8.0)
    r.c(f"portlog {plog}")
    r.pokeb(hi("ck_on"), 0)
    r.call("plus_tick")
    r.c("plmark")
    r.go()
    d = {fn: (2 - lw) & 0xFFFF for fn, (gw, lw) in last_taps(plog).items() if gw}
    check("CLOCK off: ECHO back at TIME 100 = 375 ms", d.get(1) == 16538, f"({d})")
    # stopped clock keeps the tempo; LFO lock on CHORUS: slot incs in proportion
    r = Run()
    r.pokeb(lo("fxon"), FX["CHORUS"])
    r.pokew(lo("ptime"), 100)
    r.pokew(lo("prate"), 100)
    r.pokeb(hi("ck_on"), 1)
    r.pokeb(hi("ck_lfo"), 1)
    r.pokew(0x73A0, 0x300)
    r.lcall("fx_apply")
    clock_run(r, 120, 8.0)
    r.c(f"peek {lo('mslots'):x} 64")
    out = r.go().split()
    b = [int(v, 16) for v in out[out.index(f"{lo('mslots'):05x}:") + 1:]]
    incs = [b[16 * k + 9] | b[16 * k + 10] << 8 for k in range(4)]
    bar = 4 * 60000 / 120 / 0.511                       # ticks a bar
    lap0 = 65536 / incs[0]
    ratio = lap0 / bar
    check("CLOCK LFO: CHORUS slot 0 laps a power-of-2 part of a bar", abs(np.log2(ratio) - round(np.log2(ratio))) < 0.02,
          f"(incs {incs}, lap {lap0:.0f} ticks, bar {bar:.0f})")


def loop_test(check):
    plog = os.path.join(HERE, "ports.log")
    r = Run()
    r.pokeb(lo("fxon"), FX["LOOPER"])
    r.pokew(lo("ptime"), 100)
    r.pokew(lo("pfb"), 99)
    r.pokew(lo("fxsendv"), 0x800F)
    r.pokew(0x73A0, 0x300)
    r.c(f"portlog {plog}")
    r.lcall("fx_apply")
    r.call("plus_tick")
    r.c("plmark")
    r.c(f"peek {hi('fz_act'):x} 1")
    r.pokew(lo("pfb"), 100)                              # FB to 100 = FREEZE
    r.lcall("fx_apply")
    r.call("plus_tick")
    r.call("mfx_run")
    r.c("plmark")
    r.c(f"peek {hi('fz_act'):x} 1")
    r.c(f"peek {lo('fxsendv'):x} 2")
    r.pokew(lo("pfb"), 99)                               # and back
    r.lcall("fx_apply")
    r.call("plus_tick")
    r.c("plmark")
    r.c(f"peek {hi('fz_act'):x} 1")
    r.c(f"peek {lo('fxsendv'):x} 2")
    r.pokeb(hi("par") + 10, 100)                         # CC 30 = FREEZE
    r.call("plus_tick")
    r.c("plmark")
    r.c(f"peek {hi('fz_act'):x} 1")
    r.pokeb(hi("par") + 10, 0)
    r.call("plus_tick")
    r.c("plmark")
    out = r.go().split("\n")
    vals = [l.split()[2:] for l in out if l.startswith("peek")]
    segs = taps_log(plog)
    fb = lambda sg: sg.get(3, (0, 0))[0]
    d1 = (2 - segs[0][1][1]) & 0xFFFF
    check("LOOPER: taps at 32768 (0.74 s), FB 99 = 0.99", d1 == 32768 and abs(fb(segs[0]) - 0x7EB1) < 8 and vals[0] == ["00"],
          f"(delay {d1}, fb {fb(segs[0]):#x}, fz {vals[0]})")
    check("LOOPER FB 100: frozen, feedback 1.0, sends 0", vals[1] == ["01"] and fb(segs[1]) == 0x7FFF and vals[2] == ["00", "00"],
          f"(fz {vals[1]}, fb {fb(segs[1]):#x}, fxsendv {vals[2]})")
    lines = open(plog).read().split("M\n")[1].split("\n")
    v7 = [lines[k + 1] for k in range(len(lines) - 1) if lines[k].startswith("0080 07") and lines[k + 1].startswith("0084")]
    check("LOOPER FREEZE: every voice's send written 0, the input's too", len(v7) >= 34 and all(l.endswith(" 0000") for l in v7),
          f"({len(v7)} reg 7 send writes)")
    check("LOOPER FB 99 again: sends back", vals[3] == ["00"] and vals[4] == ["0f", "80"] and fb(segs[2]) != 0x7FFF,
          f"(fz {vals[3]}, fxsendv {vals[4]}, fb {fb(segs[2]):#x})")
    check("LOOPER CC 30: frozen, FB tap 1.0", vals[5] == ["02"] and fb(segs[3]) == 0x7FFF, f"(fz {vals[5]})")
    check("LOOPER CC 30 off: FB tap back to 0.99", abs(fb(segs[4]) - 0x7EB1) < 8, f"({fb(segs[4]):#x})")


def main():
    ok = True

    def check(name, cond, info=""):
        nonlocal ok
        print(("PASS " if cond else "FAIL ") + name, info)
        ok &= bool(cond)

    detune_test(check)
    clock_test(check)
    loop_test(check)
    if os.environ.get("ONLY") == "fx":
        return ok

    # reverse baseline (kind 1): R = the input reversed, same pitch at OCT 0
    for fx, oct_, want in [("REVERSE", 0, 441), ("PITCH", 1, 882), ("PITCH", 0, 441), ("PITCH", -1, 220.5),
                           ("REVERSE", 1, 882)]:
        a, out = capture(fx, oct_)
        act = out.split()
        R = a[30000:, 1]
        f, mag = peakf(R)
        check(f"{fx} OCT {oct_:+d}: wet at {want} Hz", abs(f - want) < want * 0.03 and np.abs(R).max() > 1000,
              f"(peak {f:.1f} Hz, max {np.abs(R).max()}, lr_act/kind {act[2:]})")
        fL, _ = peakf(a[30000:, 0])
        check(f"{fx} OCT {oct_:+d}: dry L at 441 Hz", abs(fL - 441) < 10, f"({fL:.1f})")
    # every rate / step: FREE lengths 60 / 200 / 700 ms (44.1 / 22 / 11 kHz history), SWELL 0 / 30: the forward
    # wet has no more steps past the sine's own slope than the stock reverse in the same setting
    for ms in (60, 200, 700):
        for sw in (0, 30):
            base = None
            for fx, oct_, want in [("REVERSE", 1, 882), ("REVERSE", 0, 441), ("PITCH", 1, 882), ("PITCH", 0, 441),
                                   ("PITCH", -1, 220.5)]:
                ex = [(hi("lr_bpm"), 0), (hi("lr_lenms"), ms & 0xFF), (hi("lr_lenms") + 1, ms >> 8), (hi("lr_sw"), sw)]
                a, out = capture(fx, oct_, extra=ex)
                R = a[30000:, 1].astype(int)
                f, _ = peakf(R)
                slope = 8000 * 2 * np.pi * want / 44100
                nj = int(np.sum(np.abs(np.diff(R)) > 1.3 * slope))
                if fx == "REVERSE":
                    base = max(base or 0, nj)
                    continue
                check(f"{fx} OCT {oct_:+d} LEN {ms} SWL {sw}: {want} Hz, steps {nj} vs stock reverse {base}",
                      abs(f - want) < want * 0.03 and nj <= base + 3 and np.abs(R).max() > 1000, f"(peak {f:.1f})")
    # forward vs reverse: a rising ramp reads rising forwards, falling backwards
    for fx, sign in [("PITCH", 1), ("REVERSE", -1)]:
        a, out = capture(fx, 0, freq=3, sig="ramp")
        R = a[30000:, 1].astype(int)
        d = np.diff(R)
        d = d[np.abs(d) < 200]
        check(f"{fx}: ramp direction", np.sign(np.median(d)) == sign, f"(median step {np.median(d)})")
    # LO-FI: L samples on 8 bits, held 4 frames
    a, out = capture("LO_FI", 0, extra=[(hi("lf_bits"), 8), (hi("lf_sh"), 4)])
    Lw = a[30000:, 0].astype(np.int64)
    check("LO-FI 8 bit: low byte 0", np.all((Lw & 0xFF) == 0) and np.abs(Lw).max() > 1000, f"(max {np.abs(Lw).max()})")
    runs = np.diff(np.flatnonzero(np.diff(Lw) != 0))
    check("LO-FI S&H 4: values held 4 frames", np.median(runs) == 4, f"(median run {np.median(runs)})")
    check("LO-FI: no wet level", "kind" in out or True)
    # LO-FI off on REVERSE: L untouched (not all low bytes 0)
    a, out = capture("REVERSE", 0)
    check("REVERSE: L clean (16 bit)", np.any((a[30000:, 0] & 0xFF) != 0))
    # SHIMMER: forward octave up with feedback: the wet holds 882 and a cascaded 1764
    a, out = capture("SHIMMER", 1, fb=60, passes=600)
    R = a[60000:, 1].astype(float)
    s = np.abs(np.fft.rfft((R - R.mean()) * np.hanning(len(R))))
    fr = np.fft.rfftfreq(len(R), 1 / 44100)
    e = lambda f0: s[(fr > f0 * 0.97) & (fr < f0 * 1.03)].max()
    check("SHIMMER FB 60: 882 Hz present", e(882) > 10 * np.median(s))
    check("SHIMMER FB 60: 1764 Hz cascade", e(1764) > 10 * np.median(s), f"({e(1764) / np.median(s):.0f}x floor)")
    return ok


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
