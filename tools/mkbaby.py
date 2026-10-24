"""Build a patched S2000 OS disk.

  python mkbaby.py stock_disk.img template.hfe out_prefix

Patches are (offset in OS file, stock bytes, new bytes); every stock value is
asserted first, so a wrong base image fails loudly instead of building junk.
The OS file is the 256 KB type-0x63 file at block 17 of the stock OS disk.
"""
import os
import struct
import subprocess
import sys

OS_BLOCK, OS_SIZE = 17, 0x40000
VERSION = "0.28"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# NASM: $NASM, else the author's copy next to the GP-16 project, else `nasm` on PATH
_NASM_LOCAL = os.path.join(ROOT, "..", "esp32_utility_box", "gp16", "tools", "nasm-2.16.03", "nasm.exe")
NASM = os.environ.get("NASM") or (_NASM_LOCAL if os.path.exists(_NASM_LOCAL) else "nasm")

# boot dragon: runs before init from the load.asm object junk at the top of the image
JUNK_LO, JUNK_HI = 0x3E01B, 0x40000   # leftover OMF object (no refs), reused as RAM after boot
DRAGON_SEG = 0x3E20                   # blob at linear 0x3E200, private stack up to +0x800
DRAGON_SPAN = 0x800
MENU_SEG = 0x3EA0                     # permanent Rosetta code at linear 0x3EA00 (src/rosetta_menu.asm), right after the dragon
MENU_SPAN = 0x1600                    # up to the end of the junk (0x40000)
LOAD_SEG = 0x3E02                     # hi-code loader (src/rosetta_load.asm) in the junk before the dragon
LOAD_SPAN = 0x1E0                     # up to the dragon (0x3E200)
BANNER = (" JSW ROSETTA OS ", f"  S2000  v{VERSION}  ")

AKAI_CHARS = "0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ#+-."

SEG_MAIN = 0x0FE4      # main-loop code segment (entry ljmp 0FE4:0002, init returns to 0FE4:0007)
SHOW_MSG = 0x0D6B      # 0FE4:0D6B far-style popup: BX = 0xFF-terminated 2x16 message (DS=0)
INIT_CALL = 0x0007     # 0FE4:0007 call 0x0073 = one-shot init before main loop
HOOK = 0xF6B2          # 0FE4:F6B2..F6BF = 14 zero bytes of alignment pad before segment 1F50
MSG = 0x2D5C           # "Searching for   AKAI SCSI disk " (31 chars + FF), only used on SCSI scan


def akai(s):
    return bytes(AKAI_CHARS.index(c) for c in s)


def lin(seg, off):
    return (seg << 4) + off


def near_call(at, target):
    return b"\xE8" + ((target - (at + 3)) & 0xFFFF).to_bytes(2, "little")


def boot_hook():
    h = HOOK
    code = near_call(h, 0x0073)                 # original init
    code += b"\x53"                             # push bx
    code += b"\xBB" + MSG.to_bytes(2, "little")  # mov bx, MSG
    code += b"\x0E"                             # push cs (far frame for SHOW_MSG's retf)
    code += near_call(h + len(code), SHOW_MSG)
    code += b"\x5B\xC3"                         # pop bx; ret
    return code


def nasm_blob(build_dir, src, extra=()):
    out = os.path.join(build_dir, os.path.splitext(os.path.basename(src))[0] + ".bin")
    sep = os.sep
    subprocess.run([NASM, "-f", "bin", "-o", out, *extra,
                    "-i", os.path.join(ROOT, "src") + sep, "-i", os.path.join(ROOT, "art") + sep,
                    "-i", build_dir + sep, os.path.join(ROOT, "src", src)], check=True)
    return open(out, "rb").read()


def build_menu(build_dir):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import fxbank
    fxbank.write_inc(build_dir)                 # FX presets + sine table (tools/fxbank.py)
    mapf = os.path.join(build_dir, "rosetta_menu.map")
    pre = os.path.join(build_dir, "lo_map_pre.inc")
    with open(pre, "w") as f:
        f.write(f"[map symbols {mapf}]\n")
    blob = nasm_blob(build_dir, "rosetta_menu.asm", [f"-DLOAD_SEG={LOAD_SEG:#x}", "-P", pre])
    lo_syms(build_dir, mapf)
    lo = lin(MENU_SEG, 0)
    assert JUNK_LO <= lo and lo + MENU_SPAN <= JUNK_HI and len(blob) <= MENU_SPAN
    assert lo >= lin(DRAGON_SEG, 0) + DRAGON_SPAN, "menu code overlaps the dragon"
    return blob


