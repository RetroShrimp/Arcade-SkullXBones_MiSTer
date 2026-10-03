`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones: the Atari PFHS (137419-104) at 195M, schematic sheet
//  5.  The playfield horizontal scroll register, the scrolled tile-column
//  counter and the 0-7 pixel fine-scroll delay line.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  The part is three things in one package:
//   1. a nine-bit scroll register, D8:0 = BD15:7, latched on HS = /HSCRL
//      (nine bits, which is what MAME's `2 * (xscroll >> 7)` needs);
//   2. a scrolled tile-column counter 8HS..256HS, six bits, restarted every
//      line by ST = /LINKRES, which replaces H[8:3] on the video-RAM address
//      muxes;
//   3. an eight-bit-wide 0-7 pixel delay line carrying the pen PS3:0 and the
//      palette PS7:4 together, out on XP3:0 = PFPIX3:0 and XP7:4 = PFPAL3S:0S.
//
//  What the coarse counter and the fine delay compute.  MAME: screen dot x
//  shows playfield dot x + 2*scroll; in playfield pixels (one H count each)
//  screen count m shows pixel m + scroll, i.e. column (m + scroll) >> 3 and
//  pixel (m + scroll) & 7.  The pixel path can only delay, so with
//  s = scroll[2:0] the part outputs at count m the pen shifted out d counts
//  earlier, which is pixel (m - d) & 7 of column C(m - d).  Choosing
//
//        d = (8 - s) & 7        and        C(n) = (n >> 3) + scroll[8:3] + c
//        with the coarse carry  c = (s != 0)
//
//  gives pixel (m + s) & 7 of column ((m + s) >> 3) + scroll[8:3] for every s.
//
//  The column source is a counter restarted by ST, not a function of H.  The
//  line is 456 counts = 57 groups and the tilemap is 64 columns, so a closed
//  form such as H[8:3] + scroll[8:3] would jump 8 columns at the H counter's
//  own 455 -> 0 wrap.  That jump lands on the tile shown at H = 0..7, whose
//  pens the fine delay pulls into the left edge of the picture.
//
//  A tile appears one 8-count group after the group whose video-RAM slots
//  fetched it, which matches the visible window starting at H = 8.
//  PF_COL_ADJ is an extra trim in tiles on top of that (0 in this core).
//============================================================================

module skullxbo_pfhs #(
	parameter int PF_COL_ADJ = 0,   // screen-group to fetch-group trim, in tiles
	parameter int PF_FINE_ADJ = 0   // extra fixed delay, in PF pixels
)(
	input  logic        clk,
	input  logic        reset,

	input  logic        ce_7m,       // CK = /7M: one playfield pixel
	input  logic [8:0]  h,           // the SOS-2 H counter
	input  logic        linkres,     // ST (the per-line restart window)

	// ---- the scroll register: HS = /HSCRL, D8:0 = BD15:7 -----------------
	// `hscrl_we` is the rising edge of /HSCRL (one clk_sys) and `hscrl_d` is
	// BD15:7 -- nine bits.
	input  logic        hscrl_we,
	input  logic [8:0]  hscrl_d,

	// ---- the pipeline: PS3:0 = SOS-1 PIX3:0, PS7:4 = SOS-1 Q3:0 ---------
	input  logic [3:0]  ps_pix,
	input  logic [3:0]  ps_pal,

	// ---- outputs ---------------------------------------------------------
	output logic [5:0]  hs,          // 8HS (bit 0) .. 256HS (bit 5)
	output logic [3:0]  xp_pix,      // XP3:0 = PFPIX3:0
	output logic [3:0]  xp_pal,      // XP7:4 = PFPAL3S:0S
	output logic [8:0]  scroll       // the scroll register (debug)
);

	// ---------------------------------------------------------------------
	// 1. The nine-bit scroll register (pin 16 `HS`, pins 6-15 `D8:0`)
	// ---------------------------------------------------------------------
	always_ff @(posedge clk) begin
		if (reset)         scroll <= 9'd0;
		else if (hscrl_we) scroll <= hscrl_d;
	end

	// `ST` latches the value the line will actually use.
	logic [8:0] scr_line;
	always_ff @(posedge clk) begin
		if (reset)        scr_line <= 9'd0;
		else if (linkres) scr_line <= scroll;
	end

	wire       carry = |scr_line[2:0];

	// ---------------------------------------------------------------------
	// 1b. The tile-column counter, restarted by ST
	// ---------------------------------------------------------------------
	// ST (/LINKRES, H = 442..445) is a level, so the counter holds the load
	// value while it is asserted; it steps on the 4H rising edge (pin 35),
	// mid-group at H = 4 mod 8, so the address never changes across the
	// playfield slots at (8k+2,b) / (8k+3,a).  The load value makes every slot
	// of the line present column H[8:3] + PF_COL_ADJ + scroll[8:3] + carry,
	// except the last group, which continues the count instead of jumping
	// back at the H wrap (see the header).
	wire [5:0] col_load = scr_line[8:3] + {5'd0, carry}
	                    + PF_COL_ADJ[5:0] - 6'd1;
	wire       ce_tile  = ce_7m & (h[2:0] == 3'd3);   // 4H rising, pin 35

	logic [5:0] col;
	always_ff @(posedge clk) begin
		if (reset)        col <= 6'd0;
		else if (linkres) col <= col_load;
		else if (ce_tile) col <= col + 6'd1;
	end

	// {256HS..8HS}, modulo 64 (there is no 512HS pin)
	assign hs = col;

	// ---------------------------------------------------------------------
	// 2. The 0-7 playfield-pixel fine delay line, eight bits wide
	// ---------------------------------------------------------------------
	logic [7:0] pipe [0:7];
	always_ff @(posedge clk) if (ce_7m) begin
		pipe[0] <= {ps_pal, ps_pix};
		for (int i = 1; i < 8; i++) pipe[i] <= pipe[i-1];
	end

	wire [3:0] tap = ((4'd8 - {1'b0, scr_line[2:0]}) & 4'd7) + PF_FINE_ADJ[3:0];
	// `tap3` is hoisted out of the always_comb to keep iverilog 12 quiet.
	wire [2:0] tap3 = tap[2:0];
	logic [7:0] outw;
	always_comb begin
		case (tap3)
			3'd0: outw = {ps_pal, ps_pix};
			default: outw = pipe[tap3 - 3'd1];
		endcase
	end
	assign xp_pix = outw[3:0];
	assign xp_pal = outw[7:4];

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, h[8:3], tap[3], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
