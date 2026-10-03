`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones on-board horizontal strobes (schematic 046903-01
//  sheet 1: LS74 80E / 80F / 80C, LS02 70E, LS27 210F, LS08 200F, LS11 90E,
//  LS10 90C, LS04 100E/40K, F174 160H).
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  The SOS-2's HBLANK pin is not the board's HBLANK net.  Three flops
//  re-time it, and the board uses both at once: RSTLB is the window in
//  which the delayed board HBLANK is still high while the custom's HBLANK
//  has already ended.  A model with a single HBLANK cannot make RSTLB, and
//  without RSTLB the motion-object line buffers never restart.
//
//  The HBLANK chain:
//      LS74 80E-A : D = HBLANK(sos2), /CLR = HBLANK(sos2), CK = 16H
//                   Q = HBDLY
//      LS02 70E-4 : NOR(/1H2H, /4H) = 1H & 2H & 4H          (h == 7)
//      LS74 80F-A : D = 1, /CLR = HBDLY, CK = (h == 7)
//      LS74 80F-B : D = 80F-A Q, CK = /4HD/14M, Q = HBLANK (board)
//
//  With the SOS-2 blanking from H = 326: 16H rises at 336 (HBLANK already
//  high), the h == 7 edge follows at 343, and the /4HD/14M edge (one per 8
//  counts, at the start of (8k+0, b)) lands at 344.  So the board HBLANK
//  rises at (344,b), while the LS374 190K holds alpha column 42, the only
//  column in which the program sets ANIRQ.  (A start of 336 puts the edge at
//  376, column 46, and the scanline interrupt never fires.)
//
//  Why the custom's HBLANK cannot end at the line wrap:
//      RSTLB = 7M & NOT(HBLANK_sos2) & NOT(8H) & HBLANK_board
//
//  The board HBLANK falls one /4HD/14M edge after the custom's does, at the
//  start of (8k, b) for the first 8-count group at or after it.  If the
//  custom's HBLANK ended exactly at the 455 -> 0 wrap, the board's would
//  fall at (0,b) and the only overlap would be (0,a), where 7M = 0, so RSTLB
//  could never fire.  The custom's HBLANK must therefore end at least one
//  count into the line.  HB_END = 7 makes RSTLB exactly one 14MA cycle wide,
//  at (7,b), the short pulse the schematic implies; the exact value is inside
//  the custom.
//
//  Everything is synchronous on clk_sys under exact-edge enables; nothing
//  here is used as a clock.
//============================================================================

// The SOS-2's own HBLANK position (HB_START / HB_END) is a parameter of
// `skullxbo_sos2_sync`; this module only consumes the resulting pin.

module skullxbo_hstrobes (
	input  logic       clk,
	input  logic       reset,

	// ---- from skullxbo_sos2_sync ----------------------------------------
	input  logic       ce_7m,        // ends an H count
	input  logic [2:0] ph,
	input  logic [8:0] h,
	input  logic       m7,           // 7M level (LOW in (H,a))
	input  logic       hblank_sos2,  // the CUSTOM's pin 21, raw
	input  logic       hsync_sos2_n, // the CUSTOM's pin 23, raw

	// ---- the re-timed board nets ----------------------------------------
	output logic       hbdly,        // 80E-A Q
	output logic       hblank,       // 80F-B Q  — the BOARD's HBLANK
	output logic       hblank_n,     // 80F-B /Q — drives RSTLB and /BLANK
	output logic       hblank_rise,  // 1 clk pulse: the IRQ1 / WAITHBL edge
	output logic       hsync_n,      // 80C-A Q  — the BOARD's /HSYNC

	// ---- the once-per-line windows --------------------------------------
	output logic       rstlb,        // 200F LS08 pin 11
	output logic       linkres,      // 100E LS04 pin 12
	output logic       linkres_n,    // 90C LS10 pin 8
	output logic       q80e2,        // 80E-B Q (debug)

	// ---- the delayed 4H family ------------------------------------------
	output logic       h4d14m,       // F174 160H Q12: 4H delayed one 14MA
	output logic       h4d14m_n,     // /4HD/14M (40K LS04)
	output logic       hd35_n,       // /4HD3.5H (F174 160H Q7) -> LS175 230N
	output logic       m7d14m,       // F74 80H-A Q: 7M delayed one 14MA

	// ---- exact-edge enables for the consumers ---------------------------
	output logic       ce_4h_rise,     // 4H rising: LS374 180K/210K clock
	output logic       ce_hd35_rise,   // /4HD3.5H rising: LS175 230N clock
	output logic       ce_4hd14m_rise, // 4HD14M rising: LS374 190K/220K clock
	output logic       ce_m7d14m_rise, // 7MD/14M rising: LS194A 230K/230L clock
	output logic       ce_4hd14m_fall  // /4HD/14M rising: LS174 190F, 80F-B
);

	// ---------------------------------------------------------------------
	// 0. Plain decodes of the H counter
	// ---------------------------------------------------------------------
	wire h4 = h[2];
	wire h8 = h[3];

	// 4HD2H = 4H delayed two counts (SOS-2 pin 19), regenerated here so this
	// module is self-contained.
	logic h_4hd1h, h_4hd2h;
	always_ff @(posedge clk) begin
		if (reset) begin h_4hd1h <= 1'b0; h_4hd2h <= 1'b0; end
		else if (ce_7m) begin h_4hd1h <= h[2]; h_4hd2h <= h_4hd1h; end
	end

	// ---------------------------------------------------------------------
	// 1. The delayed 4H / 7H family — F174 160H and F74 80H
	// ---------------------------------------------------------------------
	// 160H is clocked by 14MA RISING: ph 3 (into the (H,b) cycle) and ph 7
	// (into the next count's (H,a) cycle).
	wire ce_m14_rise = (ph == 3'd3) | (ph == 3'd7);
	// 80H is clocked by /14MA, i.e. 14MA FALLING: ph 1 and ph 5.
	wire ce_m14_fall = (ph == 3'd1) | (ph == 3'd5);

	wire h3_win = (h[2:0] == 3'd3);   // 70E LS02 pin 1 = /4H & 1H & 2H

	always_ff @(posedge clk) begin
		if (reset) begin
			h4d14m <= 1'b0;
			hd35_n <= 1'b0;
			m7d14m <= 1'b0;
		end else begin
			if (ce_m14_rise) begin
				h4d14m <= h4;
				hd35_n <= h3_win;
			end
			if (ce_m14_fall) m7d14m <= m7;
		end
	end
	assign h4d14m_n = ~h4d14m;

	// Exact-edge enables.  Each is high for the ONE clk_sys cycle whose ending
	// posedge IS the edge named, so a consumer's `always_ff` lands on it.
	assign ce_4h_rise     = ce_7m       & (h[2:0] == 3'd3);       // 3 -> 4
	assign ce_hd35_rise   = ce_m14_rise & ~hd35_n &  h3_win;      // into (h3,b)
	assign ce_4hd14m_rise = ce_m14_rise & ~h4d14m &  h4;          // into (h4,b)
	assign ce_m7d14m_rise = ce_m14_fall & ~m7d14m &  m7;          // ph 5
	// 4HD14M FALLING = /4HD/14M RISING, the 80F-B clock: one edge per 8 counts,
	// at the start of (8k+0, b).
	assign ce_4hd14m_fall = ce_m14_rise &  h4d14m & ~h4;

	// ---------------------------------------------------------------------
	// 2. HBLANK regeneration — 80E-A, 70E-4, 80F-A, 80F-B
	// ---------------------------------------------------------------------
	// 16H rises at the count boundary out of h[4:0] == 15 (h = 15->16, 47->48,
	// ... 335->336, 367->368).  The flop samples D as it was before the edge;
	// with HBLANK_sos2 rising at 326, the edge at 336 sets HBDLY.
	wire ce_16h_rise = ce_7m & (h[4:0] == 5'd15);
	// The `h == 7` clock (70E pin 13) rises at the boundary out of h[2:0] == 6.
	wire ce_h7_rise  = ce_7m & (h[2:0] == 3'd6);

	logic f80fa;

	always_ff @(posedge clk) begin
		if (reset) begin
			hbdly  <= 1'b0;
			f80fa  <= 1'b0;
			hblank <= 1'b0;
		end else begin
			// 80E-A: /CLR = HBLANK_sos2 (asynchronous on the board; modelled
			// as a same-cycle override, which is the only observable
			// difference and is invisible at this clock rate).
			if (!hblank_sos2)        hbdly <= 1'b0;
			else if (ce_16h_rise)    hbdly <= hblank_sos2;

			// 80F-A: D = PR5 = 1, /CLR = HBDLY
			if (!hbdly)              f80fa <= 1'b0;
			else if (ce_h7_rise)     f80fa <= 1'b1;

			// 80F-B: CK = /4HD/14M rising
			if (ce_4hd14m_fall)      hblank <= f80fa;
		end
	end
	assign hblank_n    = ~hblank;
	assign hblank_rise = ce_4hd14m_fall & f80fa & ~hblank;

	// ---------------------------------------------------------------------
	// 3. RSTLB — 210F LS27 + 200F LS08
	// ---------------------------------------------------------------------
	assign rstlb = m7 & ~hblank_sos2 & ~h8 & hblank;

	// ---------------------------------------------------------------------
	// 4. /HSYNC — 80C-A, D = /HSYNC(sos2), CK = 8H
	// ---------------------------------------------------------------------
	wire ce_8h_rise = ce_7m & (h[3:0] == 4'd7);
	always_ff @(posedge clk) begin
		if (reset)            hsync_n <= 1'b1;
		else if (ce_8h_rise)  hsync_n <= hsync_sos2_n;
	end

	// ---------------------------------------------------------------------
	// 5. LINKRES — 80E-B, 90E LS11, 90C LS10, 100E LS04
	// ---------------------------------------------------------------------
	// 80E-B: D = 32H, CK = 16H, /CLR = 32H  =>  Q = 1 over H mod 64 in [48,63]
	always_ff @(posedge clk) begin
		if (reset)                q80e2 <= 1'b0;
		else if (!h[5])           q80e2 <= 1'b0;
		else if (ce_16h_rise)     q80e2 <= h[5];
	end

	// LINKRES = 256H & 128H & Q80E2 & 8H & /4HD2H  ->  H = 442..445
	assign linkres   = h[8] & h[7] & q80e2 & h8 & ~h_4hd2h;
	assign linkres_n = ~linkres;

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, h[6], h_4hd1h, 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
