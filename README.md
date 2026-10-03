# Skull & Crossbones for MiSTer FPGA

A hardware recreation of Atari Games' 1989 arcade title **Skull & Crossbones**,
implemented as an FPGA core for the
[MiSTer](https://github.com/MiSTer-devel/Main_MiSTer/wiki) platform.

This is not a software port. The core reconstructs the original two-board set —
the game PCB **A046903-01** (schematic 046903-01 rev D) and the **JSA Audio II**
sound PCB **A047184-02** (schematic 046487-01 rev D) — from Atari's schematic
package in the kit manual and from the three PAL fuse dumps that ship with the
ROM set. MAME was used as a functional reference where the drawings are silent.
Where a schematic and MAME disagree, the schematic wins.

The two boards talk over the four-wire **J1 cable** between a pair of Atari
**SCOM** 137526-001 custom chips (120E on the game board, 3D on the audio
board), and the core models that serial link as the cable it is.

The core has been tested on DE10-Nano hardware by a number of users, with no
issues reported.

## Supported ROM sets

Five sets, one parent MRA and four alternatives. All five run on the **same
hardware** and differ only in the four 68000 program ROMs at 228A / 228C /
213A / 213C; the other 43 ROM files are identical across every set.

| MRA | MAME set | Revision |
| --- | --- | --- |
| `SkullXBones.mra` | `skullxbo` | rev 5 (parent) |
| `_alternatives/_Skull & Crossbones/Skull & Crossbones (rev 4).mra` | `skullxbo4` | rev 4 |
| `_alternatives/_Skull & Crossbones/Skull & Crossbones (rev 3).mra` | `skullxbo3` | rev 3 |
| `_alternatives/_Skull & Crossbones/Skull & Crossbones (rev 2).mra` | `skullxbo2` | rev 2 |
| `_alternatives/_Skull & Crossbones/Skull & Crossbones (rev 1).mra` | `skullxbo1` | rev 1 |

## Requirements

| Item | Requirement |
| --- | --- |
| Board | DE10-Nano (Cyclone V `5CSEBA6U23I7`) |
| SDRAM | **Required** — a standard 32 MB module (MT48LC16M16A2-class) |
| Display | Horizontal (ROT0) monitor, **672 × 240 visible at 59.92 Hz** |
| ROMs | Supplied by you from a MAME archive; none are included here |

**The SDRAM module is not optional.** The 512 KB 68000 program, the 640 KB of
playfield graphics, the 1.5 MB of sprite graphics and the 256 KB of ADPCM
samples all live in it (a 3,178,496-byte download), and there is no block-RAM
fallback. The controller expects the usual 4-bank × 13-bit-row × 9-bit-column
part, so a legacy 8 MB module will not work.

**Refresh rate.** The raster is 912 × 262 dots of the 14.318181 MHz pixel clock,
giving a 15.70 kHz line rate and **59.92 Hz**. The line count (262) is the one
timing number the schematics cannot confirm, because the vertical counter is
inside the SOS-2 custom chip; see [Open questions](#open-questions). If a
display refuses to lock, that is the first thing to check.

## Installation

1. Copy `releases/SkullXBones_YYYYMMDD.rbf` to `_Arcade/cores/` on the SD card.
2. Copy `releases/SkullXBones.mra` to `_Arcade/`, and any of the MRAs in
   `releases/_alternatives/` you want, keeping the `_alternatives` directory
   structure.
3. Place the matching MAME ROM archive (`skullxbo.zip`, or the clone's) in
   `games/mame/`.

**No ROM data is included in this repository, and none ever will be.** The MRA
builds the memory image from an archive you already own. With no ROMs present
the core stays on a black screen.

## Controls

The cabinet is a two-player upright: an 8-way joystick per player plus a
**Sword** button and a **Turn** button.

| Pad | Function |
| --- | --- |
| D-pad | 8-way joystick |
| A | **Sword** |
| B | **Turn** |
| Start | Start |
| Select | Coin |

`Sword` and `Turn` are the two cabinet buttons. `Start` is the JAMMA start pin,
which the board wires to each player's input port. The manual calls it
"development only" and the game is not known to use it, but because it is wired
it is offered for mapping. The port's other spare bit (JAMMA button 3) is not
used by the game either and is not offered.

The coin switches are read by the sound board's 6502, which has four coin
inputs, one per pad's **Select**. Pad 1 is MAME's *Coin 1* and pad 2 its
*Coin 2*, the pair the default "separate mechs" coin setting credits; pads 3
and 4 drive the other two inputs.

## Options

Skull & Crossbones has **no DIP switches**. Coinage, difficulty, bookkeeping and
the high-score table live in the on-board **28C16 EEPROM** and are changed from
the game's own self-test, reached with the OSD **Service** toggle. Settings are
kept through MiSTer's *Save Settings* (the MRA declares a 2048-byte NVRAM). On a
first boot with no saved settings the EEPROM is blank, exactly like a factory-new
chip: the game writes its own defaults and adds one to the self-test error
count, as the real board does.

| OSD item | Effect |
| --- | --- |
| Aspect ratio | Original / Full Screen / two user ratios |
| Orientation | Original / Flip |
| Scale | Normal / V-Integer / HV-Integer / Narrower HV-Integer |
| **Analog alignment** (page) | CRT H-Size, CRT H-Position, Analog VGA H-Shift, Analog VGA V-Shift |
| Service | the cabinet's self-test switch |
| Reset | core reset |

The analog alignment page is the same as in the
[Arcade-Badlands_MiSTer](https://github.com/MiSTer-devel/Arcade-Badlands_MiSTer),
[Arcade-Toobin_MiSTer](https://github.com/MiSTer-devel/Arcade-Toobin_MiSTer),
[Arcade-Klax_MiSTer](https://github.com/MiSTer-devel/Arcade-Klax_MiSTer) and
[Arcade-Xybots_MiSTer](https://github.com/MiSTer-devel/Arcade-Xybots_MiSTer)
cores, for centring and sizing the picture on an analog CRT. It works on the
output only: the core's own raster, pixel clock and refresh rate are
untouched, and at the default settings it is a bit-exact pass-through.

## Hardware baseline

| Block | Implementation |
| --- | --- |
| Main CPU | Motorola **68000** at 7.159 MHz — fx68k, cycle-exact |
| Protection | **none**: the SLAPSTIC socket is not populated on this board |
| Program ROM | 512 KB (eight EPROMs), served from SDRAM through a small cache |
| Video RAM | two 16-bit RAMs (playfield; alphanumerics + sprites + work RAM), CPU access arbitrated by **PAL16R8 110E** (`136072-2143`), implemented from its fuse dump |
| Raster | Atari **SOS-2** sync custom: 912 × 262 dots at 14.318181 MHz, **672 × 240 visible**, 59.92 Hz |
| Playfield | 64 × 64 map of 16 × 8 tiles, 4 bpp, the **SOS-1** shifter and the **PFHS** horizontal-scroll custom |
| Alphanumerics | 64 × 32 of 16 × 8 (8 × 8 characters drawn double width), 2 bpp; the off-screen columns carry per-row command words (scanline interrupt) |
| Motion objects | the **137593-001 MOB** custom, five-plane 16 × 8 stamps, and four discrete line-buffer RAMs |
| Priority | **PAL16L8 10F** (`136072-1142`), implemented from its fuse dump |
| Palette | 2048-entry colour RAM, IRGB 1555, R-2R DACs |
| Sound board | **JSA Audio II**: 6502 (T65) at 1.79 MHz, banked program ROM, **PAL16L8 2D** (`136056-2101`) from its fuse dump, periodic-interrupt divider |
| FM | **YM2151** (jt51) at 3.58 MHz with the YM3012 DAC |
| ADPCM | **MSM6295** at 1.19 MHz with its sample-rate pin live, samples from SDRAM |
| Analog stage | the volume ladder with its volume-dependent high-pass corner, the switchable low-pass filter, the ADPCM reconstruction filter and the mixer, modelled as fixed-point digital filters |
| NVRAM | **28C16** 2 KB EEPROM with the board's unlock / lock-after-write protection |
| Interrupts | IRQ1 = scanline (from the alphanumerics), IRQ2 = VBLANK, IRQ4 = sound |

The whole core runs in a single **57.272727 MHz** clock domain (4 × the
14.318181 MHz board crystal). Every chip clock is an integer division of it —
14.3 MHz ÷4, 7.16 MHz ÷8, 3.58 MHz ÷16, 1.79 MHz ÷32, 1.19 MHz ÷48 — used as a
clock enable, so there is no clock-domain crossing anywhere in the game logic.

Resource use on the DE10-Nano's Cyclone V for the bitstream in `releases/`:
**14,055 / 41,910 ALMs (34 %)**, 21,637 registers, **273 / 553 M10K blocks
(49 %)**, 2,006,461 of 5,662,720 memory bits (35 %), 67 / 112 DSP blocks
(60 %). Quartus 17.0.2 with multi-corner analysis: **0 errors and timing met on
all four corners** (worst `clk_sys` setup +2.162 ns, worst hold +0.078 ns). The
only timing exceptions in `SkullXBones.sdc` are the vendored cores' own
(fx68k's documented microcode constraint, T65 and jt51).

## Accuracy and verification

This core was developed with AI assistance. Because that raises a fair question
about whether the result was actually checked, here is the verification record.
Every claim below is backed by an automated check in the development
repository, and the checks are required to be able to fail: many first run
against deliberately broken versions of the design and fail if those pass.

**Schematics** — all ten game-board sheets and all three sound-board sheets were
transcribed before any RTL was written. Every address strobe has an equation
traced to a sheet and a chip. All three programmable chips on the two boards —
the video-RAM arbiter `136072-2143`, the priority PAL `136072-1142` and the
sound address decoder `136056-2101` — were decoded from their fuse dumps and
are implemented directly from the equations; the parts lists confirm there is no
other programmable chip on either board.

**Main CPU** — the 68000 bus is compared against MAME: **74,058 consecutive bus
cycles agree** (address, read/write, data, size) through reset, the ROM
checksum, the EEPROM check and the first sound interrupt.

**Video** — MAME was instrumented to capture the complete video state (playfield,
alphanumerics, sprite and colour RAM) at chosen frames; those states are played
through the real core RTL and the result is compared with MAME's own picture,
pixel for pixel. Across six captured sets (attract, the self-test screens, two
gameplay sessions, the BURIED BOOTY treasure screen and the first-coin message),
**65 of 67 frames are pixel-exact** and 576 of 10,789,680 compared dots differ,
all on two lines of the MOTION OBJECT TEST screen (see open question 3). Each
compared dot's RGB output is also checked against the DAC ladder: 0 wrong. The
priority PAL is checked exhaustively (all 1,048,576 input combinations), and
every other video block has its own focused test.

**Sound** — the sound board is compared against MAME the same way: the command
and response traffic between the boards, and the YM2151 and MSM6295 register
writes, match in order and value, and the periodic interrupt rate matches the
board's divider chain.

**Whole core** — the complete core (68000, 6502, YM2151, MSM6295, the video
pipeline and an SDRAM model) is fed the real 3,178,496-byte MRA download byte by
byte through the MiSTer download port. Every program word lands correctly in
SDRAM, the boot trace and the first sound round trip match MAME, and eight
attract frames come out pixel-exact with all graphics read from SDRAM. Running
the CPU live in this simulation is what reproduced the hardware faults below.

**ROM sets** — every ROM region is checked by hash for all five sets, and the MRA
byte stream is shown to rebuild the exact download image.

**This repository** — generated from the development repository by a script and
then checked by a second one: every file the Quartus project names exists here,
there are no absolute or private paths and no ROM data, `sys/` is the unmodified
framework, and the shipped bitstream is byte-identical to the one Quartus
produced.

**Hardware** — faults found on the DE10-Nano during bring-up, each fixed and now
covered by a check that fails on the old code:

- the MRA checksum was computed over the assembled image, but MiSTer checks each
  part's raw bytes, so the ROM was never sent;
- the MRA listed fewer button names than the core;
- the scanline interrupt never fired (the SOS-2's horizontal-blanking start was
  wrong), so the HUD was drawn 8 lines low;
- the motion-object custom read CPU accesses as sprite-list words, causing
  flickering streaks;
- pad 1's coin reached an input the game ignores;
- a long sprite list lost its last objects on a line (the BURIED BOOTY vase),
  fixed by reading each entry's Y/size word first, as a real-PCB recording
  shows;
- the line buffer showed one never-erased location at screen x = 0, leaving a
  dotted line down the left edge;
- the vertical-scroll counters kept counting through vertical blanking (a pin
  missed in the first transcription), which put stray dots on the top line and
  cut off the top of the first-coin message.

An SDRAM clock-phase sweep (225°, 245.5°, 270°, 294.5°) was clean at every
phase; 270° is used.

## Open questions

These are the places where the schematics cannot settle the behaviour. None of
them is known to cause a visible problem.

**1. 262 or 263 lines.** The vertical counter is inside the SOS-2 custom and is
not drawn. The core uses **262 lines / 59.92 Hz**, the same as MAME. A
measurement on a real board, or a dump of the SOS-2, would settle it.

**2. The right-most column.** Exactly where the SOS-2 starts horizontal blanking
is not drawn; the program's scanline-interrupt timing pins it to a range, and
the core uses a value inside it (the HUD lands on the correct line on
hardware). With that value the board's blanking signal clears the output on the
same clock edge that would show screen x = 671, and the core treats that column
as blanked; MAME draws it. A photograph of a real cabinet's right edge would
settle it.

**3. Two per-line timings.** The scanline interrupt's scroll writes land just
before the playfield scroll custom restarts for the next line, which puts the
HUD split on display line 216; a photograph of a real screen while the
playfield scrolls would confirm it. And the motion-object list is read one line
ahead of the line it fills, which is the whole 576-dot difference from MAME on
the MOTION OBJECT TEST screen (display lines 56 and 64). The core on hardware
shows exactly what the simulation predicts, but only a real board can say which
is right.

**4. Which JAMMA pin is which coin.** The four coin switches reach the sound
board on J1-36 / J1-35 / J1-31 / J1-33, and the manual does not say how those
map to the harness. The core follows MAME's order (pad 1 = Coin 1), which
credits correctly.

**5. The SDRAM read-capture phase.** The controller latches read data a fixed
number of clocks after each command, so whether data arrives in time depends on
the board, the SDRAM module and the clock phase sent to the chip; timing
analysis cannot check it. The phase used was swept on hardware (see above). If
graphics ever look corrupted on your setup, this is the first thing to suspect.

**6. The motion-object custom's internals.** The 137593-001 MOB is not dumped.
The per-line object limit follows from the surrounding hardware, and the
gameplay captures render exactly with it. The order in which it reads each
list entry's words is inferred: Y/size first, because the older order dropped
objects on hardware and a real-PCB recording shows them whole.

**7. The empty ROM half.** Addresses `0x060000`–`0x06FFFF` hold no program.
The sockets at 185A/185C are drawn for 27512s, but their ROM images are 32 KB
and sit in the upper half. A half-programmed 27512 would read `0xFF` in the
lower half and a 27256 would mirror the upper half; the drawing cannot say which
is fitted. The MRA fills the range with `0xFF`, and the program is not known to
read it.

## Building

Use Quartus Prime **17.0.2** (Lite or Standard), the version MiSTer standardises
on. Open `SkullXBones.qpf` and run a full compile, or from a shell:

```
quartus_sh --flow compile SkullXBones
```

The bitstream lands in `output_files/SkullXBones.rbf`, already named for the
`<rbf>SkullXBones</rbf>` the MRA asks for.

Source files are listed in `files.qip`. Add and remove entries by hand; do not
add files through the Quartus GUI, which rewrites the `.qsf`. `clean.bat`
removes every build product.

One line in `files.qip` must not be removed:

```
set_global_assignment -name SEARCH_PATH rtl/lib/fx68k
```

fx68k loads its microcode from `microrom.mem` and `nanorom.mem` by relative
path, and Quartus finds them only through this line. **If they are missing,
Quartus does not report an error**: the microcode synthesises empty and the
core boots to a black screen. Analysis & Synthesis prints `Info (10905)` for
each `.mem` file it reads — check for it.

`SkullXBones.sdc` prints one `Info` line for each vendored core it finds (fx68k,
T65, jt51). If one is missing, that core's timing exceptions were not applied.

The `.qsf` sets `SEED 3`, the seed this bitstream was built with (seeds 1 and 2
left the framework's HDMI scaler clock marginally short on one corner). A
different seed produces a different bitstream.

`rtl/video/skullxbo_testpat.sv` is a bring-up test pattern. It is not listed in
`files.qip` and is not part of the build.

## Attribution

This core's own RTL is **GPL-3.0-or-later** (`LICENSE`). Third-party components
keep their own notices; `NOTICE.md` is the full list.

| Component | Author | License |
| --- | --- | --- |
| MiSTer framework (`sys/`) | Till Harbaum, Alexey Melnikov (sorgelig) and MiSTer-devel contributors | GPL-2.0-or-later / GPL-3.0-or-later per file |
| fx68k (cycle-exact 68000, the main CPU) | Jorge Cwik (ijor), <https://github.com/ijor/fx68k> | GPL-3.0-or-later |
| T65 (6502, the sound CPU) | Daniel Wallner, with fixes by Mike Johnson, Wolfgang Scherr and Morten Leikvoll (OpenCores / FPGAArcade) | BSD-style |
| jt51 (YM2151) | Jose Tejada (jotego), <https://github.com/jotego/jt51> | GPL-3.0-or-later |
| `klax_oki6295.v` (MSM6295, the source of `rtl/sound/skullxbo_oki.sv`) | the Arcade-Klax_MiSTer authors | GPL-2.0-or-later |
| analog_hsize (CRT H-Size / H-Position resampler) | Umberto Parisi (rmonic79), Arcade-Raiden_MiSTer | GPL-3.0-or-later |
| Altera/Intel PLL megafunction | Intel Corporation (generated IP) | Intel FPGA IP licence, as generated |

The memory path, the MiSTer glue, the 68000 wrapper, the SOS-2 raster and most
of the main-board structure follow this author's
[Arcade-Badlands_MiSTer](https://github.com/MiSTer-devel/Arcade-Badlands_MiSTer)
core, which uses the same Atari custom chips on the same crystal; the SCOM
link, the alphanumerics layer and parts of the motion-object chain follow the
same author's
[Arcade-Vindicators_MiSTer](https://github.com/MiSTer-devel/Arcade-Vindicators_MiSTer)
core. Every equation, strobe, timing slot and raster position in this core was
taken from the A046903-01 / A047184-02 schematics and the three PAL dumps;
`NOTICE.md` names, file by file, which earlier work each module's structure
follows.

Thanks to the MAME team, whose `skullxbo.cpp`, `atarimo.cpp` and JSA sources
served as the functional reference throughout, and to whoever preserved the
Atari manual and schematic package and dumped the PALs.

Skull & Crossbones and its ROMs, artwork and manuals are © Atari Games and its
successors. This project contains no copyrighted ROM data.
