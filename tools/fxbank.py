"""Rosetta FX bank -> build/hi_fx.inc (NASM), assembled into the hi code (src/rosetta_hi.asm, 0.22+); the
menu code (src/rosetta_fx.asm) reads it through `fxhdr`, which the hi code points at `hifx` when it loads.

Engine model (measured 2026-10-13, see README): one 65536-sample line @ 44.1 kHz, 30 taps on reg A
functions 1-10, 12-31. Tap = gain word (Q15, low 2 bits = route: 1 = L out, 0 = R out, 3 = feedback)
+ length word (2 - delay in samples). Static taps are written once; LFO slots drive a pair of taps
(even/odd delay) whose gains crossfade for fractional delays (chorus / flanger), updated every 2 ms tick.

Header hifx: dw preset_ptrs, fx_short, sintab (all as MENU_SEG offsets: + LOREL), db NPRESETS.
rev_tab: 4 bytes per preset for the REVERSE engine (src/rosetta_rev.asm): db on, chunk slices (512 samples,
  scaled by the page's TIME %), use the page's FEEDBACK as reverse feedback, octave up.
Preset record: name[8], db fbmax (FEEDBACK % limit: loop sum stays < 0.97; 0 = no feedback), nstatic, nmod,
  nstatic x (db fn, dw gainword, dw lenword-delay)   [delay in samples, the asm turns it into 2 - delay]
  nmod    x (db fnE, fnO, route, dw gain, center, depth, inc, phase0)
"""
import json
import math
import os

SR = 44100
TICK_HZ = 2_000_000 / 4087          # TCU ch0 count 4087 @ 2 MHz
L, R, FB = 1, 0, 2
FNS = [f for f in range(1, 32) if f != 11]
HERE = os.path.dirname(os.path.abspath(__file__))
FXDIR = os.path.join(HERE, "..", "src", "fx")


def ms(x):
    return int(round(SR * x / 1000))


def gw(g, route):
    q = int(round(g * 32767))
    assert -32768 <= q <= 32767, g
    return ((q & 0xFFFC) | (3 if route == FB else route)) & 0xFFFF


def mod(fne, fno, route, gain, center_ms, depth_ms, rate_hz, phase_deg=0, off=0):
    c, d = ms(center_ms) + off, ms(depth_ms)
    assert c - d >= 2 and c + d + 1 < 65535, (center_ms, depth_ms)
    return dict(fne=fne, fno=fno, route=route, gain=gain, center=c, depth=d,
                inc=int(round(65536 * rate_hz / TICK_HZ)), phase=int(phase_deg / 360 * 65536) & 0xFFFF)


def saw(fne, fno, route, gain, center, depth, inc, phase):
    """0.28 pitch-shift slot (lo lfo_run, route bit 7): the delay ramps center - depth .. center + depth over a
    lap of the phase (a sawtooth, not a sine) and the gain follows a sin^2 window that is 0 at the wrap, so the
    jump back is silent; two slots half a lap apart sum to a steady level. Pitch ratio = 1 - 2 depth inc /
    (65536 x samples a tick): depth < 0 = the delay shrinks = sharp. center / depth in samples, inc a tick
    (the OS tick: 0.511 ms = 22.5 samples)."""
    assert center - abs(depth) >= 2 and center + abs(depth) + 1 < 65535
    return dict(fne=fne, fno=fno, route=route, gain=gain, center=center, depth=depth, inc=inc,
                phase=phase & 0xFFFF, saw=True)


def from_json(name):
    taps = json.load(open(os.path.join(FXDIR, name + ".json")))
    assert len(taps) <= 30
    return [(fn, g, r, d) for fn, (g, r, d) in zip(FNS, taps)]


