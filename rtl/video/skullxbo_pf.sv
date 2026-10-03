`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones playfield (schematic sheets 4, 5): LS374 180K/210K,
//  LS175 230N, the six-bank 27512 stamp ROM map, the SOS-1 195N shifter and
//  the PFHS 195M scroll custom.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  The two video-RAM slots.  Per 8-count group the playfield gets two 14MA
//  cycles, and the colour word comes first:
//
//      (8k+2, b)  mux -> 0xFFA000 + ...   the tile colour word
//      (8k+3, a)  mux -> 0xFF8000 + ...   the tile code word
//
//  The data bus lags the mux by one 14MA cycle, so:
//      LS175 230N      clocked by /4HD3.5H, rising into (8k+3, b): takes the
//                      colour word.  PFPAL3:0 come off the /Q pins, so
//                      PFPALn = NOT VDn.
//      LS374 180K/210K clocked by 4H, rising into (8k+4, a): takes the code
//                      word: PFPIC14:0 = VD14:0, PFHFLIP = VD15.
//  Swapped, every tile would be drawn with another tile's palette.
//
//  Stamp ROM:
//      byte in device = PFPIC[11:0]*16 + {4VS,2VS,1VS}*2 + HALFSTMP
//      device bank    = PFPIC[14:12]          (bank 5 = 250R/250P is empty)
//      HALFSTMP       = PFHFLIP XOR /4H
//      "R" column = PFD15:8 (high byte), "P" column = PFD7:0
//      pixel 0 = PFD15..12, 1 = PFD11..8, 2 = PFD7..4, 3 = PFD3..0
//
//  Both ROMs of a bank are read at once, so one fetch is a 16-bit word;
//  skullxbo_gfx_client reads it as two bytes.  The device byte offset is
//  q = {bank, PFPIC[11:0], VS[2:0], HALFSTMP}, and skullxbo_rom_loader stores
//  the region in 4-byte groups per (bank, code, row):
//
//      SDRAM region byte = {q[18:1], is_R, q[0]}
//          [0] "P" HALFSTMP=0   [1] "P" HALFSTMP=1
//          [2] "R" HALFSTMP=0   [3] "R" HALFSTMP=1
//
//  so `pf_addr` = {q[18:1], 1'b0, q[0]} (the "P" byte) and the "R" byte is
//  at +2.  Both halves of a tile row are in one group, so the two fetches of
//  a group share one SDRAM row fill.
//
//  The pen polarity is applied once, in the SOS-1 (SHPOL = GND, inverting).
//  The MRA stores the raw ROM bytes, so MAME's ROMREGION_INVERT must not be
//  applied as well.
//
//  Fetch windows:
//      window A : address valid over h = 4..7, HALFSTMP = PFHFLIP
//      window B : address valid over h = 0..3, HALFSTMP = /PFHFLIP
//
//  /LD = /1H2H is low at h = 3 and h = 7 and SHCLK = /7M rises on the count
//  boundary, so the SOS-1 loads at the end of h = 7 (window A, shown over
//  h = 0..3 of the next group) and at the end of h = 3 (window B, shown over
//  h = 4..7).  Both use the tile latched at the previous group's 4H edge, so
//  a tile fetched in group k is displayed in group k+1 (see skullxbo_pfhs).
//============================================================================

module skullxbo_pf #(
	parameter int  PF_COL_ADJ   = 0,
	parameter int  PF_FINE_ADJ  = 0,
	parameter int  SOS1_LAT     = 0,
	parameter int  PFCAW        = 20,   // the arbiter's byte address width
	// Bank 5 (250R / 250P) is not stuffed and the PFD bus has no pull
	// resistors, so it floats.  0xFFFF -> pen 0 after the SOS-1's inversion.
	parameter logic [15:0] PF_EMPTY = 16'hFFFF
)(
	input  logic        clk,
	input  logic        reset,

	// ---- raster ----------------------------------------------------------
	input  logic        ce_7m,
	input  logic [8:0]  h,
	input  logic        linkres,
	input  logic        ce_hd35_rise,    // LS175 230N clock
	input  logic        ce_4h_rise,      // LS374 180K/210K clock

	// ---- the video data bus and the vertical scroll counters -------------
	input  logic [15:0] vd,
	input  logic [8:0]  vs,

	// ---- the CPU's /HSCRL write -----------------------------------------
	input  logic        hscrl_we,    // the /HSCRL rising edge
	input  logic [8:0]  hscrl_d,     // BD15:7

	// ---- the graphics-ROM client ----------------------------------------
	output logic            pf_req,
	output logic [PFCAW-1:0] pf_addr,
	output logic [3:0]      pf_blen,
	input  logic            pf_ack,
	input  logic [31:0]     pf_group,   // the 4-byte group
	output logic            pf_late,

	// ---- outputs ---------------------------------------------------------
	output logic [5:0]  hs,          // 8HS..256HS to the video-RAM mux
	output logic [3:0]  pfpix,       // PFPIX3:0  (PFHS XP3:0)
	output logic [3:0]  pfpal_s,     // PFPAL3S:0S (PFHS XP7:4)
	output logic [14:0] pfpic,       // debug
	output logic        pfhflip      // debug
);

	// ---------------------------------------------------------------------
	// 1. The two latches
	// ---------------------------------------------------------------------
	logic [3:0] pfpal;               // LS175 230N, from the /Q pins

	always_ff @(posedge clk) begin
		if (reset) begin
			pfpal   <= 4'b0;
			pfpic   <= 15'b0;
			pfhflip <= 1'b0;
		end else begin
			if (ce_hd35_rise) pfpal <= ~vd[3:0];            // the /Q pins
			if (ce_4h_rise) begin
				pfpic   <= vd[14:0];
				pfhflip <= vd[15];
			end
		end
	end

	// ---------------------------------------------------------------------
	// 2. HALFSTMP and the stamp-ROM address (F86 160J)
	// ---------------------------------------------------------------------
	wire h4n      = ~h[2];                       // /4H
	wire halfstmp = pfhflip ^ h4n;

	// q = the device byte offset; the SDRAM group address
	// interleaves the two chip columns into it (see the header).
	wire [18:0]      q        = {pfpic[14:12], pfpic[11:0], vs[2:0], halfstmp};
	wire [PFCAW-1:0] rom_addr = {q[18:1], 1'b0, q[0]};
	wire             bank_ok  = (pfpic[14:12] < 3'd5);

	// One fetch per four playfield pixels.  Window A is issued one clk after
	// the 4H edge that latches the tile (so `pfpic` is already the new one),
	// window B one clk after the h7 -> h0 boundary.
	logic fetch;
	always_ff @(posedge clk) begin
		if (reset) fetch <= 1'b0;
		else       fetch <= ce_4h_rise | (ce_7m & (h[2:0] == 3'd7));
	end

	logic [15:0] pf_word;
	logic        pf_valid;
	// One hardware fetch = the "P" and "R" column bytes of the same tile row,
	// two bytes apart inside one 4-byte group (see the header).
	skullxbo_gfx_client #(.AW(PFCAW), .GROUP(4), .BEATS(2), .STRIDE(2))
	u_client (
		.clk(clk), .reset(reset),
		.fetch(fetch), .fetch_addr(rom_addr),
		.data(pf_word), .data_valid(pf_valid), .late(pf_late),
		.req(pf_req), .addr(pf_addr), .blen(pf_blen),
		.ack(pf_ack), .group(pf_group));

	wire [15:0] pfd = bank_ok ? pf_word : PF_EMPTY;
	logic [8:0] pf_scroll;

	// ---------------------------------------------------------------------
	// 3. SOS-1 195N — SHCLK = /7M (rising on the count boundary),
	//    /LD = /1H2H (low at h = 3 and h = 7), LDCLK = /4H (rising into h = 0)
	// ---------------------------------------------------------------------
	wire ld_n     = ~(h[1] & h[0]);                 // /1H2H
	wire ce_shclk = ce_7m;                          // /7M rising
	wire ce_ldclk = ce_7m & (h[2:0] == 3'd7);       // /4H rising (into h = 0)

	logic [3:0] sos_pix, sos_q;
	skullxbo_sos1 #(.SHPOL(1'b0), .MODE_P4(1'b0), .SOS1_LAT(SOS1_LAT)) u_195n (
		.clk(clk), .reset(reset),
		.ce_sh(ce_shclk), .ld_n(ld_n), .d(pfd), .hfld(pfhflip), .wratch(1'b0),
		.ce_ldclk(ce_ldclk), .ld(pfpal),
		.pix(sos_pix), .q(sos_q));

	// ---------------------------------------------------------------------
	// 4. PFHS 195M — the scroll register, the column counter and the fine delay
	// ---------------------------------------------------------------------
	skullxbo_pfhs #(.PF_COL_ADJ(PF_COL_ADJ), .PF_FINE_ADJ(PF_FINE_ADJ)) u_195m (
		.clk(clk), .reset(reset),
		.ce_7m(ce_7m), .h(h), .linkres(linkres),
		.hscrl_we(hscrl_we), .hscrl_d(hscrl_d),
		.ps_pix(sos_pix), .ps_pal(sos_q),
		.hs(hs), .xp_pix(pfpix), .xp_pal(pfpal_s),
		.scroll(pf_scroll));

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, pf_valid, pf_scroll, vs[8:3], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
