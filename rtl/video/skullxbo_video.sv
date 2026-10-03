`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones video block (schematic sheets 1, 4-10): the SOS-2
//  raster and board strobes, playfield, alphanumerics, motion objects, line
//  buffers, priority PAL, colour RAM and DAC.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  This block reads the video RAM (in skullxbo_main) and two graphics-ROM
//  clients in SDRAM, and exports the raster to the main board.
//
//  Video-RAM port:
//      video -> memory (address sources into the F253/LS253 muxes, sheet 4)
//        vram_hs[5:0]    8HS..256HS   the PFHS scrolled column
//        vram_vs[8:0]    1VS..256VS   the LS191 scrolled row
//        vram_l[7:0]     L7:0         the MOB's link register
//        vram_mc[1:0]    MC1:MC0  ->  VRAMA2 / VRAMA1 (MOB pins 13, 12)
//        vram_linkres    LINKRES      mux C2 of 160F/170F and PAL 110E pin 8
//        h, v                         the alpha source and everything else
//
//      memory -> video
//        vd[15:0]        the video data bus.  `vd` during 14MA cycle N carries
//                        the word whose mux address was presented in cycle
//                        N-1 (the F174 latch plus a 45 ns SRAM in a 69.8 ns
//                        cycle), so every latch here fires on its real board
//                        edge and sees the right word.
//
//      slot schedule per 8 H counts:
//        (8k+2, b)  PF  0xFFA000 + ...   the tile colour word
//        (8k+3, a)  PF  0xFF8000 + ...   the tile code word
//        (8k+3, b)  ALPHA 0xFFC000 + 2*(V[7:3]*64 + H[8:3])
//        the other thirteen cycles  MO   0xFFD000 + 0x800*MOBMSB + 8*L + 2*MC
//        in the LINKRES window (H = 442..445): /SLIP low at (442,b), SLIPUP at
//        (443,a) -> the SLIP address 0xFFCF80 + 2*VS[8:3]
//
//  Graphics-ROM clients (see skullxbo_gfx_client): the playfield reads a
//  16-bit word ({"R", "P"} columns) and the motion objects a whole 16-dot
//  slice (five planes x two halves) per fetch, each as one SDRAM transaction.
//
//  Output window: `de` is generated at the raster and pipelined through the
//  same stages as the pixel data, so the 672 pixels of each of the 240
//  active lines come out in order.  `VIS_DOT0` is the board dot that is
//  screen x = 0: 16, because the playfield and alphanumerics are displayed
//  one 8-count group after the group that fetched them.
//
//  `hblank` / `vblank` follow that 672 x 240 window.  `blank_n` is the
//  board's /BLANK (board HBLANK or VBLANK), which clears the colour
//  registers; in this model it also blanks the last column, x = 671.
//============================================================================

module skullxbo_video #(
	// ---- raster ----------------------------------------------------------
	parameter int V_TOTAL      = 262,
	parameter int HB_START     = 326,    // board HBLANK then rises at (344,b), alpha column 42
	parameter int HB_END       = 7,
	parameter int VIS_DOT0     = 16,     // the board dot that is screen x = 0
	// ---- playfield -------------------------------------------------------
	parameter int PF_COL_ADJ   = 0,
	parameter int PF_FINE_ADJ  = 0,
	parameter int SOS1_LAT     = 0,
	// ---- alphanumerics ---------------------------------------------------
	parameter int ALPHA_DOT_ADJ = 0,
	// ---- motion objects --------------------------------------------------
	parameter bit MOB_CODE_CARRY = 1'b1,
	parameter bit MOB_YSRC       = 1'b1,
	parameter bit MOB_TL_CONST   = 1'b1,
	parameter bit MOB_MISC_CONST = 1'b0,
	parameter bit MOB_LINK_LATCH = 1'b1,
	parameter int MOB_LINE_ADJ   = 1,
	parameter bit MOB_VRES_YREF  = 1'b1,
	parameter bit VS_CTEN_VBLANK = 1'b1,
	parameter bit LB_ERASE       = 1'b1,
	parameter int LB_RD_ADJ      = 1
)(
	input  logic        clk,
	input  logic        reset,
	input  logic        ce_14m,
	input  logic        ce_7m,

	// ---- the video-RAM port ---------------------------------------------
	input  logic [15:0] vd,
	output logic [5:0]  vram_hs,
	output logic [8:0]  vram_vs,
	output logic [7:0]  vram_l,
	output logic [1:0]  vram_mc,
	output logic        vram_linkres,

	// ---- the graphics-ROM clients ---------------------------------------
	output logic        pf_req,
	output logic [19:0] pf_addr,     // a byte offset, 0..0x9FFFF
	output logic [3:0]  pf_blen,
	input  logic        pf_ack,
	input  logic [31:0] pf_group,   // the 4-byte group

	output logic        mo_req,
	output logic [21:0] mo_addr,     // a byte offset, 0..0x27FFF9
	output logic [3:0]  mo_blen,
	input  logic        mo_ack,
	input  logic [127:0] mo_gdata,  // the 16-byte group

	output logic        gfx_late,

	// ---- CPU strobes that reach the video block -------------------------
	// `hscrl_we` is an edge (one clk_sys); `vscrl_load` and `mobwr_we` are
	// levels, and both of those carry `VD`, not `BD`.
	input  logic        hscrl_we,     // the /HSCRL rising edge
	input  logic [8:0]  hscrl_d,      // BD15:7  -> PFHS 195M
	input  logic        vscrl_load,   // LEVEL: /VWRH & /VSCRL
	input  logic [8:0]  vscrl_d,      // VD15:7  -> the LS191s
	input  logic        mobwr_we,     // LEVEL: /VWRH & /MOBWR
	input  logic [15:0] mobwr_d,      // VD15:0  -> the MOB
	input  logic        mo_ctc,       // PAL 110E E (this cycle) -> MOB MO-CTC
	input  logic        cram_cs,
	input  logic        cram_we,
	input  logic [10:0] cram_cpu_a,
	input  logic [15:0] cram_din,
	output logic [15:0] cram_dout,

	// ---- the character-ROM loader (250K, 32 KB) -------------------------
	input  logic        crom_wr,
	input  logic [14:0] crom_addr,
	input  logic [7:0]  crom_din,

	// ---- colour-RAM preload port (tied off in the core) -----------------
	input  logic        cram_init_wr,
	input  logic [10:0] cram_init_a,
	input  logic [15:0] cram_init_d,

	// ---- video out -------------------------------------------------------
	output logic [7:0]  red,
	output logic [7:0]  green,
	output logic [7:0]  blue,
	output logic        de,           // travels WITH the pixel
	output logic        hblank,       // the 672 x 240 display window
	output logic        vblank,
	output logic        hsync_n,      // the board's re-clocked /HSYNC
	output logic        vsync_n,
	output logic        csync_n,      // NAND(/HSYNC, /VSYNC) -> JAMMA-P
	output logic        blank_n,      // the BOARD's /BLANK
	output logic [10:0] pix_index,    // the palette index (debug)

	// ---- raster taps for the main board ---------------------------------
	output logic [8:0]  h,
	output logic [8:0]  v,
	output logic        m7,
	output logic        hblank_board,
	output logic        hblank_rise,
	output logic        vblank_raw,
	output logic        vres_n,
	output logic        anirq,
	output logic        slip_n,
	output logic        slipup,
	output logic        e_slot,

	// ---- debug outputs --------------------------------------------------
	output logic [7:0]  mo_slices,
	output logic [7:0]  mo_entries
);

	// =====================================================================
	// 1. The raster
	// =====================================================================
	logic       m14, m14_n, m7_n, pix;
	logic [2:0] ph;
	logic       ce_m7_rise, ce_m7_fall, ce_m14_rise, ce_m14_fall;
	logic [9:0] x;
	logic       h1, h1_n, h2, h2_n, h4, h4_n, h8, h16, h32, h64, h128, h256;
	logic       h256_n;
	logic       v1, v1_n, v2, v4, v8, v16, v32, v64, v128, v256;
	logic       h_4hd1h, h_4hd1h_n, h_4hd2h, h_4hd2h_n;
	logic       hblank_sos2, hblank_sos2_n, hsync_sos2_n, vblank_n;
	logic [9:0] hpos_u;
	logic [8:0] vpos_u;
	logic       hde_u, vde_u, line_start, frame_start, vblank_start;

	skullxbo_sos2_sync #(
		.V_TOTAL(V_TOTAL), .HB_START(HB_START), .HB_END(HB_END)
	) u_sos2 (
		.clk(clk), .reset(reset), .ce_14m(ce_14m), .ce_7m(ce_7m),
		.m14(m14), .m14_n(m14_n), .m7(m7), .m7_n(m7_n), .ph(ph), .pix(pix),
		.ce_m7_rise(ce_m7_rise), .ce_m7_fall(ce_m7_fall),
		.ce_m14_rise(ce_m14_rise), .ce_m14_fall(ce_m14_fall),
		.h(h), .v(v), .x(x),
		.h1(h1), .h1_n(h1_n), .h2(h2), .h2_n(h2_n), .h4(h4), .h4_n(h4_n),
		.h8(h8), .h16(h16), .h32(h32), .h64(h64), .h128(h128), .h256(h256),
		.h256_n(h256_n),
		.v1(v1), .v1_n(v1_n), .v2(v2), .v4(v4), .v8(v8), .v16(v16),
		.v32(v32), .v64(v64), .v128(v128), .v256(v256),
		.h_4hd1h(h_4hd1h), .h_4hd1h_n(h_4hd1h_n),
		.h_4hd2h(h_4hd2h), .h_4hd2h_n(h_4hd2h_n),
		.hblank(hblank_sos2), .hblank_n(hblank_sos2_n),
		.hsync_n(hsync_sos2_n),
		.vblank(vblank_raw), .vblank_n(vblank_n), .vsync_n(vsync_n),
		.vres_n(vres_n),
		.hpos(hpos_u), .vpos(vpos_u), .hde(hde_u), .vde(vde_u),
		.line_start(line_start), .frame_start(frame_start),
		.vblank_start(vblank_start));

	// =====================================================================
	// 2. The on-board strobes
	// =====================================================================
	logic hbdly, hblank_b_n, rstlb, linkres, linkres_n, q80e2;
	logic h4d14m, h4d14m_n, hd35_n, m7d14m;
	logic ce_4h_rise, ce_hd35_rise, ce_4hd14m_rise, ce_m7d14m_rise;
	logic ce_4hd14m_fall;

	skullxbo_hstrobes u_hstb (
		.clk(clk), .reset(reset), .ce_7m(ce_7m), .ph(ph), .h(h), .m7(m7),
		.hblank_sos2(hblank_sos2), .hsync_sos2_n(hsync_sos2_n),
		.hbdly(hbdly), .hblank(hblank_board), .hblank_n(hblank_b_n),
		.hblank_rise(hblank_rise), .hsync_n(hsync_n),
		.rstlb(rstlb), .linkres(linkres), .linkres_n(linkres_n),
		.q80e2(q80e2),
		.h4d14m(h4d14m), .h4d14m_n(h4d14m_n), .hd35_n(hd35_n),
		.m7d14m(m7d14m),
		.ce_4h_rise(ce_4h_rise), .ce_hd35_rise(ce_hd35_rise),
		.ce_4hd14m_rise(ce_4hd14m_rise), .ce_m7d14m_rise(ce_m7d14m_rise),
		.ce_4hd14m_fall(ce_4hd14m_fall));

	assign vram_linkres = linkres;
	assign blank_n      = vblank_n & hblank_b_n;
	assign csync_n      = ~(~hsync_n | ~vsync_n);   // 10D LS00 + 10C 7406

	// ---- PAL 110E's video-side outputs (the CPU grant is in skullxbo_vram)
	//   /SLIP'  = NOT[ /7M & (h == 2) & LINKRES ]
	//   SLIPUP' = LINKRES & 7M & (h == 2)
	//   E'      = NOT[ /SLIP & ( VIDRAM + (h==2) + (h==3 & /7M) ) ]
	logic e_r;
	always_ff @(posedge clk) begin
		if (reset) begin
			slip_n <= 1'b1;
			slipup <= 1'b0;
			e_r    <= 1'b0;
		end else if (ce_14m) begin
			slip_n <= ~(~m7 & (h[2:0] == 3'd2) & linkres);
			slipup <= linkres & m7 & (h[2:0] == 3'd2);
			e_r    <= ~( slip_n & ((h[2:0] == 3'd2) | ((h[2:0] == 3'd3) & ~m7)) );
		end
	end
	assign e_slot = e_r;

	// /SLIP's RISING edge — the LS191 clock and the MOB's line tick.
	wire ce_slip_rise = ce_14m & ~slip_n;

	// =====================================================================
	// 3. The vertical scroll counters
	// =====================================================================
	logic [8:0] vs;
	logic       vs_load_win;
	skullxbo_vscroll #(.VS_CTEN_VBLANK(VS_CTEN_VBLANK)) u_vs (
		.clk(clk), .reset(reset),
		.ce_slip_rise(ce_slip_rise),
		.vscrl_load(vscrl_load), .vscrl_d(vscrl_d),
		.linkres(linkres), .vres_n(vres_n), .vblank(vblank_raw),
		.h4(h4), .h4d14m(h4d14m),
		.vd(vd), .vs(vs), .load_win(vs_load_win));
	assign vram_vs = vs;

	// =====================================================================
	// 4. The playfield
	// =====================================================================
	logic [3:0]  pfpix, pfpal_s;
	logic [14:0] pfpic;
	logic        pfhflip, pf_late;

	skullxbo_pf #(
		.PF_COL_ADJ(PF_COL_ADJ), .PF_FINE_ADJ(PF_FINE_ADJ), .SOS1_LAT(SOS1_LAT)
	) u_pf (
		.clk(clk), .reset(reset), .ce_7m(ce_7m), .h(h), .linkres(linkres),
		.ce_hd35_rise(ce_hd35_rise), .ce_4h_rise(ce_4h_rise),
		.vd(vd), .vs(vs), .hscrl_we(hscrl_we), .hscrl_d(hscrl_d),
		.pf_req(pf_req), .pf_addr(pf_addr), .pf_blen(pf_blen),
		.pf_ack(pf_ack), .pf_group(pf_group), .pf_late(pf_late),
		.hs(vram_hs), .pfpix(pfpix), .pfpal_s(pfpal_s),
		.pfpic(pfpic), .pfhflip(pfhflip));

	// =====================================================================
	// 5. The alphanumerics
	// =====================================================================
	logic [1:0]  anpix_r;
	logic [3:0]  anpal;
	logic        anbo;
	logic [15:0] an_word;

	skullxbo_alpha u_alpha (
		.clk(clk), .reset(reset), .ce_7m(ce_7m), .h(h), .v(v),
		.ce_4hd14m_rise(ce_4hd14m_rise), .h_4hd1h_n(h_4hd1h_n),
		.vd(vd),
		.rom_wr(crom_wr), .rom_addr(crom_addr), .rom_din(crom_din),
		.anpix(anpix_r), .anpal(anpal), .anbo(anbo), .anirq(anirq),
		.an_word(an_word));

	// ALPHA_DOT_ADJ trims the alpha layer against the playfield in whole dots.
	logic [1:0] anpix;
	generate
		if (ALPHA_DOT_ADJ == 0) begin : g_an0
			assign anpix = anpix_r;
		end else begin : g_and
			logic [1:0] an_d [0:ALPHA_DOT_ADJ-1];
			always_ff @(posedge clk) if (ce_14m) begin
				an_d[0] <= anpix_r;
				for (int i = 1; i < ALPHA_DOT_ADJ; i++) an_d[i] <= an_d[i-1];
			end
			assign anpix = an_d[ALPHA_DOT_ADJ-1];
		end
	endgenerate

	// =====================================================================
	// 6. The motion objects
	// =====================================================================
	logic        slice_stb, slice_live, mhflip;
	logic [14:0] mo_code;
	logic [2:0]  mo_row;
	logic [9:0]  mhpos;
	logic [3:0]  mopal;
	logic [1:0]  mopri;
	logic        motl, momisc;
	logic [8:0]  mob_xs, mob_ys, mob_vs_o;

	skullxbo_mob #(
		.MOB_CODE_CARRY(MOB_CODE_CARRY), .MOB_YSRC(MOB_YSRC),
		.MOB_TL_CONST(MOB_TL_CONST), .MOB_MISC_CONST(MOB_MISC_CONST),
		.MOB_LINK_LATCH(MOB_LINK_LATCH),
		.MOB_LINE_ADJ(MOB_LINE_ADJ), .MOB_VRES_YREF(MOB_VRES_YREF)
	) u_mob (
		.clk(clk), .reset(reset), .ce_14m(ce_14m), .ce_7m(ce_7m),
		.h(h), .pix(pix), .linkres(linkres), .ce_slip_rise(ce_slip_rise),
		.vd(vd), .vs(vs), .mobwr_we(mobwr_we), .mobwr_d(mobwr_d),
		.mo_ctc(mo_ctc),
		// the line before /VRES: its SLIP sample starts the walk whose buffer
		// is displayed on screen line 0
		.vres_walk(v == (V_TOTAL[8:0] - 9'd2)),
		.l(vram_l), .mc(vram_mc),
		.slice_stb(slice_stb), .slice_live(slice_live),
		.mo_code(mo_code), .mo_row(mo_row), .mhflip(mhflip), .mhpos(mhpos),
		.mopal(mopal), .mopri(mopri), .motl(motl), .momisc(momisc),
		.mob_xscroll(mob_xs), .mob_yscroll(mob_ys), .mob_vs(mob_vs_o),
		.slices_this_line(mo_slices), .entries_this_line(mo_entries));

	logic       lb_loadlb, lb_live, mo_late;
	logic [9:0] lb_pos;
	logic [4:0] lb_pen;
	logic [7:0] lb_attr;

	skullxbo_mo_fetch u_mof (
		.clk(clk), .reset(reset), .ce_14m(ce_14m), .ce_7m(ce_7m),
		.h(h), .pix(pix),
		.slice_stb(slice_stb), .slice_live(slice_live),
		.mo_code(mo_code), .mo_row(mo_row), .mhflip(mhflip), .mhpos(mhpos),
		.mopal(mopal), .mopri(mopri), .motl(motl), .momisc(momisc),
		.mo_req(mo_req), .mo_addr(mo_addr), .mo_blen(mo_blen),
		.mo_ack(mo_ack), .mo_gdata(mo_gdata), .mo_late(mo_late),
		.lb_loadlb(lb_loadlb), .lb_pos(lb_pos), .lb_pen(lb_pen),
		.lb_attr(lb_attr), .lb_live(lb_live));

	assign gfx_late = pf_late | mo_late;

	// 1VMOB — the ping-pong flop 30H-B, flipped once per line at the SLIP tick.
	logic wbank;
	always_ff @(posedge clk) begin
		if (reset)              wbank <= 1'b0;
		else if (ce_slip_rise)  wbank <= v[0];
	end

	logic [9:0] lb_wcnt, lb_rcnt;
	logic [4:0] lbpix;
	logic [3:0] lbpal;
	logic [1:0] lbpri;
	logic       lbtl, lbmisc;

	skullxbo_lb #(.LB_ERASE(LB_ERASE), .LB_RD_ADJ(LB_RD_ADJ)) u_lb (
		.clk(clk), .reset(reset), .ce_14m(ce_14m),
		.wbank(wbank), .line_tick(ce_slip_rise), .rstlb(rstlb),
		.loadlb(lb_loadlb), .wpos(lb_pos), .pen(lb_pen), .attr(lb_attr),
		.live(lb_live),
		.lbpix(lbpix), .lbpal(lbpal), .lbpri(lbpri), .lbtl(lbtl),
		.lbmisc(lbmisc),
		.wcnt(lb_wcnt), .rcnt(lb_rcnt));

	// =====================================================================
	// 7. Priority, colour RAM, DAC
	// =====================================================================
	logic       sa, sb, a10_pin, shadow, cramd_n;
	logic [9:0] cram_a;

	skullxbo_prio u_prio (
		.cramd_n(cramd_n), .ba11(cram_cpu_a[10]),
		.lbpri(lbpri), .lbtl(lbtl), .lbpix(lbpix),
		.pfpix3(pfpix[3]), .pfpix2(pfpix[2]), .pfpal_s(pfpal_s),
		.lbmisc(lbmisc), .anbo(anbo), .anpix(anpix),
		.lbpal(lbpal), .pfpix(pfpix), .anpal(anpal), .ba(cram_cpu_a),
		.sa(sa), .sb(sb), .a10_pin(a10_pin), .shadow(shadow),
		.cram_a(cram_a));

	logic [15:0] colour;

	skullxbo_cram u_cram (
		.clk(clk), .reset(reset), .ce_14m(ce_14m),
		.cram_a(cram_a), .shadow(shadow), .blank_n(blank_n),
		.cram_cs(cram_cs), .cram_we(cram_we), .cram_cpu_a(cram_cpu_a),
		.cram_din(cram_din), .cram_dout(cram_dout),
		.init_wr(cram_init_wr), .init_a(cram_init_a), .init_d(cram_init_d),
		.colour(colour), .pix_index(pix_index), .cramd_n(cramd_n));

	skullxbo_dac u_dac (
		.colour(colour), .red(red), .green(green), .blue(blue));

	// =====================================================================
	// 8. The display window, pipelined WITH the pixel
	// =====================================================================
	// The pen buses are combined by PAL 10F and the F153 muxes combinationally,
	// registered by F174 50F/40F and again by the HC273s — two 14M stages.
	localparam int DE_PIPE = 2;

	wire [9:0] dotidx = {h, pix};
	wire       de_raw = ~vblank_raw &
	                    (dotidx >= VIS_DOT0[9:0]) &
	                    ({1'b0, dotidx} < (VIS_DOT0[10:0] + 11'd672));

	logic [DE_PIPE-1:0] de_sr;
	always_ff @(posedge clk) begin
		if (reset)       de_sr <= '0;
		else if (ce_14m) de_sr <= {de_sr[DE_PIPE-2:0], de_raw};
	end
	assign de     = de_sr[DE_PIPE-1];
	assign hblank = ~de_sr[DE_PIPE-1] & ~vblank;

	logic [DE_PIPE-1:0] vb_sr;
	always_ff @(posedge clk) begin
		if (reset)       vb_sr <= '1;
		else if (ce_14m) vb_sr <= {vb_sr[DE_PIPE-2:0], vblank_raw};
	end
	assign vblank = vb_sr[DE_PIPE-1];

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0,
		m14, m14_n, m7_n, ce_m7_rise, ce_m7_fall, ce_m14_rise, ce_m14_fall,
		x, h1, h1_n, h2, h2_n, h4_n, h8, h16, h32, h64, h128, h256, h256_n,
		v1, v1_n, v2, v4, v8, v16, v32, v64, v128, v256,
		h_4hd1h, h_4hd2h, h_4hd2h_n, hbdly, q80e2, hd35_n, m7d14m,
		h4d14m_n, ce_m7d14m_rise, ce_4hd14m_fall,
		hpos_u, vpos_u, hde_u, vde_u, line_start, frame_start, vblank_start,
		hblank_sos2_n, pfpic, pfhflip, an_word,
		mob_xs, mob_ys, mob_vs_o, sa, sb, a10_pin, linkres_n,
		vs_load_win, lb_wcnt, lb_rcnt, 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
