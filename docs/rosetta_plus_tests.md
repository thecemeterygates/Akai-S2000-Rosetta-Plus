# Rosetta+ 0.28: hardware test plan

Not yet tested on hardware beyond booting. Please report what you hear (an Issue per feature is ideal).

## Tests
1. **Boot**: check for the `ROSETTA+ READY` popup and that HOME shows `ROSETTA 0.28`. Check that stock Rosetta things
   still work: HALL, ECHO, live REVERSE.
2. **CHOP EQUAL**: select a drum loop on the sample page, then MULTI → CHOP → GO → F2 F2 F2. Play C3 upwards. Does
   each key play one slice, cleanly?
3. **CHOP LAZY**: tap along to the hits. **Are the cuts early or late by a fixed amount?** If they are, tell me
   roughly how many ms. The tap timing reads the playing voice's position if the chip allows it, and otherwise
   counts time from GO.
4. **LOOPER**: set WET to 60 and FB to 90, play a phrase, then turn FB to 100 (freeze) and play over it. The new
   notes should be dry and the loop unchanged. Turn FB back down to 90 and check that it overdubs.
5. **CC 30 freeze** and **CC 31 clock sync**: send clock from a DAW and pick ECHO with CLK on. Do the repeats sit
   on the beat? Change the tempo and check that it follows within a few seconds.
6. **PITCH/SHIMMER**: on the sampling screen with MONITOR on, try PITCH OCT +1, then SHIMMER with FB 50. Report any
   crackles or dropouts, and whether the sampler stays responsive. The CPU is busier with this.
7. **LO-FI**: try BIT 8 and S&H 4 on the input.
8. **DETUNE**: on held chords. It uses moving taps, so **it may crackle like CHORUS does on hardware** (this is
   Rosetta's known open issue). Say whether it is better, worse or the same.

## Limits
- **DETUNE** shares the moving-tap crackle that is still open for CHORUS, FLANGER, JUNO and TAPE.
- **PITCH and SHIMMER** are granular, with one grain stream, so expect some chunk-rate pulsing. Use SWL and LEN to
  smooth it.
- **The longest live-reverse chunks** are about 10 % shorter, because the hi code grew into the start of the
  history buffer.
- **CHOP** works on the sample selected on the sample pages, and needs 2N+1 free header slots plus free sample
  memory.
- **Unfreezing** gives new notes their send back right away. Notes that were already sounding stay dry until they
  are played again.