def lo_syms(build_dir, mapf):
    """build/lo_syms.inc: LO_<label> equ <offset in MENU_SEG> for every global lo label (for the hi code, which
    patches and calls lo at run time)."""
    import re
    out = []
    for line in open(mapf):
        m = re.match(r"^\s*([0-9A-Fa-f]+)\s+([0-9A-Fa-f]+)\s+([A-Za-z_]\w*)\s*$", line)
        if m:
            out.append(f"LO_{m.group(3)} equ 0x{int(m.group(1), 16):04X}")
    assert any(o.startswith("LO_fxsend ") for o in out), "no lo symbols parsed from the NASM map"
    with open(os.path.join(build_dir, "lo_syms.inc"), "w") as f:
        f.write("\n".join(out) + "\n")


def build_dragon(build_dir):
    """Assemble src/s2k_dragon.asm with the banner; returns the blob."""
    assert all(len(s) == 16 for s in BANNER), BANNER
    inc = os.path.join(build_dir, "dragon_banner.inc")
    with open(inc, "w") as f:
        f.write(f"line1: db '{BANNER[0]}'\nline2: db '{BANNER[1]}'\n")
    out = os.path.join(build_dir, "s2k_dragon.bin")
    sep = os.sep
    # speed: one delay step ~29 ms per DLY_OUTER unit on hw (0.04: DLY_OUTER=1 flew in ~1.5 s, "way too fast")
    defs = [f"-D{k}={os.environ[k]}" for k in ("DLY_OUTER", "HOLD_STEPS") if os.environ.get(k)]
    subprocess.run([NASM, "-f", "bin", "-o", out, *defs,
                    "-i", os.path.join(ROOT, "src") + sep, "-i", os.path.join(ROOT, "art") + sep,
                    "-i", build_dir + sep, os.path.join(ROOT, "src", "s2k_dragon.asm")], check=True)
    blob = open(out, "rb").read()
    assert len(blob) < DRAGON_SPAN - 0x100, f"dragon blob {len(blob)} B too close to its stack"
    lo = lin(DRAGON_SEG, 0)
    assert JUNK_LO <= lo and lo + DRAGON_SPAN <= JUNK_HI
    return blob


# 0.03's post-init popup ("ROSETTA OS vX / dragon was here") waits for a key press -> costs a press per boot.
# The dragon is the splash now, so it's off by default (set BOOT_POPUP=1 to bring it back).
BOOT_POPUP = os.environ.get("BOOT_POPUP") == "1"
assert not BOOT_POPUP, "the 0FE4:F6B2 pad now holds the SysEx stub; the boot popup can't come back without new space"

