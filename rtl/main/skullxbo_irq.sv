`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones interrupts (schematic sheet 2): the LS11 90E band
//  decoder, the LS10 90C gates, the LS74 130C-A scanline latch, the LS74
//  110C-A VBLANK latch and the LS00 120C / LS10 90C IPL encoder.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Structure ported from
//  `Arcade-Badlands_MiSTer/rtl/main/badlands_irq.sv` (GPL-3.0, same
//  author); the three levels, the band gate and both acknowledge paths are
//  this board's.
//
//  The parts:
//    LS11 90E    : /1V & 2V & 4V                  (high when V mod 8 == 6)
//    LS10 90C    : NAND(90E, ANIRQ, /VBLANK)      -> 130C-A D
//    LS74 130C-A : CK = HBLANK (board net), /PRE = /IRQACK, /Q = IRQ1 pending
//    LS74 110C-A : D = GND, CK = VBLANK (SOS-2 pin), /PRE = /VBLACK,
//                  /Q = IRQ2 pending
//    /IPL2 = SCOM 120E FULL, direct
//    /IPL1 = NAND(/IPL2, IRQ2 pending)                    (LS00 120C)
//    /IPL0 = NAND(/IPL2, IRQ1 pending, /IPL1)             (LS10 90C)
//
//  Resulting levels (all autovectored):
//    pending          /IPL2 /IPL1 /IPL0   level
//    sound (SCOM)       0     1     1       4
//    VBLANK only        1     0     1       2
//    scanline only      1     1     0       1
//    none               1     1     1       0
//
//  A higher level hides a lower one without losing it: the latches stay set
//  and the lower level appears once the higher one clears.
//
//  IRQ1, the scanline interrupt, sets at a rising edge of the board's HBLANK
//  (the delayed net from the sheet-1 chain, not the SOS-2 pin) when
//  V mod 8 == 6, ANIRQ is set and the raster is not in vertical blanking.
//  ANIRQ is bit 15 of the alphanumerics word being fetched at that moment
//  (about column 46), so the HBLANK timing decides which word is sampled.
//  Acknowledged by a write to FF1F00 (or its FF1D00 mirror).  /PRE is level
//  sensitive and wins over the clock.
//
//  IRQ2, VBLANK, sets on the rising edge of the SOS-2 VBLANK pin and is
//  acknowledged by a write to FF1000.  (The manual's memory map calls FF1F00
//  "the video IRQ acknowledge"; that is the scanline interrupt.)
//
//  IRQ4, sound, is the SCOM's FULL output, cleared when the 68000 reads
//  FF5001; there is no separate acknowledge.
//
//  Reset: neither latch is cleared by /RESET on the board; the boot code
//  acknowledges both.  `reset` here is an FPGA power-up initialiser only, so
//  a watchdog reset leaves a pending VBLANK request pending, as on hardware.
//============================================================================

module skullxbo_irq
(
	input  logic       clk,        // clk_sys
	input  logic       reset,      // POWER-UP only (see the header)

	// ---- the raster (from the SOS-2 and the sheet-1 HBLANK chain) ----
	input  logic       v1_n,       // /1V  -- LS11 90E pin 11
	input  logic       v2,         //  2V  -- pin 10
	input  logic       v4,         //  4V  -- pin 9
	input  logic       vblank,     // SOS-2 pin 22, RAW, ACTIVE HIGH
	input  logic       hblank,     // the board's HBLANK, ACTIVE HIGH

	// ---- from the video side ----
	// D15 of the alpha word currently in the LS374 190K latch, ACTIVE HIGH.
	// Sampled ONLY at the rising edge of the board's HBLANK.
	input  logic       anirq,

	// ---- the two acknowledge strobes (LS138 130A Y4 / LS139 170J Y2) ----
	input  logic       irqack_n,   // FF1F00 / FF1D00, LEVEL, /PRE of 130C-A
	input  logic       vblack_n,   // FF1000,          LEVEL, /PRE of 110C-A

	// ---- the SCOM's FULL output, direct ----
	input  logic       scom_full_n,// /IPL2, ACTIVE LOW

	output logic [2:0] ipl,        // {/IPL2, /IPL1, /IPL0}, ACTIVE LOW
	output logic       irq1_pend,  // 130C-A /Q (debug only)
	output logic       irq2_pend   // 110C-A /Q (debug only)
);

	// ---------------- LS11 90E + LS10 90C (the D input) -------------------
	wire band6   = v1_n & v2 & v4;             // V mod 8 == 6
	wire d_130c  = ~(band6 & anirq & ~vblank); // LS10 90C pin 6 (a 3-input NAND)

	// ---------------- LS74 130C-A : the scanline latch --------------------
	logic hblank_q;
	always_ff @(posedge clk) hblank_q <= hblank;
	wire hblank_rise = hblank & ~hblank_q;

	logic q130c;
	always_ff @(posedge clk) begin
		if (reset)            q130c <= 1'b1;      // power-up: no request
		else if (!irqack_n)   q130c <= 1'b1;      // /PRE, level, dominates
		else if (hblank_rise) q130c <= d_130c;
	end
	assign irq1_pend = ~q130c;                    // pin 6 = /Q

	// ---------------- LS74 110C-A : the VBLANK latch ----------------------
	logic vblank_q;
	always_ff @(posedge clk) vblank_q <= vblank;
	wire vblank_rise = vblank & ~vblank_q;

	logic q110c;
	always_ff @(posedge clk) begin
		if (reset)            q110c <= 1'b1;      // power-up: no request
		else if (!vblack_n)   q110c <= 1'b1;      // /PRE, level, dominates
		else if (vblank_rise) q110c <= 1'b0;      // D = GND
	end
	assign irq2_pend = ~q110c;                    // pin 6 = /Q

	// ---------------- LS00 120C + LS10 90C : the IPL encoder --------------
	assign ipl[2] = scom_full_n;                          // direct
	assign ipl[1] = ~( scom_full_n & irq2_pend );         // LS00 120C pin 8
	assign ipl[0] = ~( scom_full_n & irq1_pend & ipl[1] );// LS10 90C pin 12

endmodule