def bank():
    """(name, static taps [(fn, gain, route, delay)], mod slots[, reverse (slices, feedback default or None,
    octave)])."""
    T1, T2 = ms(375), ms(300)
    stock = [
        ("OFF", [], []),
        ("ROOM", from_json("room"), []),
        ("HALL", from_json("hall"), []),
        ("PLATE", from_json("plate"), []),
        ("ECHO", [(1, 0.6, L, T1), (2, 0.6, R, T1), (3, 0.4, FB, T1)], []),
        ("PINGPONG", [(1, 0.6, L, T2), (2, 0.6, R, 2 * T2), (3, 0.5, FB, 2 * T2)], []),
        ("CHORUS", [], [mod(1, 2, L, 0.55, 15, 2.5, 0.6, 0), mod(3, 4, R, 0.55, 17, 2.5, 0.6, 90),
                        mod(5, 6, L, 0.4, 22, 1.8, 0.43, 180), mod(7, 8, R, 0.4, 24, 1.8, 0.43, 270)]),
        ("FLANGER", [], [mod(1, 2, L, 0.75, 2.6, 2.2, 0.2, 0), mod(3, 4, R, 0.75, 2.6, 2.2, 0.2, 30),
                         mod(5, 6, FB, 0.55, 2.6, 2.2, 0.2, 0)]),
    ] + sp404()
    hall = from_json("hall")
    # 0.28: d = 220 samples, inc 16 -> 2 x 220 x 16 / (65536 x 22.535) = 0.48 % = 8 cents, a 2.1 s lap
    det = [saw(1, 2, L, 0.7, 240, -220, 16, 0), saw(3, 4, L, 0.7, 240, -220, 16, 0x8000),
           saw(5, 6, R, 0.7, 240, 220, 16, 0x4000), saw(7, 8, R, 0.7, 240, 220, 16, 0xC000)]
    LP = 32768                                    # LOOPER: 0.74 s at TIME 100 (25-200 %: 0.19-1.49 s)
    loop = [(1, 0.9, L, LP), (2, 0.9, R, LP), (3, 0.99997, FB, LP)]
    extra = [("DETUNE", [], det, None),           # micro pitch shift: L +8 cents, R -8 (TIME / RATE = more)
             ("LOOPER", loop, [], None),          # FB 99 = a slow fade, FB 100 = FREEZE (sends cut, gain 1.0)
             # live input only (SAMPLE page), the live-reverse engine reading forwards (kind 2) / crusher only (3)
             ("PITCH", [], [], (34, None, 0, 2)),
             ("SHIMMER", hall, [], (34, None, 0, 2)),
             ("LO-FI", [], [], (34, None, 0, 3))]
    return [p + (None,) for p in stock] + extra + [
        # reverse delays: each chunk of the delay line plays back flipped (TIME scales the chunk). One REVERSE
        # since 0.24 (the user: SHRT / LONG / ECHO / OCT / PING are its knobs now: length, FB, OCT, PING on the
        # MFX REV menu, src/rosetta_rvui.asm) + REV HALL
        ("REVERSE", [], [], (34, None, 0)),       # 0.39 s
        ("REV HALL", hall, [], (40, None, 0)),    # the hall's tail flipped: swells into the note
    ]


def sp404():
    """SP-404 style (0.27). JUNO: the Juno-60 chorus trick, one BBD-like line, L = +wet, R = -wet (with the centred
    dry: L = dry + wet, R = dry - wet), 0.5 Hz, 1.7-5.3 ms. TAPE: echo with wow on every tap (the repeats wobble
    more each pass) and two feedback taps 2 samples apart (each repeat a bit darker). DUB: long dark echo, a
    3-tap [1 2 1] FIR in the loop (-5 dB at 10 kHz per repeat), R 12 ms later. RESO: a comb resonator, C3 at
    TIME 100 (TIME 25-200 = C5 down to C2), FEEDBACK = ring time."""
    P, N = ms(520), ms(1000 / 130.81)
    return [
        ("JUNO", [], [mod(1, 2, L, 0.7, 3.5, 1.8, 0.5, 0), mod(3, 4, R, -0.7, 3.5, 1.8, 0.5, 0)]),
        ("TAPE", [], [mod(1, 2, L, 0.6, 330, 0.6, 0.8, 0), mod(3, 4, R, 0.6, 345, 0.6, 0.8, 40),
                      mod(5, 6, FB, 0.25, 330, 0.6, 0.8, 0), mod(7, 8, FB, 0.25, 330, 0.6, 0.8, 0, off=2)]),
        ("DUB", [(1, 0.6, L, P), (2, 0.6, R, P + ms(12)),
                 (3, 0.15, FB, P), (4, 0.3, FB, P + 1), (5, 0.15, FB, P + 2)], []),
        ("RESO", [(1, 0.5, L, N), (2, 0.5, R, N), (3, 0.9, FB, N)], []),
    ]


