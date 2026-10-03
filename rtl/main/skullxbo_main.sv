`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones main board, 68000 side: schematic sheets 1-4 plus the
//  memory path.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Structure ported from
//  `Arcade-Badlands_MiSTer/rtl/main/badlands_main.sv` (GPL-3.0, same
//  author); every strobe, lane, wait and port below is this board's.
//
//  Contains: the 68000 and its decode, the /DTACK sequencer, the two video
//  RAMs with PAL 110E's slot schedule, the interrupt latches, power-on reset
//  and watchdog, the control inputs and status nibble, the 28C16 EEPROM, the
//  512 KB program ROM (in SDRAM), the SDRAM controller and the ROM loaders.
//
//  Not here: the raster (SOS-2 counters, the board HBLANK chain and the
//  LINKRES gate live in the video block and arrive as `h`, `v`, `pix`,
//  `vblank`, `hblank`, `linkres_n`), the scroll counters (`hs`, `vs` arrive;
//  this module outputs the strobes that load them), the colour RAM itself,
//  the motion-object hardware, the priority PAL, and the sound board (which
//  uses the SCOM ports).  The alphanumerics ROM and the 6502 ROM are loaded
//  here but live in those blocks.
//
//  Reset: /RESET (the watchdog output) reaches only the 68000's /HALT and
//  /RESET, the EEPROM unlock flop and the EEPROM /OE gate.  It does not reach
//  the video hardware, the interrupt latches or the sound board; the sound
//  board is reset only through the SCOM, by a write to FF1800.
//
//  Undriven data bus.  Several accesses drive only part of the data bus:
//     the write-only strobes (LS138 / LS139 170J)   nothing at all
//     /INPUTS                                       BD15:4 (BD3:0 float)
//     /AUDRD, /EEROM                                BD7:0
//     anything undecoded                            nothing
//  The board has no data-bus pull-ups, so a floating bus reads as 1s
//  (`UNDRIVEN_DATA = 0xFFFF`).  MAME returns 0x0000 instead.  The difference
//  is visible only in one harmless read-modify-write of FF1C81 during boot.
//
//  Program-ROM stalls.  ROM cycles have no wait states on the board, but the
//  ROM here lives in SDRAM behind a cache.  A cache miss raises `prog_stall`,
//  which holds off /DTACK for ROM reads only, adding wait states the board
//  does not have.  Stretching `ce_7m` instead would shift every CPU
//  video-RAM slot against the raster.
//============================================================================

module skullxbo_main #(
	parameter int  CLK_HZ                = 57272727,
	// What a floating data bus reads: 0xFFFF as on the board (MAME uses 0x0000).
	parameter logic [15:0] UNDRIVEN_DATA = 16'hFFFF,
	// power-on reset length and the watchdog-defeat jumper
	parameter int  POR_US                = 37000,
	parameter bit  WDOG_JP1              = 1'b0,     // 1 = JP1 fitted = defeated
	// the 28C16's self-timed byte write time
	parameter int  EEPROM_WRITE_CYCLES   = CLK_HZ / 100,
	// skullxbo_prog_rom's cache: sets of 4 words.  2048 -> 16 KB, 20 M10K.
	parameter int  PROG_CACHE_LINES      = 2048,
	// 1 = the F373 200K link register's `G` is PAL 110E's E output
	parameter bit  LINK_G_FROM_E         = 1'b1,
	// 1 = the VRAM address mux takes the MOB's own link register on `link_ext`
	// instead of this block's F373 200K copy (the top level sets 1).
	parameter bit  LINK_FROM_MOB         = 1'b0
)(
	input  logic        clk,            // clk_sys 57.272727 MHz
	input  logic        ce_7m,          // clk_sys/8 -- the H-count boundary
	input  logic        ce_14m,         // clk_sys/4 -- the 14MA rising edge
	input  logic        init_reset,     // ~pll_locked ONLY
	input  logic        ext_reset,      // OSD reset; re-runs the POR

	// ================= the raster, from the video block =================
	// The video block owns the sheet-1 raster logic (skullxbo_sos2_sync and
	// skullxbo_hstrobes) and exports these nets.
	input  logic  [8:0] h,              // the H count, 0..455
	input  logic  [8:0] v,              // the V count (only V[7:3] are wired on the board)
	input  logic        pix,            // the board's `7M`: 0 in (H,a), 1 in (H,b)
	input  logic        vblank,         // SOS-2 pin 22, RAW, ACTIVE HIGH
	input  logic        hblank,         // the BOARD's HBLANK (80F pin 9), rises ~H = 376
	input  logic        linkres_n,      // /LINKRES (90C LS10 pin 8); LINKRES is H = 442..445

	// ================= the scrolled counters, from the video block =======
	input  logic  [8:0] hs,             // PFHS 8HS..256HS
	input  logic  [8:0] vs,             // LS191 1VS..256VS

	// ================= the F373 200K link register ======================
	// Used when LINK_FROM_MOB = 1: the MOB's copy of the link register.
	input  logic  [7:0] link_ext,       // the MOB's own L7:0, used iff LINK_FROM_MOB

	// ================= the video-RAM video port ==========================
	output logic [15:0] vd,
	output logic [14:1] vd_addr,
	output logic  [1:0] vd_src,
	output logic        vd_cpu,
	output logic        vd_alpha,
	output logic        vd_pf_colour,
	output logic        vd_pf_code,
	output logic        vd_slip,
	output logic        vd_mob,
	output logic  [1:0] vd_mob_mc,
	// PAL 110E's pins and the F174-derived nets the video side needs
	output logic        rasa,
	output logic        rasb,
	output logic        slipup,
	output logic        pal_e,
	output logic        slip_n,
	output logic        ramcpu,
	output logic        vidcpu_n,
	output logic        e_d,            // E delayed one 14MA -> MOB pin 10
	output logic        slipup_d_n,
	output logic        h4d14m,         // -> the alpha latch clock and the LS191 term 2
	output logic        h4d35h_n,       // -> LS175 230N, the PF colour latch clock
	// the MOB's side of the RAM interface
	input  logic  [1:0] mob_mc,         // MC1:0 -> VRAMA2/1 (sampled at the MUX edge)
	input  logic        mob_link_g,     // only used when LINK_G_FROM_E = 0
	output logic  [7:0] link_l,         // F373 200K -> the VRAMA10:3 mux C3
	output logic        mobmsb,         // LS00 120C -> the VRAMA11 mux C3

	// ================= the video registers' write strobes ================
	// /HSCRL -> PFHS 195M.  BD15:7, on the rising edge of the strobe.  A byte
	// write puts the same byte on both halves of the bus, so a byte write to
	// FF1C81 gives BD15:7 = {byte, byte[7]}.
	output logic        hscrl_we,
	output logic  [8:0] hscrl_d,        // BD15:7
	// /VSCRL -> the LS191 counters' /LOAD (one of its two terms): asserted
	// while /VWRH and /VSCRL are both low.  The data is VD15:7, not BD15:7.
	output logic        vscrl_load,
	output logic  [8:0] vscrl_d,        // VD15:7
	// /MOBWR -> the MOB's write port (/CS = /VWRH OR /MOBWR).  The low nibble is
	// the MOB's register selector.
	output logic        mobwr_we,
	output logic [15:0] mobwr_d,        // VD15:0
	// /PFUPPER -> the LS374 140E playfield colour register
	output logic        pfupper_we,
	output logic  [7:0] pfupper_d,

	// ================= the colour-RAM CPU port ===========================
	output logic        cram_cs,        // /CRAM asserted (level, follows /AS)
	output logic [11:1] cram_a,         // BA11:1 (PAL 10F inverts BA11 into the
	                                    // RAM's A10; the colour RAM applies that)
	output logic        cram_we,        // ONE clk_sys pulse: write the 16-bit word
	output logic [15:0] cram_din,       // BD15:0 (LS245 50B/50C are a WORD port)
	input  logic [15:0] cram_dout,      // valid one clk_sys after cram_a, HELD
	output logic        cramd_n,        // LS74 70C-B Q -- the one-pixel steal
	output logic        cramoo_n,       // /CRAMD delayed one 14MB -> VIDCLK

	// ================= the SCOM master (link to the sound board) =========
	output logic        audwr_stb,      // 1-clk pulse at the END of a FF1400 write
	output logic  [7:0] audwr_data,     // BD7:0 for that write
	output logic        audrd_stb,      // 1-clk pulse at the END of a FF5000 read
	input  logic  [7:0] audrd_data,     // the SCOM's D7:0
	output logic        audres_stb,     // 1-clk pulse at the END of a FF1800 write
	output logic        scom_ck,        // LS125 50H pin 3 = /4H, the link bit clock
	input  logic        scom_full_n,    // SCOM pin 4 FULL -> /IPL2, ACTIVE LOW
	input  logic        audbusy_n,      // SCOM pin 5 BUSY -> status BD6, ACTIVE LOW

	// ================= ROMs loaded into block RAM elsewhere ==============
	output logic        char_wr,        // `chars` -> the 250K alphanumerics ROM
	output logic [14:0] char_addr,
	output logic        snd_wr,         // `jsa:cpu` -> the 6502 ROM at 1B
	output logic [15:0] snd_addr,
	output logic  [7:0] rom_data,       // the shared loader byte

	// ================= the SDRAM graphics / sample clients ===============
	input  logic        pf_req,
	input  logic [19:0] pf_addr,
	output logic        pf_ack,
	output logic  [7:0] pf_data,
	output logic [31:0] pf_group,       // the whole 4-byte group
	input  logic        mo_req,
	input  logic [21:0] mo_addr,
	output logic        mo_ack,
	output logic  [7:0] mo_data,
	output logic [127:0] mo_group,      // the whole 16-byte group
	input  logic        oki_req,
	input  logic [17:0] oki_addr,
	output logic        oki_ack,
	output logic  [7:0] oki_data,

	// ================= SDRAM pins ========================================
	inout  wire  [15:0] SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic  [1:0] SDRAM_BA,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_CKE,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nWE,

	// ================= MiSTer HPS ioctl ==================================
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_upload,
	output logic        ioctl_wait,
	output logic        ioctl_upload_req,
	output logic  [7:0] ioctl_upload_index,
	output logic  [7:0] ioctl_din,

	// ================= controls ==========================================
	input  logic        service,        // the JSA SW1, ACTIVE HIGH = self test ON
	input  logic  [3:0] p1_joy,         // {up, down, left, right}
	input  logic  [3:0] p2_joy,
	input  logic        p1_sword, p1_turn, p1_btn3, p1_start,
	input  logic        p2_sword, p2_turn, p2_btn3, p2_start,

	// ================= ANIRQ, from the alphanumerics =====================
	// D15 of the alpha word in the LS374 190K latch, ACTIVE HIGH.  Sampled ONLY
	// at the rising edge of the board's HBLANK.
	input  logic        anirq,

	// ================= status and debug outputs ==========================
	output logic        reset_n,        // the /RESET net
	output logic        rom_loaded,
	output logic        vcycdone,
	output logic [23:1] cpu_a,
	output logic  [2:0] cpu_fc,         // 111 = CPU space = an interrupt acknowledge
	output logic        cpu_as,
	output logic        cpu_rw,
	output logic        cpu_uds_n,
	output logic        cpu_lds_n,
	output logic [15:0] cpu_wdata,
	output logic [15:0] cpu_rdata,
	output logic        cpu_dtack
);

	// =====================================================================
	//  the 68000 and its decode
	// =====================================================================
	logic [15:0] rdata;
	logic        as, uds_n, lds_n, rw, dtack, vpa_n, ce_7m_cpu;
	logic  [2:0] fc, ipl;
	logic [23:1] a;
	logic [15:0] wdata;

	/* verilator lint_off UNUSEDSIGNAL */
	logic reset_inst;   // unused: the program contains no RESET instruction
	/* verilator lint_on UNUSEDSIGNAL */

	// The CPU is held while the board's /RESET is asserted, while the PLL is not
	// locked, and until the ROMs have arrived.
	wire cpu_reset = init_reset | ~rom_loaded | ~reset_n;

	skullxbo_cpu u_cpu (
		.clk(clk), .ce_7m(ce_7m), .reset(cpu_reset), .ipl(ipl),
		.a(a), .wdata(wdata), .rdata(rdata),
		.as(as), .uds_n(uds_n), .lds_n(lds_n), .rw(rw),
		.dtack(dtack), .vpa_n(vpa_n), .fc(fc),
		.reset_inst(reset_inst), .ce_7m_cpu(ce_7m_cpu)
	);

	logic r_n, w_n, wh_n, wl_n;
	logic cram_n, eerom_n;
	logic vscrl_n, mobwr_n, audrd_n, inputs_n;
	logic mobmsb_clr_n, mobmsb_set_n, waithbl_n, unlock_n, vblack_n, audwr_n,
	      audres_n, y7_n;
	logic pfupper_n, hscrl_n, irqack_n, wdog_n;
	logic rom_n, slapstik_n, vidram_n;
	logic [3:0] romsel_n;
	logic [17:0] rom_a;

	/* verilator lint_off UNUSEDSIGNAL */
	// /SLAPSTIK (empty socket) and /ROM3:0 are for waveforms only: the 512 KB
	// image is addressed by A18..A1.  `y7_n` is used inside the decoder.
	wire _unused_dec = &{1'b0, slapstik_n, romsel_n, y7_n, r_n, w_n, 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

	skullxbo_addr_decode u_dec (
		.clk(clk), .init_reset(init_reset),
		.as(as), .rw(rw), .uds_n(uds_n), .lds_n(lds_n), .a(a),
		.r_n(r_n), .w_n(w_n), .wh_n(wh_n), .wl_n(wl_n),
		.cram_n(cram_n), .eerom_n(eerom_n),
		.vscrl_n(vscrl_n), .mobwr_n(mobwr_n), .audrd_n(audrd_n),
		.inputs_n(inputs_n),
		.mobmsb_clr_n(mobmsb_clr_n), .mobmsb_set_n(mobmsb_set_n),
		.waithbl_n(waithbl_n), .unlock_n(unlock_n), .vblack_n(vblack_n),
		.audwr_n(audwr_n), .audres_n(audres_n), .y7_n(y7_n),
		.pfupper_n(pfupper_n), .hscrl_n(hscrl_n), .irqack_n(irqack_n),
		.wdog_n(wdog_n),
		.rom_n(rom_n), .slapstik_n(slapstik_n), .vidram_n(vidram_n),
		.romsel_n(romsel_n), .rom_a(rom_a), .mobmsb(mobmsb)
	);

	// F20 240F: /VPA = NAND(AS, FC2, FC1, FC0).  FC = 7 is CPU space,
	// which the 68000 drives only for an interrupt acknowledge, so every
	// interrupt on this board is autovectored.
	assign vpa_n = ~(as & fc[2] & fc[1] & fc[0]);

	// =====================================================================
	//  the end-of-cycle strobes
	// =====================================================================
	//  Every "the write has happened" event on this board is the rising edge of
	//  the strobe as /AS negates, so the decode is sampled while /AS is still
	//  asserted and used at that edge.
	logic as_q, rw_q, uds_q, lds_q;
	logic q_audwr, q_audrd, q_eerom, q_unlock, q_hscrl, q_pfupper, q_audres;
	logic [15:0] wdata_q;

	always_ff @(posedge clk) begin
		as_q <= as;
		if (as) begin
			rw_q      <= rw;
			wdata_q   <= wdata;
			q_audwr   <= ~audwr_n;
			q_audrd   <= ~audrd_n;
			q_eerom   <= ~eerom_n;
			q_unlock  <= ~unlock_n;
			q_hscrl   <= ~hscrl_n;
			q_pfupper <= ~pfupper_n;
			q_audres  <= ~audres_n;
		end
		// The 68000 asserts /UDS //LDS one clock AFTER /AS on a WRITE, so the
		// lanes are collected STICKILY over the cycle -- cleared as /AS asserts,
		// set the moment the strobe does.
		if (as && !as_q)       begin uds_q <= 1'b0; lds_q <= 1'b0; end
		else begin
			if (as && !uds_n)  uds_q <= 1'b1;
			if (as && !lds_n)  lds_q <= 1'b1;
		end
	end
	wire as_fall  = ~as & as_q;
	wire wr_end   = as_fall & ~rw_q;      // the rising edge of any write strobe
	wire rd_end   = as_fall &  rw_q;

	// /UNLOCK must still be asserted in the cycle `wr_end` fires.  On the board
	// /UNLOCK is the 30H flop's /PRE and /WL is its clock; both release when /AS
	// negates, and the level-sensitive /PRE wins, so the unlock write does not
	// re-lock the part.  Here `unlock_n` is already high when the edge is seen,
	// so the level is extended by one cycle.  Without this the EEPROM never
	// accepts a write.
	wire unlock_lvl = ~unlock_n | (as_fall & q_unlock);

	// =====================================================================
	//  the two video RAMs and PAL 110E
	// =====================================================================
	logic [15:0] vram_dout;
	logic        vmemh_n, vmeml_n, vwrh, vwrl, pfupper_q, pal_p12;

	/* verilator lint_off UNUSEDSIGNAL */
	// /VMEMH, /VMEML and PAL pin 12 (not connected on the board) are for
	// waveforms only.  Only /VWRH reaches the /VSCRL and /MOBWR loads, so /VWRL
	// has no use outside the RAM.
	wire _unused_vram = &{1'b0, vmemh_n, vmeml_n, vwrl, pfupper_q, pal_p12, 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

	skullxbo_vram #(
		.LINK_G_FROM_E(LINK_G_FROM_E), .LINK_FROM_MOB(LINK_FROM_MOB)
	) u_vram (
		.link_ext(link_ext),
		.clk(clk), .init_reset(init_reset), .ce_14m(ce_14m),
		.h(h), .pix(pix), .v(v), .hs(hs), .vs(vs), .linkres_n(linkres_n),
		.as(as), .rw(rw), .wh_n(wh_n), .wl_n(wl_n), .vidram_n(vidram_n),
		.vcycdone(vcycdone),
		.cpu_a(a[14:1]), .cpu_din(wdata), .cpu_dout(vram_dout),
		.pfupper_we(pfupper_we), .pfupper_d(pfupper_d),
		.mobmsb(mobmsb), .mob_mc(mob_mc), .mob_link_g(mob_link_g),
		.link_l(link_l),
		.vd(vd), .vd_addr(vd_addr), .vd_src(vd_src),
		.vd_cpu(vd_cpu), .vd_alpha(vd_alpha),
		.vd_pf_colour(vd_pf_colour), .vd_pf_code(vd_pf_code),
		.vd_slip(vd_slip), .vd_mob(vd_mob), .vd_mob_mc(vd_mob_mc),
		.rasa(rasa), .rasb(rasb), .slipup(slipup), .e(pal_e),
		.slip_n(slip_n), .ramcpu(ramcpu), .vidcpu_n(vidcpu_n), .pal_p12(pal_p12),
		.h4d14m(h4d14m), .h4d35h_n(h4d35h_n), .e_d(e_d),
		.slipup_d_n(slipup_d_n),
		.vmemh_n(vmemh_n), .vmeml_n(vmeml_n), .vwrh(vwrh), .vwrl(vwrl),
		.pfupper_q(pfupper_q)
	);

	// =====================================================================
	//  the LS163A wait sequencer, VCYCDONE and the /WAITHBL stall
	// =====================================================================
	logic dtack_raw;
	/* verilator lint_off UNUSEDSIGNAL */
	logic waithbl_q_n;
	logic [3:0] dtack_count;
	/* verilator lint_on UNUSEDSIGNAL */

	skullxbo_dtack u_dtack (
		.clk(clk), .ce_7m_cpu(ce_7m_cpu),
		.as(as), .vidram_n(vidram_n), .waithbl_n(waithbl_n),
		.eerom_n(eerom_n), .vpa_n(vpa_n), .ramcpu(ramcpu), .hblank(hblank),
		.dtack(dtack_raw), .vcycdone(vcycdone),
		.waithbl_q_n(waithbl_q_n), .count(dtack_count)
	);

	// A program-ROM cache miss holds /DTACK off (see the header).
	logic prog_stall;
	wire  rom_read = ~rom_n & rw;
	assign dtack = dtack_raw & ~(rom_read & prog_stall);

	// =====================================================================
	//  interrupts, watchdog and power-on reset
	// =====================================================================
	/* verilator lint_off UNUSEDSIGNAL */
	logic irq1_pend, irq2_pend, por;
	logic [3:0] wdog_count;
	/* verilator lint_on UNUSEDSIGNAL */

	skullxbo_irq u_irq (
		.clk(clk),
		// /RESET does not reach either latch: power-up only.
		.reset(init_reset),
		.v1_n(~v[0]), .v2(v[1]), .v4(v[2]),
		.vblank(vblank), .hblank(hblank), .anirq(anirq),
		.irqack_n(irqack_n), .vblack_n(vblack_n), .scom_full_n(scom_full_n),
		.ipl(ipl), .irq1_pend(irq1_pend), .irq2_pend(irq2_pend)
	);

	skullxbo_watchdog #(.CLK_HZ(CLK_HZ), .POR_US(POR_US)) u_wdog (
		.clk(clk),
		.ext_reset(init_reset | ext_reset | ~rom_loaded),
		.vblank(vblank), .wdog_n(wdog_n), .jp1(WDOG_JP1),
		.reset_n(reset_n), .por(por), .count(wdog_count)
	);

	// =====================================================================
	//  inputs and the status nibble
	// =====================================================================
	logic [7:0] mux_dout;
	logic [3:0] stat_dout;

	skullxbo_inputs u_inputs (
		.ba1(a[1]),
		.p1_joy(p1_joy), .p2_joy(p2_joy),
		.p1_sword(p1_sword), .p1_turn(p1_turn),
		.p1_btn3(p1_btn3), .p1_start(p1_start),
		.p2_sword(p2_sword), .p2_turn(p2_turn),
		.p2_btn3(p2_btn3), .p2_start(p2_start),
		.selftest(service), .audbusy_n(audbusy_n),
		.vblank(vblank), .hblank(hblank),
		.mux_dout(mux_dout), .stat_dout(stat_dout)
	);

	// =====================================================================
	//  the EEPROM and the NVRAM channel
	// =====================================================================
	logic [7:0] ee_rdata;
	/* verilator lint_off UNUSEDSIGNAL */
	logic       ee_busy, ee_oe_n, ee_unlocked;
	/* verilator lint_on UNUSEDSIGNAL */
	logic       ee_write_accepted;
	logic       nv_load_we;
	logic [10:0] nv_load_addr, nv_dump_addr;
	logic  [7:0] nv_load_data, nv_dump_data;

	// The EEPROM's init window: the PLL lock, the ROM download, and an index-2
	// NVRAM restore.  Every restored byte must arrive INSIDE it.
	wire ee_init = init_reset | ~rom_loaded |
	               (ioctl_download & (ioctl_index == 16'd2));

	// /WE is /WL unconditionally, so the relock clock is the rising edge of any
	// low-lane write anywhere in the map.
	wire wl_rise = wr_end & lds_q;

	skullxbo_eeprom_28c16 #(
		.CLK_HZ(CLK_HZ), .WRITE_CYCLES(EEPROM_WRITE_CYCLES)
	) u_eeprom (
		.clk(clk), .init_reset(ee_init),
		.reset(~reset_n),                 // /RESET reaches the 30H /CLR
		.unlock(unlock_lvl),              // /UNLOCK is a level on /PRE
		.any_write(wl_rise),
		.cpu_we(wl_rise & q_eerom),
		.cpu_addr(a[11:1]), .cpu_wdata(wdata_q[7:0]), .cpu_rdata(ee_rdata),
		.busy(ee_busy), .oe_n(ee_oe_n), .unlocked(ee_unlocked),
		.write_accepted(ee_write_accepted),
		.load_we(nv_load_we), .load_addr(nv_load_addr), .load_data(nv_load_data),
		.dump_addr(nv_dump_addr), .dump_data(nv_dump_data)
	);

	skullxbo_nvram_io u_nvram (
		.clk(clk), .init_reset(init_reset),
		.write_accepted(ee_write_accepted),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
		.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_index(ioctl_index), .ioctl_upload(ioctl_upload),
		.load_we(nv_load_we), .load_addr(nv_load_addr), .load_data(nv_load_data),
		.dump_addr(nv_dump_addr), .dump_data(nv_dump_data),
		.ioctl_upload_req(ioctl_upload_req),
		.ioctl_upload_index(ioctl_upload_index), .ioctl_din(ioctl_din)
	);

	// =====================================================================
	//  the download path, the program ROM and the SDRAM
	// =====================================================================
	logic        ld_wr;
	logic [23:0] ld_addr;
	logic        sdl_busy;
	logic        dl_wr, dl_ack;
	logic [23:0] dl_waddr;
	logic [15:0] dl_wdata;

	skullxbo_rom_loader u_ldr (
		.clk(clk), .reset(init_reset),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
		.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_index(ioctl_index),
		.sdram_wr(ld_wr), .sdram_addr(ld_addr),
		.char_wr(char_wr), .char_addr(char_addr),
		.snd_wr(snd_wr), .snd_addr(snd_addr),
		.rom_data(rom_data), .rom_loaded(rom_loaded)
	);

	skullxbo_sdram_loader u_sdl (
		.clk(clk), .reset(init_reset),
		.ld_wr(ld_wr), .ld_addr(ld_addr), .ld_data(rom_data),
		.wr_busy(sdl_busy),
		.dl_wr(dl_wr), .dl_waddr(dl_waddr), .dl_wdata(dl_wdata), .dl_ack(dl_ack)
	);

	assign ioctl_wait = sdl_busy;

	logic        prog_req, prog_valid, prog_last;
	logic [23:0] prog_addr;
	logic  [1:0] prog_blen;
	logic [15:0] prog_rdata, prog_q;
	/* verilator lint_off UNUSEDSIGNAL */
	logic        prog_ready;
	/* verilator lint_on UNUSEDSIGNAL */

	skullxbo_prog_rom #(.LINES(PROG_CACHE_LINES)) u_prom (
		.clk(clk), .reset(init_reset | ~rom_loaded),
		.rd(rom_read), .addr(rom_a), .data(prog_q),
		.ready(prog_ready), .stall(prog_stall),
		.c_req(prog_req), .c_addr(prog_addr), .c_blen(prog_blen),
		.c_valid(prog_valid), .c_last(prog_last), .c_rdata(prog_rdata)
	);

	logic        sd_req, sd_we, sd_ready, sd_valid, rfsh_ok;
	logic [23:0] sd_addr;
	logic  [2:0] sd_blen;
	logic [15:0] sd_wdata, sd_rdata;

	skullxbo_gfx_mem u_gfx (
		.clk(clk), .reset(init_reset),
		.cpu_req(prog_req), .cpu_addr(prog_addr), .cpu_blen(prog_blen),
		.cpu_valid(prog_valid), .cpu_last(prog_last), .cpu_rdata(prog_rdata),
		.pf_req(pf_req), .pf_addr(pf_addr), .pf_ack(pf_ack), .pf_data(pf_data),
		.pf_group(pf_group),
		.mo_req(mo_req), .mo_addr(mo_addr), .mo_ack(mo_ack), .mo_data(mo_data),
		.mo_group(mo_group),
		.oki_req(oki_req), .oki_addr(oki_addr), .oki_ack(oki_ack),
		.oki_data(oki_data),
		.dl_wr(dl_wr), .dl_waddr(dl_waddr), .dl_wdata(dl_wdata), .dl_ack(dl_ack),
		.sd_req(sd_req), .sd_addr(sd_addr), .sd_we(sd_we), .sd_blen(sd_blen),
		.sd_wdata(sd_wdata), .rfsh_ok(rfsh_ok),
		.sd_ready(sd_ready), .sd_valid(sd_valid), .sd_rdata(sd_rdata)
	);

	skullxbo_sdram u_sdram (
		.clk(clk),
		// This MUST be ~pll_locked only: a reset here during the download drops
		// CKE, restarts the 200 us init mid-stream and silently loses every
		// loader write already made.
		.reset(init_reset),
		.addr(sd_addr), .wdata(sd_wdata), .we(sd_we), .blen(sd_blen),
		.req(sd_req), .rfsh_ok(rfsh_ok),
		.rdata(sd_rdata), .valid(sd_valid), .ready(sd_ready),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_CKE(SDRAM_CKE),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE)
	);

	// =====================================================================
	//  the colour-RAM CPU port
	// =====================================================================
	//    LS74 70C-A (an S-R latch, clock tied off) : /PRE = AS , /CLR = /CRAMD
	//    F32 60C pin 11 = OR( 70C-A /Q , /CRAM )
	//    LS74 70C-B : D = 60C pin 11 , CP = /14MA , /PRE = AS , Q = /CRAMD
	//  => /CRAMD is a ONE-14MA-cycle low pulse, once per CPU colour-RAM cycle.
	//  Then, on sheet 9, F398 40J delays it one 14MB into /CRAMOO, and
	//    /CRWR  = OR( OR(/CRAMOO, /W) , /14MA )     -- a half-cycle write pulse
	//    VIDCLK = OR( CRAMOO , /14MA )              -- HELD HIGH for that cycle
	//  The CPU steals exactly one pixel: there is no wait state or arbitration
	//  between the colour RAM and the 68000, so each CPU access freezes the
	//  output latch for one pixel.  MAME does not model this.
	//
	//  The video block owns the RAM, the F153 address mux and VIDCLK; this
	//  module owns the CPU side.  `cram_we` is the /CRWR pulse reduced to one
	//  clk_sys, and `cramd_n` / `cramoo_n` feed VIDCLK from the same flops.
	logic q70ca;      // Q of the S-R latch; /Q is what 60C sees
	always_ff @(posedge clk) begin
		if (!as)            q70ca <= 1'b1;     // /PRE = AS, level
		else if (!cramd_n)  q70ca <= 1'b0;     // /CLR = /CRAMD, level
	end
	wire c60c_11 = ~q70ca | cram_n;            // OR( 70C-A /Q , /CRAM )

	always_ff @(posedge clk) begin
		if (!as)            cramd_n <= 1'b1;   // /PRE = AS, level
		else if (ce_14m)    cramd_n <= c60c_11;
	end

	always_ff @(posedge clk) begin
		if (init_reset)  cramoo_n <= 1'b1;
		else if (ce_14m) cramoo_n <= cramd_n;  // F398 40J group 4, CK = /14MB
	end

	assign cram_cs  = ~cram_n;
	assign cram_a   = a[11:1];
	assign cram_din = wdata;                   // LS245 50B/50C: a 16-bit WORD port
	assign cram_we  = ce_14m & ~cramoo_n & ~rw;

	// =====================================================================
	//  the video registers' write strobes
	// =====================================================================
	// /HSCRL -> PFHS 195M, BD15:7, latched on the strobe's RISING edge.
	assign hscrl_we = wr_end & q_hscrl;
	assign hscrl_d  = wdata_q[15:7];

	// /PFUPPER -> LS374 140E, BD7:0, likewise (the program writes FF1E01 as a
	// byte on the odd lane).
	assign pfupper_we = wr_end & q_pfupper;
	assign pfupper_d  = wdata_q[7:0];

	// /VSCRL -> the LS191 counters.  One /LOAD term is (/VWRH low AND /VSCRL
	// low), and the counters load VD15:7, not BD15:7: the data reaches them
	// over the video bus, which is why a /VSCRL access is also a /VIDRAM one.
	assign vscrl_load = ~vscrl_n & vwrh;
	assign vscrl_d    = vd[15:7];

	// /MOBWR -> the MOB's write port (/CS = /VWRH OR /MOBWR), also over VD.
	assign mobwr_we = ~mobwr_n & vwrh;
	assign mobwr_d  = vd;

	// =====================================================================
	//  the SCOM master
	// =====================================================================
	assign audwr_stb  = wr_end & q_audwr;
	assign audwr_data = wdata_q[7:0];          // SCOM D0..D7 = BD0..BD7
	assign audrd_stb  = rd_end & q_audrd;      // reading FF5001 is the only ack
	assign audres_stb = wr_end & q_audres;
	assign scom_ck    = ~h[2];                 // LS125 50H pin 3 = /4H

	// =====================================================================
	//  the CPU read mux
	// =====================================================================
	always_comb begin
		rdata = UNDRIVEN_DATA;
		if      (!rom_n)    rdata = prog_q;                    // A23 = 0
		else if (!vidram_n) rdata = vram_dout;                 // LS373 170K/140C
		else if (!cram_n)   rdata = cram_dout;                 // LS245 50B/50C, a WORD
		else if (!eerom_n)  rdata = {UNDRIVEN_DATA[15:8], ee_rdata};
		else if (!inputs_n) rdata = {mux_dout, stat_dout, UNDRIVEN_DATA[3:0]};
		else if (!audrd_n)  rdata = {UNDRIVEN_DATA[15:8], audrd_data};
	end

	assign cpu_a     = a;
	assign cpu_fc    = fc;
	assign cpu_as    = as;
	assign cpu_rw    = rw;
	assign cpu_uds_n = uds_n;
	assign cpu_lds_n = lds_n;
	assign cpu_wdata = wdata;
	assign cpu_rdata = rdata;
	assign cpu_dtack = dtack;

	/* verilator lint_off UNUSEDSIGNAL */
	// `mobmsb_*_n` drive the LS00 latch inside the decoder; `uds_q` is kept for
	// symmetry with `lds_q`, which the EEPROM relock uses.
	wire _unused_main = &{1'b0, mobmsb_clr_n, mobmsb_set_n, uds_q, 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
