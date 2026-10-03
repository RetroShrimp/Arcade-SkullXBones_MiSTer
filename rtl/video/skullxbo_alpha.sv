`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones alphanumerics (schematic sheet 5): LS374 190K/220K, the
//  27256 character ROM at 250K, LS194A 230K/230L and LS174 190F (ANPAL3:0,
//  ANBO, ANIRQ).
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  The word and the ROM:
//      D15    = ANIRQ / ANBO   one bit with two uses, at two pipeline stages
//      D14:11 = ANPAL3:0
//      D10:0  = the character code, with bit 10 inverted on its way to the
//               ROM (200E LS14): MAME's `code = (data ^ 0x400)`
//
//      char ROM A14..A4 = { NOT(VD10), VD9..VD0 }
//                A3..A1 = 4V, 2V, 1V          the character row 0..7
//                A0     = /4HD1H              which byte of that row
//
//  One word per 16 x 8-dot cell, 64 columns x 32 rows at 0xFFC000 (address
//  0xFFC000 + 2*(V[7:3]*64 + H[8:3])).  H stops at 455, so only columns 0..56
//  are fetched: 0..41 are displayed and 42..56 hold the off-screen per-row
//  command words.  Row 31 is not a character row: it is the motion-object
//  SLIP list, read by the video-RAM slot schedule.
//
//  Pipeline (why a cell is displayed one group late):
//      mux slot  (8k+3, b)                     -> the alpha word
//      LS374 190K/220K  clocked by 4HD14M, rising into (8k+4, b)
//      LS194A    S1 = NOR(1H,2H): parallel load once every four counts,
//                shift the other three, CK = 7MD/14M
//
//  The 27256-450 takes 450 ns (3.2 H counts), so the first load that can use
//  cell k is at the end of h = 7 of group k and the second at the end of
//  h = 3 of group k+1.  /4HD1H is 0 at h = 7 and 1 at h = 3, so the loads
//  take byte 2*row (pixels 0..3) then byte 2*row + 1 (pixels 4..7).  Cell k
//  is therefore displayed over counts 8(k+1)+0 .. 8(k+1)+7: the same lag as
//  the playfield, so the two layers line up and the visible window starts at
//  H = 8.
//
//  The LS194A clock 7MD/14M rises a quarter count after the count boundary;
//  the pens are modelled on the boundary, which is the same thing at the
//  resolution of the doubled alpha pixels.
//
//  ANIRQ is the undelayed 190K bit and changes every eight counts as the
//  fetch walks the columns.  The scanline-interrupt latch (skullxbo_irq)
//  samples it at the rising edge of the board's HBLANK, H = 344, when the
//  latch holds column 42.  This module only outputs the level.
//============================================================================

module skullxbo_alpha (
	input  logic        clk,
	input  logic        reset,

	// ---- raster ----------------------------------------------------------
	input  logic        ce_7m,
	input  logic [8:0]  h,
	input  logic [8:0]  v,
	input  logic        ce_4hd14m_rise,   // LS374 190K/220K clock
	input  logic        h_4hd1h_n,        // /4HD1H -> char ROM A0

	// ---- the video data bus ---------------------------------------------
	input  logic [15:0] vd,

	// ---- the character ROM loader port (250K, 32 KB) --------------------
	input  logic        rom_wr,
	input  logic [14:0] rom_addr,
	input  logic [7:0]  rom_din,

	// ---- outputs ---------------------------------------------------------
	output logic [1:0]  anpix,       // ANPIX1:0
	output logic [3:0]  anpal,       // ANPAL3:0  (LS174 190F)
	output logic        anbo,        // the "opaque" bit, one stage later
	output logic        anirq,       // the SAME bit, undelayed (190K pin 6)
	output logic [15:0] an_word      // the latched word (debug)
);

	// ---------------------------------------------------------------------
	// 1. LS374 190K / 220K
	// ---------------------------------------------------------------------
	always_ff @(posedge clk) begin
		if (reset)               an_word <= 16'b0;
		else if (ce_4hd14m_rise) an_word <= vd;
	end
	assign anirq = an_word[15];

	// ---------------------------------------------------------------------
	// 2. LS174 190F — ANBO and ANPAL3:0, one stage behind
	// ---------------------------------------------------------------------
	// Clocked by /4HD/14M, which rises inside h = 0; modelled on the count
	// boundary into h = 0 so the attributes change with the pens they belong
	// to (a quarter-count difference, invisible at doubled alpha resolution).
	wire ce_190f = ce_7m & (h[2:0] == 3'd7);
	always_ff @(posedge clk) begin
		if (reset) begin
			anbo  <= 1'b0;
			anpal <= 4'b0;
		end else if (ce_190f) begin
			anbo  <= an_word[15];
			anpal <= an_word[14:11];
		end
	end

	// ---------------------------------------------------------------------
	// 3. The 27256 character ROM at 250K (32 KB in BRAM)
	// ---------------------------------------------------------------------
	logic [7:0] charrom [0:32767];
	logic [7:0] rom_q;

	wire [10:0] code     = {~an_word[10], an_word[9:0]};      // 200E inverter
	wire [14:0] rom_radr = {code, v[2:0], h_4hd1h_n};

	always_ff @(posedge clk) begin
		if (rom_wr) charrom[rom_addr] <= rom_din;
		rom_q <= charrom[rom_radr];
	end

	// ---------------------------------------------------------------------
	// 4. LS194A 230K / 230L
	// ---------------------------------------------------------------------
	// S0 = 1 always; S1 = NOR(1H, 2H) -> parallel load once every four counts.
	// 230K (ANPIX1) D,C,B,A = O7, O5, O3, O1 ; 230L (ANPIX0) = O6, O4, O2, O0
	// and the output is QD, so pixel p = { O[7-2p], O[6-2p] } — the leftmost
	// pixel first.
	logic [7:0] sr;
	wire        do_load = (h[1:0] == 2'd3);   // the count ENDING at a 4H/4-count

	always_ff @(posedge clk) begin
		if (reset)      sr <= 8'b0;
		else if (ce_7m) sr <= do_load ? rom_q : {sr[5:0], 2'b0};
	end
	assign anpix = sr[7:6];

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, h[8:3], v[8:3], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
