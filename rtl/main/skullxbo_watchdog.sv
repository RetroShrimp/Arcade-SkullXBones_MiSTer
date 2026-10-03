`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones power-on reset and watchdog (schematic sheet 1): the
//  Q1 / R62 / C55 power-on node into 200E LS14, the LS90 70F divider, the
//  LS00 10D reset gate with jumper JP1, and Q3 driving the /RESET net.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Structure ported from
//  `Arcade-Badlands_MiSTer/rtl/main/badlands_watchdog.sv` (GPL-3.0,
//  same author, a 28A LS197 doing the same job); the part, the set-to-nine
//  power-on behaviour, the edge and the fan-out are this board's.
//
//  Power-on node:
//      +5V - R62 100K -+- C55 0.1uF - GND           (tau = 10 ms)
//                      +- Q1 2N5306 base
//      Q1 emitter -+- R64 240 - GND
//                  +- 200E LS14 -> the POR node
//  The POR node stays high for about 35-40 ms after power-up (`POR_US`).
//
//  The POR node drives the LS90's set-to-nine inputs, not a clear: power-up
//  holds the counter at 9, where QD = 1, so /RESET is asserted from the start.
//
//  LS90 70F, a BCD divide-by-ten:
//      CKA = /VBLANK, QA -> CKB
//      R0 (reset to 0)  = LS00 10D output = NAND(/WDOG, JP1 node)
//      R9 (set to 9)    = the POR node, wins over R0
//      QD -> Q3 -> /RESET
//  JP1 open (as shipped): a /WDOG write resets the count.  JP1 fitted: the
//  counter is held at 0 and the watchdog is defeated.
//
//  The LS90 counts on the falling edge of /VBLANK, i.e. once per frame at the
//  start of vertical blank.  QD is high at counts 8 and 9, so:
//    * a write to FF1F80 / FF1D80 (/WDOG) forces the count to 0;
//    * eight frames with no write reach 8 and assert /RESET;
//    * /RESET then stays asserted for two frames until the count wraps to 0;
//    * at power-up the count is held at 9, and the first VBLANK after the POR
//      node falls wraps it to 0 and releases /RESET.
//  The strobe ignores the data and the byte lanes.
//
//  /RESET drives the 68000's /HALT and /RESET, the EEPROM unlock flop and
//  the EEPROM /OE gate.  It does not reach the SOS-2, the MOB, the PALs, the
//  video latches or the sound board; the sound board is reset only through
//  the SCOM, by a write to FF1800.
//============================================================================

module skullxbo_watchdog #(
	// clk_sys, for turning POR_US into a cycle count
	parameter int CLK_HZ = 57272727,
	// 35-40 ms on the board (see the header)
	parameter int POR_US = 37000
)(
	input  logic       clk,          // clk_sys
	input  logic       ext_reset,    // MiSTer: OSD reset / ioctl_download -- re-runs POR
	input  logic       vblank,       // SOS-2 pin 22, RAW, ACTIVE HIGH
	input  logic       wdog_n,       // LS139 170J Y3, LEVEL, active low
	input  logic       jp1,          // 1 = JP1 fitted = watchdog defeated

	output logic       reset_n,      // the /RESET net, ACTIVE LOW
	output logic       por,          // the POR node, ACTIVE HIGH (debug only)
	output logic [3:0] count         // LS90 QD..QA (debug only)
);

	// ---------------- the POR node ----------------------------------------
	localparam int POR_CYCLES = int'((longint'(POR_US) * CLK_HZ) / 1000000);
	localparam int POR_W      = (POR_CYCLES <= 1) ? 1 : $clog2(POR_CYCLES + 1);

	logic [POR_W-1:0] por_cnt;
	logic             por_done;

	always_ff @(posedge clk) begin
		if (ext_reset) begin
			por_cnt  <= '0;
			por_done <= 1'b0;
		end else if (!por_done) begin
			if (por_cnt >= POR_W'(POR_CYCLES - 1)) por_done <= 1'b1;
			else                                   por_cnt  <= por_cnt + 1'b1;
		end
	end

	assign por = ~por_done;          // HIGH while C55 has not reached V_IH

	// ---------------- LS00 10D + JP1 --------------------------------------
	//   R0 = NAND( /WDOG , JP1node ) with JP1node = ~jp1
	wire jp1_node = ~jp1;
	wire r0       = ~(wdog_n & jp1_node);

	// ---------------- LS90 70F --------------------------------------------
	// R9 (set to nine) dominates R0 on a 74LS90; both are LEVEL sensitive and
	// asynchronous.  CKA = /VBLANK and the part is negative-edge triggered, so
	// it advances on VBLANK's RISING edge.
	logic vblank_q;
	always_ff @(posedge clk) vblank_q <= vblank;
	wire vblank_rise = vblank & ~vblank_q;

	logic [3:0] q;
	always_ff @(posedge clk) begin
		if (por)              q <= 4'd9;                       // R9, dominates
		else if (r0)          q <= 4'd0;                       // R0
		else if (vblank_rise) q <= (q == 4'd9) ? 4'd0 : q + 4'd1;
	end

	assign count   = q;
	assign reset_n = ~q[3];          // QD -> Q3 -> the /RESET net

endmodule
