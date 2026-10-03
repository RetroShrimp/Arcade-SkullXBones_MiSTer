`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones: the Atari SOS-1 (137550-001) pixel shifter.  One
//  parameterised model, used three times: 195N (playfield, sheet 5), 20N
//  (motion-object planes 3..0, sheet 8) and 25L (plane 4, sheet 8).
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  The part: a 16-bit parallel-load shift register, four bits wide, with a
//  four-bit attribute latch whose output is delayed to match the pixel path,
//  plus three mode straps (FUNC, SHPOL, WRATCH).
//
//      /LD    low, sampled at SHCLK   -> load all 16 bits of D15:0
//      SHCLK  each edge               -> output the next four-bit group on PIX3:0
//      HFLD   0 -> D15:12, D11:8, D7:4, D3:0 ; 1 -> that order reversed
//                 (the four bits of a group are the bit-planes of one pixel
//                  and keep their order)
//      LDCLK  captures LD3:0, which appears on Q3:0 delayed by the pixel-path
//             latency
//
//  Straps as this board sets them:
//    instance   FUNC   SHPOL        WRATCH   HFLD      groups per load
//    195N PF    GND    GND (inv)    GND      PFHFLIP   4 x 4 bits
//    20N  MO    GND    +5V (true)   live     MHFLIPO   4 x 4 bits
//    25L  P4    GND    GND (inv)    live     GND       8 x 1 bit
//
//  SHPOL low = inverting outputs.  This is inferred (the part is undumped)
//  and agrees with three independent facts: the playfield ROMs are stored
//  complemented (MAME's ROMREGION_INVERT) and PFPAL3:0 come off an LS175's
//  /Q pins; 20N needs no inverter; and 25L's empty plane-4 banks read 0x00
//  through pull-downs and must come out as MOPIX4 = 0 after the external F04
//  110F inverter.  SHPOL inverts both the PIX and the Q path.
//
//  MODE_P4 is the eight-shift plane-4 mode.  25L's /LD fires once per
//  plane-4 ROM byte, i.e. once per eight dots, and only PIX3 is wired out, so
//  the part must shift eight times and output D15, D11, D7, D3, D14, D10,
//  D6, D2, the order the 110M/100M LS157 wiring requires.  WRATCH (live on
//  both MO instances, grounded on the playfield) is the likely mode control;
//  since the mode is static it is modelled as a parameter, and the `wratch`
//  pin is carried but unused.
//
//  SOS1_LAT is the fixed latency of both paths in SHCLK periods.  The part
//  only guarantees that the two are equal; 0 (the load edge presents group 0)
//  is what matches MAME's frames.
//============================================================================

module skullxbo_sos1 #(
	parameter bit SHPOL    = 1'b0,  // 0 = GND = INVERTING outputs
	parameter bit MODE_P4  = 1'b0,  // 1 = the eight-shift plane-4 mode (25L)
	parameter int SOS1_LAT = 0      // fixed latency of BOTH paths, in SHCLK
)(
	input  logic        clk,
	input  logic        reset,

	input  logic        ce_sh,      // SHCLK rising — one shift/load decision
	input  logic        ld_n,       // /LD, sampled at SHCLK
	input  logic [15:0] d,          // D15:0
	input  logic        hfld,       // HFLD
	input  logic        wratch,     // WRATCH (unused, see the header)

	input  logic        ce_ldclk,   // LDCLK rising
	input  logic [3:0]  ld,         // LD3:0

	output logic [3:0]  pix,        // PIX3:0
	output logic [3:0]  q           // Q3:0
);

	// ---------------------------------------------------------------------
	// The pixel path
	// ---------------------------------------------------------------------
	// `sr` holds the remaining groups, MSB group first.  A load writes the
	// whole ordered sequence; a shift drops the group just emitted.
	logic [31:0] sr;

	// The load order.  MODE 0: four nibbles.  MODE 1: eight single bits, taken
	// from the eight live D pins of 25L in the order the LS157 pair forces.
	function automatic logic [31:0] load_order(input logic [15:0] dd,
	                                           input logic flip);
		logic [31:0] r;
		logic [7:0]  s;
		begin
			// PIX3 emits D15, D11, D7, D3, D14, D10, D6, D2 in MODE_P4.
			// Each group is then one bit, carried in the group's MSB.
			s = {dd[15], dd[11], dd[7], dd[3], dd[14], dd[10], dd[6], dd[2]};
			if (flip) s = {s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]};
			if (MODE_P4)
				r = {s[7], 3'b0, s[6], 3'b0, s[5], 3'b0, s[4], 3'b0,
				     s[3], 3'b0, s[2], 3'b0, s[1], 3'b0, s[0], 3'b0};
			else if (flip)
				r = {dd[3:0], dd[7:4], dd[11:8], dd[15:12], 16'b0};
			else
				r = {dd[15:12], dd[11:8], dd[7:4], dd[3:0], 16'b0};
			load_order = r;
		end
	endfunction

	always_ff @(posedge clk) begin
		if (reset)      sr <= 32'b0;
		else if (ce_sh) sr <= (!ld_n) ? load_order(d, hfld)
		                              : {sr[27:0], 4'b0};
	end

	wire [3:0] pix_raw = sr[31:28];
	wire [3:0] q_raw_now = ld;

	// ---------------------------------------------------------------------
	// The attribute path — LD3:0 captured at LDCLK, delayed SOS1_LAT SHCLKs
	// ---------------------------------------------------------------------
	logic [3:0] qlat;
	always_ff @(posedge clk) begin
		if (reset)         qlat <= 4'b0;
		else if (ce_ldclk) qlat <= q_raw_now;
	end

	generate
		if (SOS1_LAT == 0) begin : g_nolat
			assign pix = SHPOL ? pix_raw : ~pix_raw;
			assign q   = SHPOL ? qlat    : ~qlat;
		end else begin : g_lat
			logic [3:0] pdly [0:SOS1_LAT-1];
			logic [3:0] qdly [0:SOS1_LAT-1];
			always_ff @(posedge clk) if (ce_sh) begin
				pdly[0] <= pix_raw;
				qdly[0] <= qlat;
				for (int i = 1; i < SOS1_LAT; i++) begin
					pdly[i] <= pdly[i-1];
					qdly[i] <= qdly[i-1];
				end
			end
			assign pix = SHPOL ? pdly[SOS1_LAT-1] : ~pdly[SOS1_LAT-1];
			assign q   = SHPOL ? qdly[SOS1_LAT-1] : ~qdly[SOS1_LAT-1];
		end
	endgenerate

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, wratch, 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
