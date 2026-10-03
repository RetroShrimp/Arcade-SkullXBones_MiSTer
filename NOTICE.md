# NOTICE — third-party components and attributions

This core's own RTL is **GPL-3.0-or-later** (see `LICENSE`). This file lists
every third-party component in this repository, its authors and its licence.
Every file keeps its original header.

## Third-party components

| Component | Author(s) | License | Location |
|---|---|---|---|
| MiSTer framework (`sys_top`, `hps_io`, `arcade_video`, `video_freak`, `ascal`, PLL config, …) | Till Harbaum, Alexey Melnikov (sorgelig), MiSTer-devel contributors | GPL-2.0-or-later / GPL-3.0-or-later per file | `sys/` (unmodified) |
| Altera/Intel PLL megafunction instance | Intel Corporation (generated IP) | Intel FPGA IP licence, as generated | `rtl/pll.v`, `rtl/pll/` |
| `analog_hsize.sv`: analog-VGA horizontal pixel-stretch line buffer | Umberto Parisi (rmonic79), Arcade-Raiden_MiSTer, via the Bad Lands core | GPL-3.0-or-later | `rtl/video/analog_hsize.sv` |
| **fx68k**: cycle-exact MC68000 with its `microrom.mem` / `nanorom.mem` microcode (the 68000 at 245C) | Jorge Cwik (ijor) | GPL-3.0-or-later | `rtl/lib/fx68k/` (unmodified; its own `LICENSE`, `README.md` and `fx68k.txt` are kept) |
| **T65**: 65xx-compatible CPU core, VHDL (the 6502A at 1D on the JSA Audio II board) | Daniel Wallner, Mike Johnson (MikeJ / FPGAArcade), Wolfgang Scherr, Morten Leikvoll | BSD-style (full notice at the head of `T65.vhd`) | `rtl/lib/T65/`: `T65_Pack.vhd`, `T65_MCode.vhd`, `T65_ALU.vhd`, `T65.vhd` unmodified. `T65_wrap.vhd` is this project's small flat-port wrapper (GPL-3.0-or-later) |
| **JT51**: YM2151 (OPM) FM core (the YM2151 at 3A and the YM3012 at 5A) | José Tejada Gómez (jotego) | GPL-3.0-or-later | `rtl/lib/jt51/hdl/` (unmodified, used through its own `jt51.qip`) |
| **`klax_oki6295.v`**: OKI MSM6295 ADPCM core, the source `rtl/sound/skullxbo_oki.sv` is derived from | the Arcade-Klax_MiSTer authors | GPL-2.0-or-later (used under its "or later" option) | `rtl/lib/oki/klax_oki6295.v` (unmodified; listed in `files.qip` but not instantiated) |

## Derived work

Every file under `rtl/` outside `rtl/lib/` is this project's own transcription
of the A046903-01 game PCB and A047184-02 JSA Audio II schematics and the three
PAL fuse dumps. Each file's header names the earlier work whose *structure* it
follows; every equation, strobe, wait state, slot and pin is this board's.
Those earlier cores are this author's MiSTer projects, all GPL-3.0:
[Arcade-Badlands_MiSTer](https://github.com/MiSTer-devel/Arcade-Badlands_MiSTer),
[Arcade-Vindicators_MiSTer](https://github.com/MiSTer-devel/Arcade-Vindicators_MiSTer),
[Arcade-Xybots_MiSTer](https://github.com/MiSTer-devel/Arcade-Xybots_MiSTer),
Blasteroids and
[Arcade-Toobin_MiSTer](https://github.com/MiSTer-devel/Arcade-Toobin_MiSTer).

| This core | Structure follows |
|---|---|
| `rtl/main/skullxbo_cpu.sv`, `_addr_decode`, `_dtack`, `_irq`, `_watchdog`, `_inputs`, `_eeprom_28c16`, `_nvram_io`, `_main` | the Bad Lands files of the same role (`badlands_*.sv`). The 68000 clock phases are swapped here: this board's 68000 runs on the SOS-2's own `/7M` |
| `rtl/mem/skullxbo_vram.sv` | `badlands_vram.sv`: only the single-array + clock-enable block-RAM idiom; the PAL, the muxes and the slot schedule are this board's |
| `rtl/mem/skullxbo_prog_rom.sv` | `vind_cpurom_sdram.sv` (Vindicators): a program ROM served from SDRAM through a cache |
| `rtl/mem/skullxbo_rom_loader.sv`, `_sdram_loader`, `_sdram`, `_gfx_mem` | the Bad Lands files of the same role (and `vind_sdram_arb.sv` for the arbiter) |
| `rtl/video/skullxbo_sos2_sync.sv`, `_hstrobes`, `_gfx_client`, `_pf`, `_prio`, `_cram`, `_dac`, `_video` | the Bad Lands video files of the same role (and Blasteroids for the SOS-2). The 7M phase is the opposite of Bad Lands' |
| `rtl/video/skullxbo_alpha.sv` | `vind_alpha.sv` (Vindicators) |
| `rtl/video/skullxbo_mob.sv`, `_mo_fetch`, `_lb` | the Bad Lands and Vindicators motion-object files: the per-line object walk, the double-buffered slice fetch and the line-buffer pair. The MOB's list walk, link latch and register file are this board's |
| `rtl/video/skullxbo_sos1.sv`, `_pfhs`, `_vscroll` | no earlier work: these parts have no counterpart in the other cores |
| `rtl/sound/skullxbo_scom.sv` | `vind_scom.sv` (Vindicators): the two-ended register model and frame sequencer; the cable topology is this board's |
| `rtl/sound/skullxbo_snd_decode.sv`, `_snd_bus`, `_snd_io`, `_ym`, `_sound`, `_snd_filter`, `_snd_iir1`, `_snd_svf` | the Bad Lands and Vindicators JSA sound files of the same role; module shape and bus idioms only, the JSA II bit maps and filter values are this board's |
| `rtl/sound/skullxbo_oki.sv` | derived from `rtl/lib/oki/klax_oki6295.v` (see above and that file's header) |
| `rtl/skullxbo_core.sv`, `Arcade-SkullXBones.sv` | `badlands_core.sv` / `vind_core.sv` and `Arcade-Badlands.sv`: the game-logic top and the MiSTer glue |

## Reference material

MAME's `skullxbo.cpp`, `atarimo.cpp` and JSA sources (BSD-3-Clause, Aaron
Giles and the MAME contributors) were used as a functional reference; no MAME
code is included. The Atari manual and schematic package, the PAL fuse dumps
and all ROM images are not included in this repository.

## Trademarks and content

This project distributes no ROM data and no copyrighted artwork. *Skull &
Crossbones* is a trademark of its rights holders. Use only with software you
are legally entitled to.
