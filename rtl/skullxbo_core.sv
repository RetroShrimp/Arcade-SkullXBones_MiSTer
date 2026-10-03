`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones (Atari Games, 1989): game logic top, below the MiSTer
//  `emu` glue.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  Structure inherited from the
//  Badlands, Vindicators and Xybots MiSTer cores (GPL-3.0, same author).
//
//  The whole cabinet: `skullxbo_main` (the 68000 game PCB A046903-01,
//  sheets 1-4, plus the SDRAM path), `skullxbo_video` (sheets 1 and 5-10)
//  and `skullxbo_sound` (the JSA Audio II board A047184-02).
//
//  Three instance names matter: SkullXBones.sdc finds fx68k as
//  `*u_main|u_cpu|u_fx68k|*`, T65 as `*u_sound|u_bus|u_cpu|u_t65|*` and jt51
//  as `*u_sound|u_ym|u_jt51|*`.  If a hierarchy does not match, that
//  exception is skipped silently; the SDC prints an info line for each core
//  it finds, so check the build log.
//
//  The video block owns the sheet-1 raster: `skullxbo_video` contains
//  `skullxbo_sos2_sync` and `skullxbo_hstrobes` and exports `h`, `v`, `m7`,
//  `hblank_board`, `hblank_rise`, `vblank_raw`, `vres_n`, `anirq` and
//  `vram_linkres` to the main board, so there is only one copy of the board
//  HBLANK and LINKRES logic.
//
//  PAL16R8 110E lives in `skullxbo_vram` (main board) and drives the memory
//  path.  `skullxbo_video` keeps its own three-equation copy of the PAL's
//  video-side outputs (/SLIP, SLIPUP, E).
//
//  The link register: `skullxbo_main` is built with `LINK_FROM_MOB = 1` and
//  `link_ext` = `skullxbo_video.vram_l`, so the video-RAM address mux uses
//  the same link value as the MOB's own list walk.
//
//  Clocking: one clock domain, clk_sys = 57.272727 MHz = 4 x the 14.318181
//  MHz crystal, with integer clock enables only:
//
//     ce_14m  = clk_sys / 4   = 14.318181 MHz  pixel, PAL 110E, colour RAM,
//                                              MO shifters
//     ce_7m   = clk_sys / 8   =  7.159091 MHz  68000, SOS-2 H counter,
//                                              PF / alpha shifters
//     ce_3m58 = clk_sys / 16  =  3.579545 MHz  YM2151
//     ce_1m79 = clk_sys / 32  =  1.789772 MHz  6502
//     ce_1m19 = clk_sys / 48  =  1.193182 MHz  MSM6295
//
//  The first four decode one free-running 5-bit counter, so each slower
//  enable is a subset of every faster one.  The /48 enable has its own
//  counter; on the JSA board 1193K is the 3.579 MHz clock divided by 3, so
//  clk_sys / 48 is the same rate exactly.
//
//  Phase convention: the clk_sys cycle in which `ce_7m` is high is the last
//  cycle of SOS-2 count `h`; the cycle in which `ce_14m` is high is the last
//  cycle of a pixel.
//
//  Resets:
//    init_reset  `~pll_locked` only.  It is the only reset the SDRAM
//                controller and the loaders may see: a reset during the
//                download would drop CKE, restart the SDRAM init and lose
//                every word already written.  It goes to
//                `skullxbo_main.init_reset` and nowhere else.
//    game_reset  `reset | ~rom_loaded`: the OSD/system reset, or ROMs not yet
//                loaded.  It reaches the board through
//                `skullxbo_main.ext_reset`, which re-runs the power-on reset,
//                so the watchdog chain holds /RESET as on a cabinet power-up.
//    vid_reset   `init_reset | ~rom_loaded`, not the OSD reset.  The board's
//                /RESET does not reach the SOS-2, the MOB, PAL 110E or the
//                video latches, so the raster keeps running through a reset
//                (a real cabinet's monitor stays locked).  The main board
//                also needs the raster running: its power-on reset counts
//                VBLANK edges.
//    snd_por     `init_reset | reset | ~rom_loaded`: the JSA board's own
//                power-on reset.  The game PCB's /RESET (watchdog included)
//                never reaches the audio board, so this is not `reset_n`; a
//                MiSTer reset is treated as a cabinet power cycle.
//============================================================================

module skullxbo_core #(
	// 262 (default) or 263 lines per frame.
	parameter int V_TOTAL = 262,
	// Forwarded to `skullxbo_main`, which documents both.  The defaults are
	// the shipped core.
	//   UNDRIVEN_DATA  what a floating data bus reads: 0xFFFF (no pull-ups);
	//                  MAME's convention is 0x0000
	//   POR_US         the power-on reset length, 35-40 ms on the board
	parameter logic [15:0] UNDRIVEN_DATA = 16'hFFFF,
	parameter int          POR_US        = 37000
)(
	input  logic        clk_sys,        // 57.272727 MHz
	input  logic        reset,          // active-high system/OSD reset
	input  logic        init_reset,     // ~pll_locked ONLY (SDRAM + loaders)

	// ---- HPS ioctl: index 0 = the ROM stream, index 2 = the EEPROM ----
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	output logic        ioctl_wait,
	input  logic        ioctl_upload,
	output logic        ioctl_upload_req,
	output logic  [7:0] ioctl_upload_index,
	output logic  [7:0] ioctl_din,

	// ---- controls (ACTIVE HIGH = "pressed" here; the board's active-low
	//      senses are formed inside skullxbo_main / skullxbo_snd_io) ----
	input  logic        service,        // the JSA SW1 self-test switch, HIGH = ON
	input  logic  [3:0] p1_joy,         // {up, down, left, right}
	input  logic  [3:0] p2_joy,
	input  logic        p1_sword, p1_turn, p1_btn3, p1_start,
	input  logic        p2_sword, p2_turn, p2_btn3, p2_start,
	input  logic        coin1, coin2, coin3, coin4,

	// ---- the two JAMMA coin-counter solenoid drivers (J1-11 / J1-12) ----
	output logic        cctr1,
	output logic        cctr2,
	output logic        cctr_wired_or,  // the R13 = 0 ohm node the board has

	// ---- video out (single clk_sys domain, qualified by ce_pix) ----
	output logic        ce_pix,
	output logic  [7:0] vga_r, vga_g, vga_b,
	output logic        hsync, vsync, hblank, vblank,
	// the software palette index behind the pixel on vga_* (debug only)
	output logic [10:0] pix_index,

	// ---- audio (the JSA II mixes to MONO: both carry one signal) ----
	output logic signed [15:0] aud_l, aud_r,

	// ---- observability ----
	output logic        rom_loaded,     // the index-0 download has finished

	// ---- SDRAM chip ----
	inout  wire  [15:0] SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic  [1:0] SDRAM_BA,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_CKE,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nWE
);

	// =====================================================================
	//  clock enables
	// =====================================================================
	// One free-running /32 counter; every enable is a decode of it.  No reset
	// or initialiser: Quartus powers it up at 0.
	logic [4:0] ce_cnt;
	always_ff @(posedge clk_sys) ce_cnt <= ce_cnt + 5'd1;

	wire ce_14m  = (ce_cnt[1:0] == 2'd0);   // 14.318181 MHz  pixel
	wire ce_7m   = (ce_cnt[2:0] == 3'd0);   //  7.159091 MHz  68000, H counter
	wire ce_3m58 = (ce_cnt[3:0] == 4'd0);   //  3.579545 MHz  YM2151
	wire ce_1m79 = (ce_cnt      == 5'd0);   //  1.789772 MHz  6502

	// The MSM6295's 1.193182 MHz = clk_sys / 48, from its own counter.
	logic [5:0] oki_cnt;
	always_ff @(posedge clk_sys) oki_cnt <= (oki_cnt == 6'd47) ? 6'd0 : oki_cnt + 6'd1;
	wire ce_1m19 = (oki_cnt == 6'd0);

	// =====================================================================
	//  resets (see the header)
	// =====================================================================
	wire game_reset = reset | ~rom_loaded;
	wire vid_reset  = init_reset | ~rom_loaded;
	wire snd_por    = init_reset | reset | ~rom_loaded;

	// =====================================================================
	//  the inter-block nets
	// =====================================================================
	// ---- the raster, from the video block into skullxbo_main -------------
	logic [8:0]  vid_h, vid_v;
	logic        vid_m7, vid_hblank_board, vid_hblank_rise, vid_vblank_raw;
	logic        vid_vres_n, vid_anirq, vid_linkres;
	logic        vid_slip_n, vid_slipup, vid_e_slot;

	// ---- the video block's side of the VRAM port -------------------------
	logic [5:0]  vram_hs;
	logic [8:0]  vram_vs;
	logic [7:0]  vram_l;
	logic [1:0]  vram_mc;
	logic [15:0] vd;

	// ---- the two SDRAM graphics clients ----------------------------------
	logic        pf_req, pf_ack, mo_req, mo_ack;
	logic [19:0] pf_addr;
	logic [21:0] mo_addr;
	logic [31:0] pf_group;
	logic [127:0] mo_group;
	logic        gfx_late;

	// ---- the CPU strobes the video block consumes ------------------------
	logic        hscrl_we, vscrl_load, mobwr_we;
	logic [8:0]  hscrl_d, vscrl_d;
	logic [15:0] mobwr_d;

	// ---- the colour-RAM CPU port -----------------------------------------
	logic        cram_cs, cram_we;
	logic [11:1] cram_a;
	logic [15:0] cram_din, cram_dout;

	// ---- the two block-RAM loader ports ----------------------------------
	logic        char_wr, snd_wr;
	logic [14:0] char_addr;
	logic [15:0] snd_addr;
	logic  [7:0] rom_data;

	// ---- the SCOM link and the OKI sample client -------------------------
	logic        audwr_stb, audrd_stb, audres_stb, scom_ck;
	logic  [7:0] audwr_data, audrd_data;
	logic        scom_full_n, audbusy_n;
	logic        oki_req, oki_ack;
	logic [17:0] oki_addr;
	logic  [7:0] oki_data;

	// ---- the video block's pixel stream ----------------------------------
	logic [7:0]  vid_r, vid_g, vid_b;
	logic        vid_de, vid_hb, vid_vb, vid_hsync_n, vid_vsync_n;

	// ---- debug nets --------------------------------------------------------
	// `main_reset_n` is the LS90 70F /RESET net; `main_slip_n` / `main_slipup`
	// / `main_pal_e` are PAL 110E's registered outputs; `main_cramd_n` /
	// `main_cramoo_n` are the one-pixel colour-RAM steal.
	logic        main_reset_n;
	logic        main_slip_n, main_slipup, main_pal_e;
	logic        main_cramd_n, main_cramoo_n;

	// =====================================================================
	//  the 68000 main board and the whole memory path (sheets 1-4)
	// =====================================================================
	//  The name `u_main` matters (the SDC uses it).  `LINK_FROM_MOB = 1` gives
	//  the video-RAM address mux the MOB's own link register (see the header).
	//  Everything else is at its default: JP1 not fitted (the watchdog is
	//  live), `LINK_G_FROM_E = 1` and the 28C16's real 10 ms byte write.
	/* verilator lint_off PINCONNECTEMPTY */
	skullxbo_main #(
		.LINK_FROM_MOB(1'b1),
		.UNDRIVEN_DATA(UNDRIVEN_DATA),
		.POR_US(POR_US)
	) u_main (
		.clk(clk_sys), .ce_7m(ce_7m), .ce_14m(ce_14m),
		.init_reset(init_reset), .ext_reset(game_reset),

		// the sheet-1 raster, from the video block
		.h(vid_h), .v(vid_v), .pix(vid_m7), .vblank(vid_vblank_raw),
		.hblank(vid_hblank_board), .linkres_n(~vid_linkres),

		// the scrolled counters: only HS[8:3] and VS[8:3] reach the muxes, and
		// the PFHS publishes exactly those six bits as `vram_hs`
		.hs({vram_hs, 3'b000}), .vs(vram_vs),

		// the MOB's own copy of the F373 200K link register
		.link_ext(vram_l),

		// the video-RAM video port
		.vd(vd), .vd_addr(), .vd_src(),
		.vd_cpu(), .vd_alpha(), .vd_pf_colour(), .vd_pf_code(),
		.vd_slip(), .vd_mob(), .vd_mob_mc(),
		.rasa(), .rasb(), .slipup(main_slipup), .pal_e(main_pal_e),
		.slip_n(main_slip_n), .ramcpu(), .vidcpu_n(), .e_d(), .slipup_d_n(),
		.h4d14m(), .h4d35h_n(),
		.mob_mc(vram_mc), .mob_link_g(1'b0), .link_l(), .mobmsb(),

		// the strobes the video block's registers take
		.hscrl_we(hscrl_we), .hscrl_d(hscrl_d),
		.vscrl_load(vscrl_load), .vscrl_d(vscrl_d),
		.mobwr_we(mobwr_we), .mobwr_d(mobwr_d),
		.pfupper_we(), .pfupper_d(),

		// the colour-RAM CPU port
		.cram_cs(cram_cs), .cram_a(cram_a), .cram_we(cram_we),
		.cram_din(cram_din), .cram_dout(cram_dout),
		.cramd_n(main_cramd_n), .cramoo_n(main_cramoo_n),

		// the SCOM master
		.audwr_stb(audwr_stb), .audwr_data(audwr_data),
		.audrd_stb(audrd_stb), .audrd_data(audrd_data),
		.audres_stb(audres_stb), .scom_ck(scom_ck),
		.scom_full_n(scom_full_n), .audbusy_n(audbusy_n),

		// the two block-RAM regions the loader fills
		.char_wr(char_wr), .char_addr(char_addr),
		.snd_wr(snd_wr), .snd_addr(snd_addr), .rom_data(rom_data),

		// the three SDRAM byte clients
		.pf_req(pf_req),   .pf_addr(pf_addr),   .pf_ack(pf_ack),
		.pf_data(),        .pf_group(pf_group),
		.mo_req(mo_req),   .mo_addr(mo_addr),   .mo_ack(mo_ack),
		.mo_data(),        .mo_group(mo_group),
		.oki_req(oki_req), .oki_addr(oki_addr), .oki_ack(oki_ack),
		.oki_data(oki_data),

		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_CKE(SDRAM_CKE), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_nWE(SDRAM_nWE),

		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
		.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_index(ioctl_index), .ioctl_upload(ioctl_upload),
		.ioctl_wait(ioctl_wait), .ioctl_upload_req(ioctl_upload_req),
		.ioctl_upload_index(ioctl_upload_index), .ioctl_din(ioctl_din),

		// The two bits the schematic calls "AUX (DEVELOPMENT ONLY)" are JAMMA
		// button 3 and the JAMMA START pin of each player.  MAME marks them
		// unused; they are wired here as on the board.
		.service(service),
		.p1_joy(p1_joy), .p2_joy(p2_joy),
		.p1_sword(p1_sword), .p1_turn(p1_turn),
		.p1_btn3(p1_btn3), .p1_start(p1_start),
		.p2_sword(p2_sword), .p2_turn(p2_turn),
		.p2_btn3(p2_btn3), .p2_start(p2_start),

		.anirq(vid_anirq),

		.reset_n(main_reset_n), .rom_loaded(rom_loaded),
		.vcycdone(),
		.cpu_a(), .cpu_fc(), .cpu_as(), .cpu_rw(),
		.cpu_uds_n(), .cpu_lds_n(), .cpu_wdata(), .cpu_rdata(), .cpu_dtack()
	);
	/* verilator lint_on PINCONNECTEMPTY */

	// =====================================================================
	//  the video block (sheets 1 and 5-10)
	// =====================================================================
	//  HB_END = 7: with HB_END = 0 the board's HBLANK and the custom's HBLANK
	//  never overlap while 7M is high, so RSTLB can never fire and the
	//  motion-object line buffers never restart (see skullxbo_hstrobes).
	//
	//  HB_START = 326: the program sets ANIRQ (D15) only in alpha column 42,
	//  and the scanline-interrupt latch samples the LS374 190K word on the
	//  board HBLANK rise.  190K holds column 42 over H 340..347 only, so the
	//  board HBLANK must rise at (344,b), which the 80E/80F chain gives for
	//  an SOS-2 HBLANK start in 304..335.  At 336 it rises at (376,b) =
	//  column 46, the interrupt never fires, and the HUD is drawn 8 lines
	//  low.  326 is also the value the Blasteroids core uses for this SOS-2.
	/* verilator lint_off PINCONNECTEMPTY */
	skullxbo_video #(.V_TOTAL(V_TOTAL), .HB_START(326), .HB_END(7)) u_video (
		.clk(clk_sys), .reset(vid_reset), .ce_14m(ce_14m), .ce_7m(ce_7m),

		// the video-RAM port
		.vd(vd),
		.vram_hs(vram_hs), .vram_vs(vram_vs), .vram_l(vram_l),
		.vram_mc(vram_mc), .vram_linkres(vid_linkres),

		// the two SDRAM graphics clients: one transaction per hardware fetch,
		// taken from the aligned group
		.pf_req(pf_req), .pf_addr(pf_addr), .pf_blen(),
		.pf_ack(pf_ack), .pf_group(pf_group),
		.mo_req(mo_req), .mo_addr(mo_addr), .mo_blen(),
		.mo_ack(mo_ack), .mo_gdata(mo_group),
		.gfx_late(gfx_late),

		// the CPU strobes
		.hscrl_we(hscrl_we), .hscrl_d(hscrl_d),
		.vscrl_load(vscrl_load), .vscrl_d(vscrl_d),
		.mobwr_we(mobwr_we), .mobwr_d(mobwr_d),
		.mo_ctc(main_pal_e),
		.cram_cs(cram_cs), .cram_we(cram_we), .cram_cpu_a(cram_a[11:1]),
		.cram_din(cram_din), .cram_dout(cram_dout),

		// the 27256 alphanumerics ROM at 250K, from the index-0 loader
		.crom_wr(char_wr), .crom_addr(char_addr), .crom_din(rom_data),

		// the colour-RAM preload port is unused: the 68000 fills FF2000-FF2FFE
		// itself
		.cram_init_wr(1'b0), .cram_init_a(11'd0), .cram_init_d(16'd0),

		.red(vid_r), .green(vid_g), .blue(vid_b),
		.de(vid_de), .hblank(vid_hb), .vblank(vid_vb),
		.hsync_n(vid_hsync_n), .vsync_n(vid_vsync_n),
		.csync_n(), .blank_n(), .pix_index(pix_index),

		// the sheet-1 raster this block owns and skullxbo_main consumes
		.h(vid_h), .v(vid_v), .m7(vid_m7),
		.hblank_board(vid_hblank_board), .hblank_rise(vid_hblank_rise),
		.vblank_raw(vid_vblank_raw), .vres_n(vid_vres_n), .anirq(vid_anirq),
		.slip_n(vid_slip_n), .slipup(vid_slipup), .e_slot(vid_e_slot),

		.mo_slices(), .mo_entries()
	);
	/* verilator lint_on PINCONNECTEMPTY */

	// =====================================================================
	//  the JSA Audio II board A047184-02
	// =====================================================================
	//  The name `u_sound` matters (the SDC finds T65 and jt51 through it).
	//  Its three MAME_* parameters are test-only switches and stay at their
	//  defaults (the board's behaviour).
	//
	//  `self_test` is the same net as `skullxbo_main.service`: the switch is
	//  on the JSA board, read by the 6502 on /RDIO D7 and D4, and also sent
	//  over J1-29 to the game PCB's FF5803 D7.  One OSD control, two boards.
	//
	//  coin1..coin4 land on {J1-33, J1-31, J1-35, J1-36} = /RDIO D3..D0.  The
	//  MiSTer glue decides which pad drives which (pad 1 -> coin4 = D0).
	skullxbo_sound u_sound (
		.clk(clk_sys),
		.ce_14m(ce_14m), .ce_7m(ce_7m),
		.ce_3m58(ce_3m58), .ce_1m79(ce_1m79), .ce_1m19(ce_1m19),
		.por(snd_por),

		.audwr_stb(audwr_stb), .audwr_data(audwr_data),
		.audrd_stb(audrd_stb), .audrd_data(audrd_data),
		.audres_stb(audres_stb), .scom_ck(scom_ck),
		.scom_full_n(scom_full_n), .audbusy_n(audbusy_n),

		.self_test(service),
		.coin({coin1, coin2, coin3, coin4}),
		.cctr1(cctr1), .cctr2(cctr2), .cctr_wired_or(cctr_wired_or),

		.rom_wr(snd_wr), .rom_addr(snd_addr), .rom_data(rom_data),

		.oki_req(oki_req), .oki_addr(oki_addr),
		.oki_ack(oki_ack), .oki_data(oki_data),

		.audio_l(aud_l), .audio_r(aud_r)
	);

	// =====================================================================
	//  outputs
	// =====================================================================
	// `de`, `hblank` and `vblank` travel WITH the pixel through the video
	// block's own pipeline and `red`/`green`/`blue` are already registered on
	// `ce_14m`, so nothing is re-timed here.  arcade_video wants ACTIVE-HIGH
	// sync; the board emits the active-low /HSYNC and /VSYNC.
	assign ce_pix = ce_14m;
	assign vga_r  = vid_r;
	assign vga_g  = vid_g;
	assign vga_b  = vid_b;
	assign hblank = vid_hb;
	assign vblank = vid_vb;
	assign hsync  = ~vid_hsync_n;
	assign vsync  = ~vid_vsync_n;

	/* verilator lint_off UNUSEDSIGNAL */
	// Unused here: `gfx_late` is the graphics clients' missed-deadline flag
	// (debug), `vid_de` is not needed because the MiSTer glue derives DE from
	// the blanks, and `vid_hblank_rise` / `vid_vres_n` / `vid_slip_n` /
	// `vid_slipup` / `vid_e_slot` are not needed by the main board because PAL
	// 110E's own outputs live in `skullxbo_vram`.
	wire _unused_core = &{1'b0,
		main_reset_n, main_slip_n, main_slipup, main_pal_e,
		main_cramd_n, main_cramoo_n, gfx_late, vid_de,
		vid_hblank_rise, vid_vres_n, vid_slip_n, vid_slipup, vid_e_slot,
		1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
