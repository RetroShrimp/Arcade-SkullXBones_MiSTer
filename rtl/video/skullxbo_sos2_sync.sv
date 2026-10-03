`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones SOS-2 sync generator (Atari custom 137550-001 at 95F,
//  schematic 046903-01 sheet 1).
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  Structure after the Bad
//  Lands core's `badlands_sos2_sync.sv` and the Blasteroids core's
//  `blstroid_sos2_sync.sv` (GPL-3.0, same author): the same Atari custom on
//  the same 14.318181 MHz crystal.  The 7M phase is the opposite of Bad
//  Lands' (see below).
//
//  This module outputs the custom's own pins.  The board re-times the
//  SOS-2's HBLANK and /HSYNC (LS74 80E / 80F / 80C) and gates RSTLB and
//  LINKRES before anything uses them; those board nets are made in
//  skullxbo_hstrobes.sv.
//
//  The 7M / 14MA phase, used everywhere downstream:
//      ce_14m = clk_sys/4   ends one 14MA cycle = one 14.318181 MHz dot
//      ce_7m  = clk_sys/8   ends one H count    = two dots
//      ph     = 0..7        position inside one H count
//
//      ph:        0   1   2   3   4   5   6   7
//      14MA     ‾‾‾‾‾‾‾‾‾___________‾‾‾‾‾‾‾‾‾___________      (m14 = ~ph[1])
//      7M       _______________________‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾      (m7  =  ph[2])
//      cycle    |-------- (H,a) -------|------- (H,b) ------|
//
//  7M is low in the first 14MA cycle of a count, (H,a), and high in the
//  second, (H,b).  Three independent latch clocks on the schematic (LS175
//  230N, LS374 180K/210K, LS374 190K/220K) fix this; getting it wrong swaps
//  the playfield code and colour words and moves the alphanumerics slot.
//  The edge enables below are each high in the one clk_sys cycle whose
//  ending edge is that clock edge, so a register written under one updates
//  on the real edge.  (Deriving them from the levels with a register would
//  put every edge one clk_sys late.)
//
//  The raster:
//      H_TOTAL  456 counts of 7M = 912 dots
//      visible  H = 0..335 (672 dots)
//      V_TOTAL  262 (the vertical counter is inside the custom and not
//               drawn; 263 is the other possibility)
//      visible  V = 0..239
//      VCLK = /256H, so V advances at the 455 -> 0 wrap
//      256V (pin 37) is not connected: every V address on the board is
//           V mod 256
//      SOS-2 HBLANK pin high from H = 326 through the line wrap to H = 6
//           (the core sets HB_START = 326, HB_END = 7).  The start is placed
//           by the program's scanline-interrupt timing and confirmed on
//           hardware (the HUD lands on the right line); skullxbo_hstrobes
//           explains why the end cannot be at the wrap.
//      SOS-2 /HSYNC and /VSYNC positions follow the sibling cores (Bad Lands
//           measured a 5-line /VSYNC on this custom)
//      /VRES    low over the last line (inferred)
//
//  /VRES matters: it is the once-per-frame term of the LS191 vertical-scroll
//  load, which reads alpha row 0 column 55.  With 8-bit V, the reset line is
//  V mod 256 = 5 (V = 261), so V[7:3] = 0 and the word read is 0xFFC06E
//  either way.
//============================================================================

module skullxbo_sos2_sync #(
	// ---- horizontal, in counts of 7M (two dots each) ---------------------
	parameter int H_TOTAL  = 456,   // 912 dots
	parameter int HB_END   = 0,     // SOS-2 HBLANK falls here (the core uses 7)
	parameter int HB_START = 326,   // SOS-2 HBLANK rises here (see the header)
	parameter int HS_START = 377,   // SOS-2 /HSYNC low over 377..408
	parameter int HS_END   = 409,
	// ---- vertical, in lines ----------------------------------------------
	parameter int V_TOTAL  = 262,   // 262 or 263 (see the header)
	parameter int VB_START = 240,   // MAME: 240 visible lines
	parameter int VS_START = 243,
	parameter int VS_END   = 248    // 5 lines, as measured on Bad Lands
)(
	input  logic       clk,        // clk_sys, 57.272727 MHz
	input  logic       reset,      // synchronous, active high (simulation only)
	input  logic       ce_14m,     // clk_sys/4 — ends one 14MA cycle / dot
	input  logic       ce_7m,      // clk_sys/8 — ends one `1H` count

	// ---- clock tree (LEVELS, never use one of these as a clock) ----------
	output logic       m14,        // 14MA: high over the first half of a cycle
	output logic       m14_n,      // /14MA  (= /14MP, /14MB)
	output logic       m7,         // 7M:   LOW in (H,a), HIGH in (H,b)
	output logic       m7_n,       // /7M
	output logic [2:0] ph,         // position 0..7 inside one count
	output logic       pix,        // which 14M dot of the count: 0 = a, 1 = b

	// ---- EXACT clock-edge enables ----------------------------------------
	output logic       ce_m7_rise,   // 7M rising  = the a -> b boundary (ph 3)
	output logic       ce_m7_fall,   // 7M falling = the count boundary  (ph 7)
	output logic       ce_m14_rise,  // 14MA rising, twice a count     (ph 3, 7)
	output logic       ce_m14_fall,  // 14MA falling, twice a count    (ph 1, 5)

	// ---- counters --------------------------------------------------------
	output logic [8:0] h,          // 1H..256H, 0..H_TOTAL-1
	output logic [8:0] v,          // 1V..256V, 0..V_TOTAL-1
	output logic [9:0] x,          // dot position 0..911 = {h, pix}

	// ---- the individual counter taps every later sheet consumes ----------
	output logic       h1,   output logic h1_n,     //   1H  /1H
	output logic       h2,   output logic h2_n,     //   2H  /2H
	output logic       h4,   output logic h4_n,     //   4H  /4H
	output logic       h8,   output logic h16,      //   8H  16H
	output logic       h32,  output logic h64,      //  32H  64H
	output logic       h128, output logic h256,     // 128H 256H
	output logic       h256_n,                      // /256H -> VCLK (pin 39)
	output logic       v1,   output logic v1_n,     //   1V  /1V
	output logic       v2,   output logic v4,       //   2V   4V
	output logic       v8,   output logic v16,      //   8V  16V
	output logic       v32,  output logic v64,      //  32V  64V
	output logic       v128, output logic v256,     // 128V 256V (pin 37 n.c.)

	// ---- the two delayed 4H copies (SOS-2 pins 2 and 19) -----------------
	output logic       h_4hd1h,    // 4HD1H — 4H delayed one count
	output logic       h_4hd1h_n,  // /4HD1H (40K LS04) -> char ROM A0
	output logic       h_4hd2h,    // 4HD2H — 4H delayed two counts
	output logic       h_4hd2h_n,  // /4HD2H (100E LS04) -> the LINKRES gate

	// ---- blanking and sync, AS THE CUSTOM'S PINS EMIT THEM ---------------
	// These are not the board's nets: 80E/80F regenerate HBLANK and 80C
	// re-clocks /HSYNC.  See skullxbo_hstrobes.sv.
	output logic       hblank,     // HBLANK (pin 21), ACTIVE HIGH, RAW
	output logic       hblank_n,   // its complement (not a board net)
	output logic       hsync_n,    // /HSYNC (pin 23), RAW
	output logic       vblank,     // VBLANK (pin 22), ACTIVE HIGH — a board net
	output logic       vblank_n,   // /VBLANK  (watchdog clock, /BLANK)
	output logic       vsync_n,    // /VSYNC (pin 24)
	output logic       vres_n,     // /VRES  (pin 38) -> MOB pin 14, F27 70H

	// ---- display coordinates (this core's contract, not a PCB net) -------
	output logic [9:0] hpos,       // 0..671 while `hde` (dots)
	output logic [8:0] vpos,       // 0..239 while `vde`
	output logic       hde,        // horizontal display enable
	output logic       vde,        // vertical display enable

	// ---- markers, one clk_sys cycle wide, aligned to ce_7m ---------------
	output logic       line_start,   // h == 0
	output logic       frame_start,  // h == 0 and v == 0
	output logic       vblank_start  // h == 0 and v == VB_START
);

	localparam logic [8:0] HTOT = H_TOTAL [8:0];
	localparam logic [8:0] HBE  = HB_END  [8:0];
	localparam logic [8:0] HBS  = HB_START[8:0];
	localparam logic [8:0] HSS  = HS_START[8:0];
	localparam logic [8:0] HSE  = HS_END  [8:0];
	localparam logic [8:0] VTOT = V_TOTAL [8:0];
	localparam logic [8:0] VBS  = VB_START[8:0];
	localparam logic [8:0] VSS  = VS_START[8:0];
	localparam logic [8:0] VSE  = VS_END  [8:0];

	// =====================================================================
	// 1. The clock tree inside one count
	// =====================================================================
	// `ce_7m` ENDS a count and `ce_14m` ENDS a 14MA cycle, so ph is loaded to
	// 0 by ce_7m (the next cycle is the count's first) and to 4 by ce_14m (the
	// next cycle is the second 14MA cycle's first).  Both load it, so it
	// re-locks every dot and cannot drift from the enables it describes.
	always_ff @(posedge clk) begin
		if      (ce_7m)  ph <= 3'd0;
		else if (ce_14m) ph <= 3'd4;
		else             ph <= ph + 3'd1;
	end

	assign pix   =  ph[2];   // 0 over the (H,a) cycle, 1 over (H,b)
	assign m14   = ~ph[1];
	assign m14_n =  ph[1];
	assign m7    =  ph[2];   // LOW in (H,a), HIGH in (H,b)
	assign m7_n  = ~ph[2];

	assign ce_m7_rise  = (ph == 3'd3);
	assign ce_m7_fall  = (ph == 3'd7);
	assign ce_m14_rise = (ph == 3'd3) | (ph == 3'd7);
	assign ce_m14_fall = (ph == 3'd1) | (ph == 3'd5);

	// =====================================================================
	// 2. The counters
	// =====================================================================
	// The SOS-2 has no reset pin and /VRES is an OUTPUT, so on the board the
	// counters free-run from power-on.  The synchronous reset exists only so a
	// testbench starts on a known state.
	wire last_h = (h == HTOT - 9'd1);
	wire last_v = (v  == VTOT - 9'd1);

	always_ff @(posedge clk) begin
		if (reset) begin
			h <= 9'd0;
			v <= 9'd0;
		end else if (ce_7m) begin
			if (last_h) begin
				h <= 9'd0;
				// VCLK = /256H: 256H is high for h = 256..455, so /256H rises
				// at the 455 -> 0 wrap and the V counter advances there.
				v <= last_v ? 9'd0 : (v + 9'd1);
			end else begin
				h <= h + 9'd1;
			end
		end
	end

	assign x = {h, pix};

	// =====================================================================
	// 3. Delayed horizontal taps — 4HD1H (pin 2) and 4HD2H (pin 19)
	// =====================================================================
	always_ff @(posedge clk) begin
		if (reset) begin
			h_4hd1h <= 1'b0;
			h_4hd2h <= 1'b0;
		end else if (ce_7m) begin
			h_4hd1h <= h[2];
			h_4hd2h <= h_4hd1h;
		end
	end
	assign h_4hd1h_n = ~h_4hd1h;
	assign h_4hd2h_n = ~h_4hd2h;

	// =====================================================================
	// 4. Blanking, sync and the frame reset — the CUSTOM'S pins
	// =====================================================================
	// HB_END = 0 means "the SOS-2's HBLANK is high from HB_START to the line
	// wrap"; the general form below also supports a non-zero HB_END.
	wire hb = (HB_END == 0) ? (h >= HBS) : ((h < HBE) | (h >= HBS));
	wire vb = (v >= VBS);

	assign hblank   =  hb;
	assign hblank_n = ~hb;
	assign hsync_n  = ~((h >= HSS) & (h < HSE));
	assign vblank   =  vb;
	assign vblank_n = ~vb;
	assign vsync_n  = ~((v >= VSS) & (v < VSE));
	assign vres_n   = ~last_v;          // position INFERRED (inside the custom)

	// =====================================================================
	// 5. The individual counter taps
	// =====================================================================
	assign h1     =  h[0];   assign h1_n   = ~h[0];
	assign h2     =  h[1];   assign h2_n   = ~h[1];
	assign h4     =  h[2];   assign h4_n   = ~h[2];
	assign h8     =  h[3];   assign h16    =  h[4];
	assign h32    =  h[5];   assign h64    =  h[6];
	assign h128   =  h[7];   assign h256   =  h[8];
	assign h256_n = ~h[8];

	assign v1     =  v[0];   assign v1_n   = ~v[0];
	assign v2     =  v[1];   assign v4     =  v[2];
	assign v8     =  v[3];   assign v16    =  v[4];
	assign v32    =  v[5];   assign v64    =  v[6];
	assign v128   =  v[7];   assign v256   =  v[8];

	// =====================================================================
	// 6. Display coordinates and markers
	// =====================================================================
	assign hde  = ~hb;
	assign vde  = ~vb;
	assign hpos = x - {HBE, 1'b0};
	assign vpos = v;

	assign line_start   = ce_7m & (h == 9'd0);
	assign frame_start  = line_start & (v == 9'd0);
	assign vblank_start = line_start & (v == VBS);

endmodule