PATCHES = [
    # SAVE page, type "System": shown next to GO
    (0x2F9CE, b"VERSION 2.00", f"ROSETTA {VERSION}".encode()),
    # splash text (2 lines x 16, line 2 is 15 chars + FF terminator)
    (MSG, b"Searching for   AKAI SCSI disk ", f"ROSETTA OS v{VERSION}dragon was here".encode()),
    # menu flow: mode entry page-0 write -> far call MENU_SEG:0000 (LOAD/SAVE skip DISK/FLASHROM w/o flash)
    (lin(SEG_MAIN, 0x03B1), bytes.fromhex("C6062C7600"), b"\x9A\x00\x00" + MENU_SEG.to_bytes(2, "little")),
    # Rosetta FX (no EB16): EFFECTS toggles the L7A1045 delay engine with the unused reverb preset,
    # and reg7 word1 writes get the delay-engine send while it's on (src/rosetta_menu.asm +3/+6/+9)
    (lin(SEG_MAIN, 0x03CB), bytes.fromhex("C6062B7606"), bytes.fromhex("9A0300") + MENU_SEG.to_bytes(2, "little")),
    (lin(0x2345, 0x50EE), bytes.fromhex("8B848400E784"), bytes.fromhex("9A0600") + MENU_SEG.to_bytes(2, "little") + bytes.fromhex("90")),
    (lin(0x2345, 0x41A8), bytes.fromhex("8B4422E784"), bytes.fromhex("9A0900") + MENU_SEG.to_bytes(2, "little")),
    (lin(0x2345, 0x5480), bytes.fromhex("8B848400E784"), bytes.fromhex("9A0600") + MENU_SEG.to_bytes(2, "little") + bytes.fromhex("90")),
    # no program active -> notes (PLAY + MIDI) audition the current sample: the note-on dispatcher's
    # "0 active programs -> exit" (0FE4:CA0C jmp CAA4) jumps to the sample-page audition branch (C9D4) instead
    (lin(SEG_MAIN, 0xCA0C), bytes.fromhex("E99500"), bytes.fromhex("E9") + ((0xC9D4 - (0xCA0C + 3)) & 0xFFFF).to_bytes(2, "little")),
    # SysEx lab backdoor (F0 7D 53 ...): SysEx start sets the handler via MENU_SEG:000C; the data-byte
    # handler must be near in 0FE4, so the (now free, popup off) 14-byte pad holds `lcall 3F00:000F; ret`
    (lin(0x2B9D, 0x00FB), bytes.fromhex("C706E67DCB63"), bytes.fromhex("9A0C00") + MENU_SEG.to_bytes(2, "little") + bytes.fromhex("90")),
    (lin(SEG_MAIN, HOOK), bytes(6), bytes.fromhex("9A0F00") + MENU_SEG.to_bytes(2, "little") + bytes.fromhex("C3")),
    # FX LFO: the main-loop wait's tick read (0FE4:000D lcall 2345:0A47) -> MENU_SEG:0015 (calls it, then
    # runs chorus/flanger slots once per tick)
    (lin(SEG_MAIN, 0x000D), bytes.fromhex("9A470A4523"), bytes.fromhex("9A1500") + MENU_SEG.to_bytes(2, "little")),
    # HOME (menu M1): main page 0 line 2 "    prog active" -> soft-key jobs + FX name (rewritten in RAM
    # by home_text on each HOME entry), and the page def drops its 4th field (active count at col 0 row 1)
    (0x2DDD3, b"    prog active", b"LOAD  OFF  EDIT"),
    (0x2E93, bytes([4]), bytes([3])),
    # FX page keys: the key dispatcher's event read (0FE4:0264 mov al,[73D4] + test al,0C0h) -> MENU_SEG:0018
    # (soft keys on page 0x0C are consumed there; everything else passes through unchanged)
    (lin(SEG_MAIN, 0x0264), bytes.fromhex("A0D473A8C0"), bytes.fromhex("9A1800") + MENU_SEG.to_bytes(2, "little")),
    # sampling screen (menu M3b, src/rosetta_rec.asm): REC opens on the meter + ARM page (mode 4 page 5),
    # its line 2 gets the SETUP label for the left soft key, and the end of a kept take (0FE4:3CE7
    # `mov byte [8215],0`) -> MENU_SEG:001B, which flags it so the main loop jumps to the sample select page
    (0x2E9C3, b"             ARM", b"SETUP        ARM"),
    (lin(SEG_MAIN, 0x3CE7), bytes.fromhex("C606158200"), bytes.fromhex("9A1B00") + MENU_SEG.to_bytes(2, "little")),
    # REC key = start/stop: the armed loop's key read -> MENU_SEG:001E (REC = GO), and a record step's DMA
    # wait (2345:27EB `call 27F8` + `jb 27F7`) -> MENU_SEG:0021 (watches the key, ends the take early)
    (lin(SEG_MAIN, 0x3AA0), bytes.fromhex("A0D473C606D47300"), bytes.fromhex("9A1E00") + MENU_SEG.to_bytes(2, "little") + bytes.fromhex("909090")),
    (lin(0x2345, 0x27EB), bytes.fromhex("E80A007207"), bytes.fromhex("9A2100") + MENU_SEG.to_bytes(2, "little")),
    # MFX (0.24): the REC meter's draw (0FE4:3827 lcall 2345:0B0B) -> MENU_SEG:0024, skipped while the MFX
    # page sits over the meter page
    (lin(SEG_MAIN, 0x3827), bytes.fromhex("9A0B0B4523"), bytes.fromhex("9A2400") + MENU_SEG.to_bytes(2, "little")),
    # data-key auto-repeat (ticks 0.511 ms on hw, measured 2026-10-14; TCU ch0 4087 @ 8 MHz): first repeat 1000 -> 300,
    # interval start 200 -> 80, floor 40 -> 10 (step stays 10, so it lands exactly on the floor)
    (0x23C49, (1000).to_bytes(2, "little"), (300).to_bytes(2, "little")),
    (0x23C56, bytes([200]), bytes([80])),
    (0x23CA0, bytes([0x28]), bytes([10])),
    # boot dragon hook: 0FE4:0002 ljmp 1F50:0000 -> ljmp DRAGON_SEG:0000 (dragon ends with ljmp 1F50:0000)
    (lin(SEG_MAIN, 0x0002), bytes.fromhex("EA0000501F"), b"\xEA\x00\x00" + DRAGON_SEG.to_bytes(2, "little")),
] + ([
    # boot hook: redirect the one-shot init call into the pad stub
    (lin(SEG_MAIN, INIT_CALL), near_call(INIT_CALL, 0x0073), near_call(INIT_CALL, HOOK)),
    (lin(SEG_MAIN, HOOK), bytes(len(boot_hook())), boot_hook()),
] if BOOT_POPUP else []) + [
    # default program header name (Akai charset), 3 copies: id 01, kg ptr, name[12]
    (off, akai("TEST PROGRAM"), akai(f"ROSETTA {VERSION}"))
    for off in (0x1629, 0xA0D3, 0x1EE88)
]


