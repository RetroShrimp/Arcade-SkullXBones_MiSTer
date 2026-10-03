`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones playfield vertical-scroll counters (LS191 150H / 130H /
//  140H, schematic sheet 6; the /LOAD term from 170H F02, 60H LS32 and 70H
//  F27).
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  Exactly three things change 1VS..256VS:
//   1. /SLIP's rising edge, once per line in the LINKRES window, counts up
//      by one (D/U is tied to GND).  /SLIP is the clock, not a load.  The
//      count is enabled only outside vertical blanking: 140H's /CTEN (pin 4)
//      is the VBLANK net, so the chain holds during VBLANK and a scroll value
//      written in VBLANK is still in place at the top of the next frame.
//   2. A CPU write to /VSCRL (FF406C): an asynchronous load from VD15:7 while
//      /VWRH and /VSCRL are both low.
//   3. The once-per-frame window LINKRES & VRES & 4H & /4HD14M, exactly one
//      14MA cycle wide at (444, a), when the alphanumerics word of row 0,
//      column 55 (0xFFC06E) is on VD.  This is MAME's "scanline 0 should
//      re-latch the previous raw scroll": a hardware read of alpha RAM.
//
//  There is no fourth term; nothing on the schematic compares data bits
//  against 0xD.  Mid-screen scroll changes are made by the CPU's scanline
//  interrupt handler (/WAITHBL, then FF406C and FF1E80).  A core that decodes
//  MAME's per-band command words would reload the scroll from ordinary
//  character codes in alpha row 30 during gameplay.
//
//  Sign: the hardware loads the scroll at the top of the frame and counts up,
//  so the ROM sees scroll + line.  MAME's `(yscroll >> 7) - scanline` with a
//  tilemap that adds the scroll is the same number.
//
//  Within a line: /SLIP is low in (442,b) and its rising edge at the end of
//  that cycle is the count, in horizontal blanking after the visible part of
//  the line.  So the value used over line y is the one counted at the end of
//  line y-1, and the frame window at (444,a) of the /VRES line comes after
//  that line's own count.  Net effect: VS over the visible part of line y is
//  yscroll_raw + y, bit for bit MAME's tilemap row.
//============================================================================

module skullxbo_vscroll #(
	// 1 = 140H /CTEN is the VBLANK net (sheet 6, pin 4), so the chain holds
	// through vertical blanking.  0 counts every /SLIP edge (test only).
	parameter bit VS_CTEN_VBLANK = 1'b1
)(
	input  logic        clk,
	input  logic        reset,

	// ---- the clock: /SLIP's RISING edge (PAL 110E pin 17) ----------------
	input  logic        ce_slip_rise,

	// ---- the asynchronous load terms ------------------------------------
	// `vscrl_load` is a level, high while /VWRH and /VSCRL are both low
	// (170H F02-A), with the data on `vscrl_d` = VD15:7.  It is a level
	// because the LS191 /LOAD is asynchronous: the outputs follow the D
	// inputs while it is asserted.
	input  logic        vscrl_load, // term 1: NOR(/VWRH, /VSCRL)
	input  logic [8:0]  vscrl_d,    // VD15:7 while `vscrl_load`
	input  logic        linkres,    // 100E LS04 pin 12
	input  logic        vres_n,     // SOS-2 pin 38
	input  logic        vblank,     // SOS-2 VBLANK -> 140H /CTEN (pin 4)
	input  logic        h4,         // 4H
	input  logic        h4d14m,     // 4HD14M

	// ---- the data for TERM 2: the video data bus, D15:7 -----------------
	// Term 2 is a hardware read of alphanumerics RAM (row 0, column 55), so it
	// takes the live `vd`; term 1 takes `vscrl_d`.  On the board both are the
	// same nine wires (the LS191 D inputs are VD15:7).
	input  logic [15:0] vd,

	output logic [8:0]  vs,         // 1VS (bit 0) .. 256VS (bit 8)
	output logic        load_win    // /LOAD is asserted (debug)
);

	// 170H F02-A : NOR(/VWRH, /VSCRL) -- `vscrl_load` from skullxbo_main
	wire term_cpu   = vscrl_load;
	// 60H LS32 : 4HD14M OR /4H ;  70H F27 : NOR(/LINKRES, /VRES, that)
	wire term_frame = linkres & ~vres_n & h4 & ~h4d14m;

	assign load_win = term_cpu | term_frame;

	// The LS191 `/LOAD` is ASYNCHRONOUS: while it is asserted the outputs
	// follow `VD15:7`, and they hold the value present when it releases.
	// Modelled as a transparent latch on clk_sys, which is what "follows" means
	// at this sample rate.
	always_ff @(posedge clk) begin
		if (reset)             vs <= 9'd0;
		else if (term_cpu)     vs <= vscrl_d;
		else if (term_frame)   vs <= vd[15:7];
		else if (ce_slip_rise & ~(VS_CTEN_VBLANK & vblank))
		                       vs <= vs + 9'd1;   // D/U = GND: UP only; /CTEN = VBLANK
	end

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, vd[6:0], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