def fbmax(static, mods):
    """FEEDBACK % ceiling: total |feedback gain| <= 0.97 and no single gain past 0.999 (Q15)."""
    g = [abs(gn) for fn, gn, r, d in static if r == FB] + [abs(m["gain"]) for m in mods if m["route"] == FB]
    if not g:
        return 0
    return int(min(250, 97 / sum(g), 99.9 / max(g)))


def nasm(presets):
    out = [f"NPRESETS equ {len(presets)}",
           "hifx:   dw preset_ptrs + LOREL, fx_short + LOREL, sintab + LOREL",
           "        db NPRESETS",
           "rev_tab:"]
    for name, static, mods, rev in presets:
        if rev:
            kind = rev[3] if len(rev) > 3 else 1
            out.append(f"        db {kind}, {rev[0]}, {1 if rev[1] else 0}, {rev[2]}   ; {name}")
        else:
            out.append(f"        db 0, 0, 0, 0             ; {name}")
    for i, (name, *_) in enumerate(presets):           # 0.28: FXI_<name> = its index (the hi code)
        out.append(f"FXI_{''.join(c if c.isalnum() else '_' for c in name)} equ {i}")
    out.append("preset_ptrs:")
    out += [f"        dw fxp{i} + LOREL" for i in range(len(presets))]
    for i, (name, static, mods, rev) in enumerate(presets):
        assert len(name) <= 8, name
        assert not (rev and len(rev) > 3 and rev[3] != 1 and mods), name   # (kind 2 / 3 run no LFO slots)
        used = [fn for fn, *_ in static] + [f for m in mods for f in (m["fne"], m["fno"])]
        assert len(used) == len(set(used)) and all(f in FNS for f in used), name
        assert len(mods) <= 4
        fbm = rev[1] if rev and rev[1] else fbmax(static, mods)   # REV ECHO: FEEDBACK = reverse repeats
        if name == "LOOPER":
            fbm = 100                                 # 100 = FREEZE (hi code)
        if rev and len(rev) > 3:
            fbm = 99                                  # PITCH / SHIMMER / LO-FI: FB = the input history's feedback
        out.append(f"fxp{i}:   db '{name:<8}', {fbm}, {len(static)}, {len(mods)}")
        for fn, g, r, d in static:
            assert 2 <= d <= 65535
            out.append(f"        db {fn}\n        dw {gw(g, r):#06x}, {d}")
        for m in mods:
            q = int(round(m["gain"] * 32767))
            out.append(f"        db {m['fne']}, {m['fno']}, {(3 if m['route'] == FB else m['route']) | (0x80 if m.get('saw') else 0)}")
            out.append(f"        dw {q & 0xFFFF:#06x}, {m['center']}, {m['depth']}, {m['inc']}, {m['phase']:#06x}")
    short = {"PINGPONG": "PING", "CHORUS": "CHORS", "FLANGER": "FLANG", "REVERSE": "REV", "REV SHRT": "RVSHT",
             "REV LONG": "RVLNG", "REV ECHO": "RVECH", "REV OCT": "RVOCT", "REV HALL": "RVHAL", "REV PING": "RVPNG",
             "DETUNE": "DETUN", "LOOPER": "LOOP", "SHIMMER": "SHIMR"}
    out.append("fx_short:                      ; 5-char names for HOME line 2")
    for name, *_ in presets:
        sn = short.get(name, name)[:5]
        out.append(f"        db '{sn.center(5)}'")
    out.append("sintab:")
    tab = [int(round(16384 * math.sin(2 * math.pi * k / 256))) & 0xFFFF for k in range(256)]
    out += ["        dw " + ", ".join(f"{v:#06x}" for v in tab[k:k + 16]) for k in range(0, 256, 16)]
    return "\n".join(out) + "\n"


def write_inc(build_dir):
    p = os.path.join(build_dir, "hi_fx.inc")
    open(p, "w").write(nasm(bank()))
    return p


if __name__ == "__main__":
    print(nasm(bank())[:2000])
