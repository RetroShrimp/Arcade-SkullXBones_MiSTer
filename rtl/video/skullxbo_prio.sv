`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones: PAL16L8 10F (136072-1142, "PRI") and the F153
//  colour-RAM address multiplexers 10E / 20D / 30D / 30E / 20E (sheet 10).
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  The PAL equations are the 136072-1142 fuse dump, decoded with MAME's
//  `jedutil -view <jed> GAL16V8`:
//
//      /o12 = i1 & /i13
//           + i1 & /i3 & /i4 & /i7 & /i8 & o17
//           + i1 &  i3 & /i4 & /i7 & /i8 & /i11
//           + i1 &  i4 & /i7 & /i8 & /i9 & /i11
//           + i1 & /i6 & /i7 & /i8
//      /o14 = /i1 & i2
//           + i1 & /i3 & /i4 & i7 & i13 & o17
//           + i1 &  i3 & /i4 & i7 & /i11 & i13
//           + i1 &  i4 & i7 & /i9 & /i11 & i13
//           + i1 & /i6 & i7 & i13
//      /o17 = i6 & i9 & i11
//      /o19 = i1 & i13
//           + i1 & /i8 & i15
//
//  A PAL16L8 output pin is the complement of the sum, and the `o17` term in
//  the other equations is the pin, i.e. NOT(i6 & i9 & i11).
//
//      i1  = /CRAMD  (low during a CPU colour-RAM cycle)
//      i2  = BA11                       i3  = LBPRI0     i4  = LBPRI1
//      i5  = NAND(PFPIX3, PFPIX2)       (used by no term)
//      i6  = PFPIX3
//      i7  = LBTL AND (LBPIX == 1)      (F27 70H gate 3)
//      i8  = (LBPIX == 0)               (F260 20C gate 1)
//      i9  = PFPAL2S                    i11 = PFPAL3S
//      i13 = (ANPIX == 0) = NOR(ANBO, ANPIX1, ANPIX0)   (F27 70H gate 1)
//      i15 = LBMISC                     i16 = PFPIX2  (used by no term)
//
//  Pins 5, 16 and 18 are wired on the board but used by no equation; the
//  equations match MAME's independently obtained comment, so the dump is
//  taken as complete.  Do not invent terms for them.
//
//  Where MAME's comment and renderer differ from the fuses:
//    * MAME's (LBPIX == 1) is really LBTL AND (LBPIX == 1), so MOTL is a
//      per-object enable for the shadow effect;
//    * LBMISC is in MAME's comment but not its renderer: the PAL lets LBMISC
//      put a motion object in front of an opaque alpha pixel, while MAME
//      always draws the alpha layer last.
//
//  Colour-RAM A10: pin 14 is inverting, so the physical A10 is the
//  complement of MAME's.  The CPU side goes through the same output, so
//  software index n and video index n both land on physical row
//  n XOR 0x400, and the palette map software sees is MAME's.  So this module
//  outputs `shadow` = MAME's A10 (the sum), and the colour RAM stores the
//  software-visible map.  `a10_pin` is the physical pin.
//============================================================================

module skullxbo_prio (
	// ---- the PAL's inputs, by pin ---------------------------------------
	input  logic       cramd_n,     // pin 1  /CRAMD
	input  logic       ba11,        // pin 2
	input  logic [1:0] lbpri,       // pins 4,3 (LBPRI1, LBPRI0)
	input  logic       lbtl,        // (into the F27 70H pre-term)
	input  logic [4:0] lbpix,
	input  logic       pfpix3,      // pin 6
	input  logic       pfpix2,      // pin 16 — wired, unused
	input  logic [3:0] pfpal_s,     // PFPAL3S..PFPAL0S (pins 11, 9 are 3S, 2S)
	input  logic       lbmisc,      // pin 15
	input  logic       anbo,
	input  logic [1:0] anpix,

	// ---- the rest of the colour-RAM address sources ---------------------
	input  logic [3:0] lbpal,
	input  logic [3:0] pfpix,       // PFPIX3:0 (bit 3 = pfpix3)
	input  logic [3:0] anpal,
	input  logic [10:0] ba,         // BA11..BA1 for the CPU port

	// ---- outputs ---------------------------------------------------------
	output logic       sa,          // pin 12
	output logic       sb,          // pin 19
	output logic       a10_pin,     // pin 14 — the PHYSICAL colour-RAM A10
	output logic       shadow,      // = NOT a10_pin = MAME's CRAM.A10
	output logic [9:0] cram_a       // CRAMA10..CRAMA1 out of the F153s
);

	// ---------------------------------------------------------------------
	// The combinational pre-terms in front of the PAL
	// ---------------------------------------------------------------------
	wire i8  = (lbpix == 5'd0);                       // F260 20C gate 1
	wire i7  = lbtl & (lbpix == 5'd1);                // F27  70H gate 3
	wire i13 = ~(anbo | anpix[1] | anpix[0]);         // F27  70H gate 1

	wire i1  = cramd_n;
	wire i2  = ba11;
	wire i3  = lbpri[0];
	wire i4  = lbpri[1];
	wire i6  = pfpix3;
	wire i9  = pfpal_s[2];
	wire i11 = pfpal_s[3];
	wire i15 = lbmisc;

	// ---------------------------------------------------------------------
	// The equations, verbatim
	// ---------------------------------------------------------------------
	wire o17 = ~(i6 & i9 & i11);

	wire sum12 = ( i1 & ~i13)
	           | ( i1 & ~i3 & ~i4 & ~i7 & ~i8 &  o17)
	           | ( i1 &  i3 & ~i4 & ~i7 & ~i8 & ~i11)
	           | ( i1 &  i4 & ~i7 & ~i8 & ~i9 & ~i11)
	           | ( i1 & ~i6 & ~i7 & ~i8);

	wire sum14 = (~i1 &  i2)
	           | ( i1 & ~i3 & ~i4 &  i7 & i13 &  o17)
	           | ( i1 &  i3 & ~i4 &  i7 & ~i11 & i13)
	           | ( i1 &  i4 &  i7 & ~i9 & ~i11 & i13)
	           | ( i1 & ~i6 &  i7 & i13);

	wire sum19 = ( i1 &  i13)
	           | ( i1 & ~i8 & i15);

	assign sa      = ~sum12;
	assign sb      = ~sum19;
	assign a10_pin = ~sum14;
	assign shadow  =  sum14;

	// ---------------------------------------------------------------------
	// The F153 colour-RAM address mux
	// ---------------------------------------------------------------------
	//   {SB,SA} = 00 motion objects | 01 playfield | 10 alpha | 11 CPU
	//   MO    index = 0x000 + LBPAL*32 + LBPIX      -> 0x000-0x1FF
	//   PF    index = 0x200 + PFPAL_S*16 + PFPIX    -> 0x200-0x2FF
	//   alpha index = 0x300 + ANPAL*4 + ANPIX       -> 0x300-0x33F
	//   CPU   index = BA10:1
	wire [1:0] sel = {sb, sa};
	// Hoisted out of the always_comb to keep iverilog 12 quiet.
	wire [9:0] ba_lo = ba[9:0];

	always_comb begin
		case (sel)
			2'b00: cram_a = {1'b0,  lbpal,        lbpix};
			2'b01: cram_a = {2'b10, pfpal_s,      pfpix};
			2'b10: cram_a = {2'b11, 2'b00, anpal, anpix};
			default: cram_a = ba_lo;
		endcase
	end

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, pfpix2, ba[10], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
