`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones main CPU: fx68k (a cycle-exact 68000) wired as sheet 2
//  draws the 68000 at 245C.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  The CPU itself is Jorge Cwik's
//  fx68k in `rtl/lib/fx68k/` (GPL-3.0-or-later, unmodified).  Structure
//  ported from `Arcade-Badlands_MiSTer/rtl/main/badlands_cpu.sv` (GPL-3.0,
//  same author); the clock phase, the IPL map and the /VPA term are this
//  board's.
//
//  Clock phase.  The SOS-2 outputs both phases of the 7 MHz clock and the
//  board inverts each once:
//
//      SOS-2 pin 12 (/7M) -> 110F F04 -> `7M`   (PAL 110E, PFHS, SOS-1 195N)
//      SOS-2 pin 13 ( 7M) -> 110F F04 -> `/7M`  (68000 CLK, LS163A 230F)
//
//  `7M` is low in the first half of each H count, so `/7M` rises at the
//  H-count boundary.  Here an H count is 8 clk_sys and `ce_7m` is high in its
//  last clk_sys cycle, so:
//
//      enPhi1 = ce_7m           // /7M rising
//      enPhi2 = (pcnt == 4)     // 4 clk_sys later, /7M falling
//
//  The two enables must be exactly 4 clk_sys apart, or /DTACK is sampled at
//  the wrong point relative to the video-RAM slot.  This is the opposite
//  assignment from Bad Lands, whose 68000 clock rises mid-count.
//  `ce_7m_cpu` is output because the LS163A 230F in skullxbo_dtack is clocked
//  by the same /7M edge.
//
//  Pins as sheet 2 wires them:
//    CLK              = /7M
//    HALT, RESET      = tied together to the /RESET net
//    AS               -> 200E LS14 -> `AS` (active high on the board)
//    UDS, LDS         -> 170E LS32 (/WH, /WL)
//    DTACK            = LS27 210F         VPA = F20 240F
//    FC2:0            -> F20 240F (the /VPA NAND)
//    BGACK, BR, BERR  = pulled up: no second bus master, no bus error
//    BG, VMA, E       = unconnected
//    A19-A22          = not connected on this board
//
//  /VPA = NAND(AS, FC0, FC1, FC2).  FC = 7 only during an interrupt
//  acknowledge, so every interrupt is autovectored.
//
//  Differences from a literal transcription:
//  1. HALTn is tied inactive.  fx68k's `extReset` does the whole reset, and
//     its HALTn input is only for single-stepping.
//  2. `pwrUp` is driven from the same `reset`, as fx68k's own top level does.
//  3. BERRn is tied inactive; the board has no bus-error source.
//
//  `reset_inst` is high while a RESET instruction runs.  The program never
//  executes one, so skullxbo_main leaves it unconnected.
//============================================================================

module skullxbo_cpu
(
	input  logic        clk,        // clk_sys, 57.272727 MHz
	input  logic        ce_7m,      // clk_sys/8, the H-count boundary = /7M rising
	input  logic        reset,      // active high: the /RESET net + power-up

	input  logic  [2:0] ipl,        // {/IPL2,/IPL1,/IPL0}, ACTIVE LOW, 111 = none

	output logic [23:1] a,
	output logic [15:0] wdata,
	input  logic [15:0] rdata,
	output logic        as,         // ACTIVE HIGH copy of /AS (200E LS14 5->6)
	output logic        uds_n,
	output logic        lds_n,
	output logic        rw,         // 1 = read, 0 = write
	input  logic        dtack,      // ACTIVE HIGH (= ~/DTACK)
	input  logic        vpa_n,      // F20 240F pin 6 -> pin 21, active low
	output logic  [2:0] fc,
	output logic        reset_inst, // 1 while a RESET instruction runs (see header)

	// the /7M rising tick, for skullxbo_dtack's LS163A 230F
	output logic        ce_7m_cpu
);

	// ------------------------------------------------------- clock phases
	// ce_7m loads pcnt with 1, so in steady state pcnt == 0 IN the ce_7m cycle
	// and runs 1..7 through the rest of the count.
	logic [2:0] pcnt;
	always_ff @(posedge clk) begin
		if (ce_7m) pcnt <= 3'd1;
		else       pcnt <= pcnt + 3'd1;
	end

	wire en_phi1 = ce_7m;            // /7M rising = the H-count boundary
	wire en_phi2 = (pcnt == 3'd4);   // exactly 4 clk_sys later
	assign ce_7m_cpu = en_phi1;

	// ------------------------------------------------------------------ IPL
	// fx68k samples IPL under enPhi2 into its own two-deep synchroniser, so
	// ordinary posedge staging here is correct; the extra latency is invisible
	// at the /7M sampling rate.  Reset value 111 = "no interrupt".
	logic [2:0] ipl_r, ipl_rr;
	always_ff @(posedge clk) begin
		if (reset) begin
			ipl_r  <= 3'b111;
			ipl_rr <= 3'b111;
		end else begin
			ipl_r  <= ipl;
			ipl_rr <= ipl_r;
		end
	end

	// ---------------------------------------------------------------- fx68k
	wire        fx_as_n, fx_reset_n;
	wire [23:1] fx_eab;

	/* verilator lint_off UNUSEDSIGNAL */
	wire        fx_e, fx_vma_n;    // 6800 bus: unconnected
	wire        fx_bg_n;           // pin 11 unconnected, no second master
	wire        fx_halted_n;       // double bus fault; no load
	/* verilator lint_on UNUSEDSIGNAL */

	assign a          = fx_eab;
	assign as         = ~fx_as_n;
	assign reset_inst = ~fx_reset_n;

	fx68k u_fx68k (
		.clk      (clk),
		.HALTn    (1'b1),          // deviation 1
		.extReset (reset),
		.pwrUp    (reset),         // deviation 2
		.enPhi1   (en_phi1),
		.enPhi2   (en_phi2),

		.eRWn     (rw),            // 1 = read, 0 = write
		.ASn      (fx_as_n),
		.LDSn     (lds_n),
		.UDSn     (uds_n),
		.E        (fx_e),
		.VMAn     (fx_vma_n),

		.FC0      (fc[0]),
		.FC1      (fc[1]),
		.FC2      (fc[2]),
		.BGn      (fx_bg_n),
		.oRESETn  (fx_reset_n),
		.oHALTEDn (fx_halted_n),

		.DTACKn   (~dtack),
		.VPAn     (vpa_n),
		.BERRn    (1'b1),          // deviation 3
		.BRn      (1'b1),
		.BGACKn   (1'b1),
		.IPL0n    (ipl_rr[0]),
		.IPL1n    (ipl_rr[1]),
		.IPL2n    (ipl_rr[2]),

		.iEdb     (rdata),
		.oEdb     (wdata),
		.eab      (fx_eab)
	);

endmodule