# High code (0.19): CPU RAM 0x40000-0x4FFFF is never written by the OS (emulator memuse map, no segment 0x4xxx
# in the code, and on hw it still held power-up junk after boot). The boot ROM loads only the first 256 KB of
# the OS file (0.18 test), so the hi code goes on the floppy right after it (chained into the OS file) and
# src/rosetta_load.asm reads it in on the first main-loop tick.
HI_SEG = 0x4000
HI_BLOCK = OS_BLOCK + OS_SIZE // 1024


def hi_tables(build_dir):
    """build/hi_tables.inc: hsin = 256-step sine (Q14), dtab = 32 per-voice detune spreads (-127..127, evenly
    spread and shuffled so neighbouring voices differ)."""
    import math
    import random
    sin = [round(16384 * math.sin(2 * math.pi * i / 256)) for i in range(256)]
    spread = [round(-127 + 254 * i / 31) for i in range(32)]
    random.Random(2000).shuffle(spread)
    with open(os.path.join(build_dir, "hi_tables.inc"), "w") as f:
        f.write("hsin: dw " + ", ".join(str(v) for v in sin) + "\n")
        f.write("dtab: db " + ", ".join(str(v) for v in spread) + "\n")


def build_hi(build_dir):
    """Assemble src/rosetta_hi.asm, padded to whole 1 KB blocks."""
    hi_tables(build_dir)
    vw = "0x%02d%02d" % tuple(int(x) for x in VERSION.split("."))  # 0.20 -> 0x0020, like VERSION_W
    pre = os.path.join(build_dir, "hi_map_pre.inc")
    with open(pre, "w") as f:
        f.write("[map symbols " + os.path.join(build_dir, "rosetta_hi.map") + "]" + chr(10))
    blob = nasm_blob(build_dir, "rosetta_hi.asm", [f"-DHI_VERSION={vw}", f"-DHI_BLOCK={HI_BLOCK}", "-P", pre])
    assert blob[:4] == b"RSHI" and len(blob) <= 0x5000, "hi code must stay below 0x45000 (0.28: live reverse history from there, src/rosetta_lrev.asm)"
    return blob + bytes(-len(blob) % 1024)


def build_loader(build_dir, nblk):
    blob = nasm_blob(build_dir, "rosetta_load.asm", [f"-DHI_BLOCK={HI_BLOCK}", f"-DHI_NBLK={nblk}"])
    lo = lin(LOAD_SEG, 0)
    assert JUNK_LO <= lo and lo + LOAD_SPAN <= lin(DRAGON_SEG, 0) and len(blob) <= LOAD_SPAN, len(blob)
    return blob


