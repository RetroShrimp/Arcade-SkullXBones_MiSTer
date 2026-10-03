`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones /DTACK generation (schematic sheet 2): the LS163A wait
//  counter at 230F, the LS11 90E clear gate, the LS74 130C-B /WAITHBL flop,
//  the LS74 110C-B VCYCDONE flop and the LS27 210F that combines the three
//  DTACK sources.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Structure ported from
//  `Arcade-Badlands_MiSTer/rtl/main/badlands_dtack.sv` (GPL-3.0, same
//  author, a 28R LS163A doing the same job); the loads, the three-way DTACK
//  and both flops are this board's.
//
//  The parts, as sheet 2 wires them:
//    LS11 90E    : /VIDRAM, /WAITHBL, AS -> 230F /CLR
//    LS163A 230F : CK = /7M ; ENP = /DTACK ; ENT = /VPA ; /LOAD = QD ;
//                  D,C,B,A = 1, 1, /EEROM, 1 ; RCO -> LS27 210F
//    LS08 200F   : /VPA & VCYCDONE -> LS27 210F
//    LS74 130C-B : D = /WAITHBL, CK = HBLANK, /PRE = AS, /Q -> LS27 210F
//    LS74 110C-B : D = 1, CK = RAMCPU (PAL 110E), /CLR = AS, Q = VCYCDONE
//    LS27 210F   : /DTACK = NOR(RCO, 130C-B /Q, VCYCDONE & /VPA)
//
//  Wait states.  Between bus cycles the counter is held cleared.  On a
//  qualifying cycle the next /7M edge loads {1,1,/EEROM,1}:
//
//    access                                 load   waits
//    ROM, colour RAM, I/O, undecoded         15    0
//    EEPROM (FF6000)                         13    2 (MAME does not model them)
//    video RAM, /MOBWR, /VSCRL              held   until VCYCDONE
//    write to FF0800 (/WAITHBL)             held   until HBLANK rises
//    interrupt acknowledge (/VPA low)       ENT=0  never (ended by /VPA)
//
//  /WAITHBL.  The scanline-interrupt handler's first instruction writes
//  FF0800; this is the only use of the strobe.  The counter is held cleared
//  and the cycle only ends at the next rising edge of the board's HBLANK, so
//  the CPU stalls until horizontal blanking and then writes the scroll
//  registers.  Treating it as a no-op would put those writes mid-line.
//
//  VCYCDONE is cleared while AS is low and set by the first rising edge of
//  RAMCPU inside a bus cycle.  It ends the CPU's slot in PAL 110E and is the
//  only /DTACK source for a video-RAM access: one video-RAM slot per bus
//  cycle.
//
//  The '163 steps on `ce_7m_cpu`, the same tick fx68k uses for enPhi1, so it
//  sees the /AS the CPU presented before that edge, as on the real board.
//============================================================================

module skullxbo_dtack
(
	input  logic clk,          // clk_sys
	input  logic ce_7m_cpu,    // /7M RISING (= ce_7m) -- 230F pin 2

	input  logic as,           // ACTIVE HIGH copy of /AS
	input  logic vidram_n,     // /VIDRAM   -- 90E pin 4
	input  logic waithbl_n,    // /WAITHBL  -- 90E pin 3 and 130C-B D
	input  logic eerom_n,      // /EEROM    -- 230F pin 4 (B)
	input  logic vpa_n,        // /VPA      -- 230F pin 10 (ENT), 200F pin 12
	input  logic ramcpu,       // PAL 110E pin 18 -- 110C-B CK
	input  logic hblank,       // the board's HBLANK -- 130C-B CK

	output logic dtack,        // ACTIVE HIGH (= ~/DTACK), for skullxbo_cpu
	output logic vcycdone,     // 110C-B Q -> PAL 110E pin 9
	output logic waithbl_q_n,  // 130C-B /Q (debug only)
	output logic [3:0] count   // 230F QD..QA (debug only)
);

	// ---------------- LS74 110C-B : VCYCDONE ------------------------------
	// D = +5 V, clocked by the RISING edge of RAMCPU, asynchronously CLEARED
	// while AS is low.  /CLR dominates the clock on a 74LS74.
	logic ramcpu_q;
	always_ff @(posedge clk) ramcpu_q <= ramcpu;
	wire ramcpu_rise = ramcpu & ~ramcpu_q;

	always_ff @(posedge clk) begin
		if (!as)              vcycdone <= 1'b0;   // /CLR = AS, level, dominates
		else if (ramcpu_rise) vcycdone <= 1'b1;
	end

	// ---------------- LS74 130C-B : the /WAITHBL release ------------------
	// /PRE = AS: between bus cycles the flop is PRESET (Q = 1, /Q = 0), so it
	// contributes nothing to /DTACK.  Inside a bus cycle the preset releases and
	// D = /WAITHBL is clocked in on HBLANK's rising edge.
	logic hblank_q;
	always_ff @(posedge clk) hblank_q <= hblank;
	wire hblank_rise = hblank & ~hblank_q;

	logic whb_q;
	always_ff @(posedge clk) begin
		if (!as)              whb_q <= 1'b1;      // /PRE = AS, level, dominates
		else if (hblank_rise) whb_q <= waithbl_n;
	end
	assign waithbl_q_n = ~whb_q;

	// ---------------- LS163A 230F -----------------------------------------
	logic [3:0] q;
	assign count = q;

	// D,C,B,A = PR1, PR1, /EEROM, PR1
	wire [3:0] load_val = {1'b1, 1'b1, eerom_n, 1'b1};

	// LS11 90E pin 6 -> /CLR (SYNCHRONOUS on an LS163A)
	wire clr_n = vidram_n & waithbl_n & as;

	wire ent    = vpa_n;                 // pin 10
	wire rco    = (q == 4'hF) & ent;     // pin 15
	wire load_n = q[3];                  // pin 9 /LOAD = QD (pin 11)

	// LS27 210F: /DTACK = NOR(RCO, 130C-B /Q, 200F pin 11)
	//   200F pin 11 = AND(/VPA, VCYCDONE)
	assign dtack = rco | waithbl_q_n | (vpa_n & vcycdone);

	wire enp = ~dtack;                   // pin 7 = the /DTACK net

	always_ff @(posedge clk) begin
		if (ce_7m_cpu) begin
			if (!clr_n)            q <= 4'd0;        // synchronous /CLR
			else if (!load_n)      q <= load_val;    // synchronous LOAD
			else if (enp & ent)    q <= q + 4'd1;
			// else hold: ENP low (DTACK reached) or ENT low (IACK)
		end
	end

endmodule
