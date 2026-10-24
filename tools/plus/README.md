# Rosetta+ tests

- `harness.c` + `cpu.c` / `emu.h` (the s2k emulator's V53 core): runs the built hi / lo binaries with stubbed
  OS calls, a simulated ADC (DMA ch2) and chip input DMA (ch3), and a port log.
  `gcc -O2 -o harness harness.c cpu.c -lm`
- `rtest.py`: live input (REVERSE / PITCH / SHIMMER / LO-FI at every history rate, compared with the stock
  reverse), DETUNE (the port log rendered through a model of the delay engine: +-8 cents), MIDI clock (tempo,
  echo taps, LFO lock, no writes while the tempo holds), LOOPER freeze. 55 checks.
  `RW=../../build python3 rtest.py` (paths: see the top of the file)
- `choptest.py`: CHOP on the full OS (the s2k emulator, `s2kemu`, not included here): EQUAL / TRANS / LAZY,
  slice audio, program + keygroups, audition. 11 checks.
