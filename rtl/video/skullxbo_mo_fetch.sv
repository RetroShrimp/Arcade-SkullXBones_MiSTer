`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones motion-object stamp fetch and pixel shifters
//  (schematic sheets 6-8: the five-plane 27512 banks, the LS373
//  60N/70N/50N/80N 32-bit row latch, the LS157 110M/100M plane-4 flip, and
//  SOS-1 20N and 25L).
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  ROM map:
//      MOROMA[17:15] = bank        MOROMA[14:3] = stamp code low 12 bits
//      MOROMA[2:0]   = stamp row   A0 = MOHALF = MO4H XOR MHFLIP
//      byte in device = code[11:0]*16 + row*2 + MOHALF
//      full stamp index = MOROMA[17:3]                (MAME's 0x7fff mask)
//
//  All five planes share MOROMA and MOHALF and are read at once, so a
//  hardware fetch is 40 bits {MOD47:40, MOD37:30, MOD27:20, MOD17:10,
//  MOD07:00}, and a 16-dot slice is two of them (MOHALF 0 and 1) = 80 bits.
//
//  One SDRAM fetch per slice: skullxbo_rom_loader stores the sprite region in
//  16-byte groups, one per (bank, code, row), with byte [2p + h] = plane p of
//  MOHALF h:
//
//      SDRAM region byte = {off[18:1], plane[2:0], off[0]}
//          off = {bank, code[11:0], row, MOHALF} = the device byte offset
//
//  So the whole 10-byte slice is one aligned group, read by skullxbo_gfx_mem
//  in one 8-word burst and returned whole on `mo_gdata`.  The fetch is issued
//  at `stb_d` and used at the next `slice_stb`, a budget of eight H counts
//  (63 clk_sys).  The gfx client also de-interleaves: lane k is plane k>>1 of
//  MOHALF k&1.
//
//  MODp7 is the leftmost pixel of a byte (MAME molayout x offset 0), and
//  plane 4 is the most significant pen bit.
//
//  Six banks x five planes, 23 sockets fitted:
//    * plane 4 of banks 3 and 4 is not fitted and reads 0x00 through the
//      680 R pull-downs R95..R102, which is also what the download image
//      holds there;
//    * bank 5 (MOROMA[17:15] = 5) has no ROM in any plane and the four low
//      planes have no pull resistors, so the MOD buses float.  Stamp codes
//      0x5000-0x7FFF reach it.  This model returns `MO_EMPTY` (40'h0 = pen 0,
//      transparent).  MAME instead takes `code % 20480`, mirroring banks 0-4
//      into bank 5.
//
//  The slice pipeline.  A 16-dot slice takes eight H counts.  The MOB
//  presents it at a group boundary; this module fetches it during that group
//  and shifts the sixteen pens out over the next group.  The one-group delay
//  is invisible: MHPOS is an absolute line-buffer address, so a later write
//  lands in the same place.
//
//      MO4H = the slice's half     selects the ROM byte  (8 dots each)
//      MO2H = the quarter          selects the LS373 pair (4 dots each)
//      MOHALF = MO4H XOR MHFLIP
//      LS373 pairs 60N/70N = pixels 0..3 and 50N/80N = 4..7, swapped by
//                 MO2H XOR MHFLIPO
//      SOS-1 20N  SHCLK = 14MC (one dot), /LD once per 4 dots, HFLD = MHFLIPO
//                 (the nibble order reverses inside the part)
//      SOS-1 25L  SHCLK = LDCLK = 14MC, /LD5 once per 8 dots, eight shifts per
//                 load, HFLD = GND: the plane-4 flip is done outside by the
//                 LS157 pair
//
//  Under MHFLIP the three mechanisms together output the sixteen pens in the
//  order 15, 14, ..., 0: MAME's mirrored tile.
//
//  The pens of a slice come out over dots 1..16 of the display group,
//  because the SOS-1's first load is the 14MC edge that ends dot 0.  That
//  one-dot skew is absorbed by LB_RD_ADJ in skullxbo_video.
//
//  Pen polarity.  The line buffer's write-suppress gate
//  (NOT(1VMOB & MOPIX == 5'b11111)) suggests MOPIX is the complement of the
//  pen, while the plane-4 pull-downs suggest the SOS-1 path is non-inverting
//  overall.  Both cannot hold.  The transparent pen is 0 (MAME transpen 0,
//  and PAL 10F's (LBPIX == 0) test), so this model carries the true pen and
//  the line buffer suppresses pen 0.  An inversion on both the write and the
//  read side would cancel and not be visible.
//============================================================================

module skullxbo_mo_fetch #(
	parameter int MOCAW = 22,   // the arbiter's byte address width
	parameter logic [39:0] MO_EMPTY = 40'h0
)(
	input  logic        clk,
	input  logic        reset,

	// ---- raster ----------------------------------------------------------
	input  logic        ce_14m,       // one dot
	input  logic        ce_7m,
	input  logic [8:0]  h,
	input  logic        pix,

	// ---- from the MOB ----------------------------------------------------
	input  logic        slice_stb,    // the group boundary
	input  logic        slice_live,   // /GS
	input  logic [14:0] mo_code,
	input  logic [2:0]  mo_row,
	input  logic        mhflip,
	input  logic [9:0]  mhpos,
	input  logic [3:0]  mopal,
	input  logic [1:0]  mopri,
	input  logic        motl,
	input  logic        momisc,

	// ---- the graphics-ROM client (40 bits per fetch) ---------------------
	output logic            mo_req,
	output logic [MOCAW-1:0] mo_addr,
	output logic [3:0]      mo_blen,
	input  logic            mo_ack,
	input  logic [127:0]    mo_gdata,   // the 16-byte group
	output logic            mo_late,

	// ---- to the line buffer ---------------------------------------------
	output logic        lb_loadlb,    // /LOADLB, one clk at the group's dot 0
	output logic [9:0]  lb_pos,       // MHPOS9:0 for the F163 load
	output logic [4:0]  lb_pen,       // MOPIX4:0, the TRUE pen
	output logic [7:0]  lb_attr,      // {MOTL, MOPAL3:0, MOPRI1:0, MOMISC}
	output logic        lb_live       // /GS for the slice being shifted
);

	// The dot index inside the group, and the dot the next `ce_14m` starts.
	wire [3:0] dot   = {h[2:0], pix};
	wire [3:0] ndot  = dot + 4'd1;
	wire       dot0  = (dot == 4'd0);

	// =====================================================================
	// 1. Capture the slice the MOB has just presented
	// =====================================================================
	// The MOB registers its outputs ON `slice_stb`, so they are valid one
	// clk_sys cycle later.
	logic        stb_d;
	logic [14:0] f_code;
	logic [2:0]  f_row;
	logic        f_flip;
	logic [9:0]  f_pos;
	logic [7:0]  f_attr;
	logic        f_live;

	always_ff @(posedge clk) begin
		stb_d <= slice_stb;
		if (reset) begin
			f_code <= 15'd0; f_row <= 3'd0; f_flip <= 1'b0;
			f_pos  <= 10'd0; f_attr <= 8'd0; f_live <= 1'b0;
		end else if (stb_d) begin
			f_code <= mo_code;
			f_row  <= mo_row;
			f_flip <= mhflip;
			f_pos  <= mhpos;
			f_attr <= {motl, mopal, mopri, momisc};
			f_live <= slice_live;
		end
	end

	// =====================================================================
	// 2. The one ROM fetch of the slice
	// =====================================================================
	// The 16-byte group holds plane p of MOHALF h at byte 2p + h, so one
	// ten-beat fetch at the group base brings back the whole slice.  Half 0 is
	// shifted out over the first eight dots and is the byte with
	// `MOHALF = MHFLIP`; half 1 is its complement.
	wire [2:0]  bank    = f_code[14:12];
	wire        bank_ok = (bank < 3'd5);

	// off[18:1] = {bank, code[11:0], row}; off[0] is MOHALF and is the byte
	// index inside the group, not part of the group address.
	wire [MOCAW-1:0] rom_addr = {bank, f_code[11:0], f_row, 4'b0000};

	wire mid_group = ce_7m & (h[2:0] == 3'd3);

	logic fetch;
	always_ff @(posedge clk) begin
		if (reset) fetch <= 1'b0;
		// one clk after `f_*` settle
		else       fetch <= stb_d;
	end

	logic [79:0] mo_group;
	logic        mo_dv;
	skullxbo_gfx_client #(.AW(MOCAW), .GROUP(16), .BEATS(10), .STRIDE(1))
	u_client (
		.clk(clk), .reset(reset),
		.fetch(fetch), .fetch_addr(rom_addr),
		.data(mo_group), .data_valid(mo_dv), .late(mo_late),
		.req(mo_req), .addr(mo_addr), .blen(mo_blen),
		.ack(mo_ack), .group(mo_gdata));

	// De-interleave: lane 2p + h is plane p of MOHALF h.
	logic [39:0] raw_h0, raw_h1;
	always_comb begin
		for (int pl = 0; pl < 5; pl++) begin
			raw_h0[8*pl +: 8] = mo_group[8*(2*pl + (f_flip ? 1 : 0)) +: 8];
			raw_h1[8*pl +: 8] = mo_group[8*(2*pl + (f_flip ? 0 : 1)) +: 8];
		end
	end

	wire [39:0] planes_h0 = bank_ok ? raw_h0 : MO_EMPTY;
	wire [39:0] planes_h1 = bank_ok ? raw_h1 : MO_EMPTY;

	// Double buffer: fetched during group G, shifted out during group G+1.
	logic [39:0] nxt_h0, nxt_h1, cur_h0, cur_h1;
	logic        d_flip, d_live;
	logic [9:0]  d_pos;
	logic [7:0]  d_attr;

	// `d_*` lag `f_*` by one group: `f_*` is the slice being FETCHED, `d_*` the
	// slice being SHIFTED OUT.  The nonblocking assignment at `stb_d` copies
	// the OLD `f_*`, which is exactly the previous group's slice.
	always_ff @(posedge clk) begin
		if (reset) begin
			nxt_h0 <= 40'd0; nxt_h1 <= 40'd0;
			cur_h0 <= 40'd0; cur_h1 <= 40'd0;
			d_flip <= 1'b0;  d_live <= 1'b0;
			d_pos  <= 10'd0; d_attr <= 8'd0;
		end else begin
			// ONE fetch per slice, issued at the previous group's `stb_d` and
			// landing well before this `slice_stb`.
			if (slice_stb) begin
				nxt_h0 <= planes_h0;
				nxt_h1 <= planes_h1;
			end
			if (stb_d) begin
				cur_h0 <= nxt_h0;
				cur_h1 <= nxt_h1;
				d_flip <= f_flip;
				d_live <= f_live;
				d_pos  <= f_pos;
				d_attr <= f_attr;
			end
		end
	end

	// `lb_live`, `lb_attr` change at the END of dot 0, so the write of the
	// previous slice's last pen (which happens at that same edge) still sees
	// the old values.
	always_ff @(posedge clk) begin
		if (reset) begin
			lb_live <= 1'b0;
			lb_attr <= 8'd0;
		end else if (ce_14m && dot0) begin
			lb_live <= d_live;
			lb_attr <= d_attr;
		end
	end
	assign lb_pos    = d_pos;
	assign lb_loadlb = ce_14m & dot0;

	// =====================================================================
	// 3. The LS373 32-bit row latch and the LS157 plane-4 flip
	// =====================================================================
	wire        nhalf = ndot[3];
	wire        nquad = ndot[2];
	wire [39:0] selb  = nhalf ? cur_h1 : cur_h0;
	wire [7:0]  p0 = selb[7:0];
	wire [7:0]  p1 = selb[15:8];
	wire [7:0]  p2 = selb[23:16];
	wire [7:0]  p3 = selb[31:24];
	wire [7:0]  p4 = selb[39:32];

	// Exactly one LS373 pair is output-enabled; the pair swaps with MHFLIPO.
	wire [2:0] base = (nquad ^ d_flip) ? 3'd3 : 3'd7;

	function automatic logic [15:0] pack4(input logic [7:0] a3,
	                                      input logic [7:0] a2,
	                                      input logic [7:0] a1,
	                                      input logic [7:0] a0,
	                                      input logic [2:0] b);
		pack4 = { a3[b],        a2[b],        a1[b],        a0[b],
		          a3[b - 3'd1], a2[b - 3'd1], a1[b - 3'd1], a0[b - 3'd1],
		          a3[b - 3'd2], a2[b - 3'd2], a1[b - 3'd2], a0[b - 3'd2],
		          a3[b - 3'd3], a2[b - 3'd3], a1[b - 3'd3], a0[b - 3'd3] };
	endfunction

	wire [15:0] d20n = pack4(p3, p2, p1, p0, base);

	// The LS157 pair: a straight or reversed copy of the plane-4 byte, landing
	// on 25L's D15,D11,D7,D3 (MOD47..MOD44) and D14,D10,D6,D2 (MOD43..MOD40).
	wire [7:0]  p4m  = d_flip
	                 ? {p4[0],p4[1],p4[2],p4[3],p4[4],p4[5],p4[6],p4[7]}
	                 :  p4;
	wire [15:0] d25l = { p4m[7], p4m[3], 2'b00,
	                     p4m[6], p4m[2], 2'b00,
	                     p4m[5], p4m[1], 2'b00,
	                     p4m[4], p4m[0], 2'b00 };

	// =====================================================================
	// 4. The two SOS-1 shifters
	// =====================================================================
	// The load edges are the `14MC` edges that END dots 0, 4, 8, 12 (20N) and
	// dots 0, 8 (25L).
	wire ld20n_n = ~(dot[1:0] == 2'b00);
	wire ld25l_n = ~(dot[2:0] == 3'b000);

	logic [3:0] pix20n, q20n, pix25l, q25l;

	skullxbo_sos1 #(.SHPOL(1'b1), .MODE_P4(1'b0), .SOS1_LAT(0)) u_20n (
		.clk(clk), .reset(reset),
		.ce_sh(ce_14m), .ld_n(ld20n_n), .d(d20n), .hfld(d_flip), .wratch(1'b1),
		.ce_ldclk(1'b0), .ld(4'd0),
		.pix(pix20n), .q(q20n));

	skullxbo_sos1 #(.SHPOL(1'b0), .MODE_P4(1'b1), .SOS1_LAT(0)) u_25l (
		.clk(clk), .reset(reset),
		.ce_sh(ce_14m), .ld_n(ld25l_n), .d(d25l), .hfld(1'b0), .wratch(1'b1),
		.ce_ldclk(1'b0), .ld(4'd0),
		.pix(pix25l), .q(q25l));

	// F04 110F re-inverts 25L's PIX3 into MOPIX4.
	assign lb_pen = {~pix25l[3], pix20n};

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, q20n, q25l, pix25l[2:0], mo_dv, h[8:3],
	                 ndot[1:0], mid_group, 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