def extend_os(disk, blob):
    """Append blob to the OS file: size field + FAT chain past block 16 + OS_SIZE / 1024."""
    assert len(blob) % 1024 == 0
    ent = None
    for i in range(512):
        e = 0x1400 + 24 * i
        if disk[e + 16] == 0x63 and struct.unpack_from("<H", disk, e + 20)[0] == OS_BLOCK:
            ent = e
    assert ent is not None, "no OS entry"
    size = disk[ent + 17] | disk[ent + 18] << 8 | disk[ent + 19] << 16
    assert size == OS_SIZE, hex(size)
    last = OS_BLOCK + OS_SIZE // 1024 - 1
    assert struct.unpack_from("<H", disk, 0x600 + 2 * last)[0] == 0xC000
    nb = len(blob) // 1024
    for k in range(nb):
        b = last + 1 + k
        assert struct.unpack_from("<H", disk, 0x600 + 2 * b)[0] == 0, f"block {b} in use"
    for k in range(nb + 1):
        b = last + k
        struct.pack_into("<H", disk, 0x600 + 2 * b, b + 1 if k < nb else 0xC000)
    lo = (last + 1) * 1024
    disk[lo:lo + len(blob)] = blob
    new = size + len(blob)
    disk[ent + 17:ent + 20] = bytes([new & 0xFF, new >> 8 & 0xFF, new >> 16])
    assert last + 1 == HI_BLOCK
    print(f"  OS file {size:#x} -> {new:#x}: hi code {len(blob)} B at blocks {last + 1}-{last + nb} (loaded to {HI_SEG:04x}:0000)")


def main():
    disk_in, template, prefix = sys.argv[1:4]
    disk = bytearray(open(disk_in, "rb").read())
    os_off = OS_BLOCK * 1024
    osb = bytearray(disk[os_off:os_off + OS_SIZE])
    for off, old, new in PATCHES:
        assert len(old) == len(new), f"{off:#x}: length change"
        cur = bytes(osb[off:off + len(old)])
        assert cur == old, f"{off:#x}: expected {old!r}, found {cur!r}"
        osb[off:off + len(new)] = new
        print(f"  {off:#07x}  {old!r} -> {new!r}")
    blob = build_dragon(os.path.dirname(os.path.abspath(prefix)))
    lo = lin(DRAGON_SEG, 0)
    osb[lo:lo + len(blob)] = blob
    print(f"  {lo:#07x}  dragon blob {len(blob)} B (DRAGON_SEG {DRAGON_SEG:04x}:0000)")
    menu = build_menu(os.path.dirname(os.path.abspath(prefix)))
    syms = dict(l.split(" equ ") for l in open(os.path.join(os.path.dirname(os.path.abspath(prefix)), "lo_syms.inc")).read().split(chr(10)) if " equ " in l)
    assert menu[int(syms["LO_lfo_run"], 16) - 1] == 0xCB, "RETF_LO (rosetta_plus.asm): lfo_hook must end in retf"
    lo = lin(MENU_SEG, 0)
    osb[lo:lo + len(menu)] = menu
    print(f"  {lo:#07x}  menu blob {len(menu)} B (MENU_SEG {MENU_SEG:04x}:0000)")
    hi = build_hi(os.path.dirname(os.path.abspath(prefix)))
    ld = build_loader(os.path.dirname(os.path.abspath(prefix)), len(hi) // 1024)
    lo = lin(LOAD_SEG, 0)
    osb[lo:lo + len(ld)] = ld
    print(f"  {lo:#07x}  loader blob {len(ld)} B (LOAD_SEG {LOAD_SEG:04x}:0000, {len(hi) // 1024} KB from block {HI_BLOCK})")
    disk[os_off:os_off + OS_SIZE] = osb
    extend_os(disk, hi)
    if os.environ.get("TESTKIT", "1") == "1":       # CLICK / NOISE BURST / BEEP 1K on the boot floppy
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import testkit
        disk = bytearray(testkit.add_files(bytes(disk), testkit.kit_files()))
        print("  test kit:", ", ".join(f"{n} ({sz} B @blk {st})" for n, t, sz, st in testkit.listing(disk)[1:]))
    if os.environ.get("ROMPLER", "1") == "1":       # ROSETTA ROM: synth waves + programs (tools/rompler.py)
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import rompler
        import testkit
        files = rompler.build()
        disk = bytearray(testkit.add_files(bytes(disk), files))
        print(f"  rompler: {len(files)} files ({sum(len(b) for _, _, b in files) // 1024} KB): "
              + ", ".join(n for n, t, b in files if t != 0xF3))
    open(prefix + ".bin", "wb").write(osb)
    open(prefix + ".img", "wb").write(disk)
    hfe = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hfe.py")
    if template != "-":
        subprocess.run([sys.executable, "-I", hfe, "write", template, prefix + ".img", prefix + ".hfe"], check=True)


if __name__ == "__main__":
    main()
