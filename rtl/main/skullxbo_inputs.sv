`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones controls and status port: the two LS257 muxes 80B/100C
//  (sheet 3) and the F244 150C status nibble (sheet 4).
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Structure ported from
//  `Arcade-Badlands_MiSTer/rtl/main/badlands_inputs.sv` (GPL-3.0, same
//  author); the bit map, the polarity and the status nibble are this board's.
//
//  The LS257s: S = BA1, /OE = /INPUTS.  Every control has a pull-up, so all
//  controls are active low and an unconnected pin reads 1.
//
//    bit    FF5800 (player 1)            FF5802 (player 2)       manual
//    BD15   JAMMA-18 UP 1                JAMMA-V  UP 2           UP
//    BD14   JAMMA-19 DOWN 1              JAMMA-W  DOWN 2         DOWN
//    BD13   JAMMA-20 LEFT 1              JAMMA-X  LEFT 2         LEFT
//    BD12   JAMMA-21 RIGHT 1             JAMMA-Y  RIGHT 2        RIGHT
//    BD11   JAMMA-24 P1 button 3         JAMMA-BB P2 button 3    AUX #1
//    BD10   JAMMA-17 P1 START            JAMMA-U  P2 START       AUX #2
//    BD9    JAMMA-23 P1 button 2         JAMMA-AA P2 button 2    TURN
//    BD8    JAMMA-22 P1 button 1         JAMMA-Z  P2 button 1    SWORD
//
//  AUX #1 and AUX #2 are marked "development only" in the manual (MAME calls
//  them unused); they are wired here as on the board.  The control panel has
//  two SWORD buttons (in parallel) and one TURN button per player; there is
//  no rotary or analog input.
//
//  The F244 150C status nibble (/OE = /INPUTS, non-inverting):
//
//    BD4   HBLANK (board net)       1 during blanking
//    BD5   VBLANK (SOS-2 pin 22)    1 during blanking
//    BD6   /AUDBUSY (SCOM 120E)     active low
//    BD7   SELFTEST (J1-29)         active low
//
//  The enable has no BA1 term, so the nibble appears on every /INPUTS read,
//  at FF5800 as well as FF5802 (MAME shows it only at FF5802).  BD3:0 are not
//  driven: the CPU reads the floating bus there.  The game never reads BD4;
//  it uses the /WAITHBL stall instead.
//
//  SELFTEST is the self-test switch, reaching this board on J1-29.  Turning
//  it on during play resets into the self test, because the VBLANK handler
//  checks it every frame.
//
//  Purely combinational: no clock, no de-bounce, no latch.
//============================================================================

module skullxbo_inputs
(
	// ---- the mux select ----
	input  logic       ba1,        // LS257 pin 1 -- FF5800 (0) vs FF5802 (1)

	// ---- the core's controls, ACTIVE HIGH = "pressed" ----
	input  logic [3:0] p1_joy,     // {up, down, left, right}
	input  logic [3:0] p2_joy,
	input  logic       p1_sword,   // JAMMA button 1
	input  logic       p1_turn,    // JAMMA button 2
	input  logic       p1_btn3,    // JAMMA button 3      ("AUX #1")
	input  logic       p1_start,   // JAMMA CREDIT/START  ("AUX #2")
	input  logic       p2_sword,
	input  logic       p2_turn,
	input  logic       p2_btn3,
	input  logic       p2_start,

	// ---- the status nibble's four sources ----
	input  logic       selftest,   // the JSA SW1, ACTIVE HIGH = "self test ON"
	input  logic       audbusy_n,  // SCOM 120E pin 5, ACTIVE LOW
	input  logic       vblank,     // SOS-2 pin 22, RAW, ACTIVE HIGH
	input  logic       hblank,     // the board's HBLANK, ACTIVE HIGH

	// ---- the two device outputs ----
	output logic [7:0] mux_dout,   // LS257 80B/100C -> BD15:8, ACTIVE LOW
	output logic [3:0] stat_dout   // F244 150C     -> BD7:4
);

	// ---------------- the two LS257s --------------------------------------
	// Assembled ACTIVE LOW: a pressed control pulls its JAMMA pin to ground.
	wire [7:0] pl1 = ~{ p1_joy[3], p1_joy[2], p1_joy[1], p1_joy[0],
	                    p1_btn3,   p1_start,  p1_turn,   p1_sword };
	wire [7:0] pl2 = ~{ p2_joy[3], p2_joy[2], p2_joy[1], p2_joy[0],
	                    p2_btn3,   p2_start,  p2_turn,   p2_sword };

	assign mux_dout = ba1 ? pl2 : pl1;     // S = 0 selects the A (player 1) side

	// ---------------- the F244 150C group 1 -------------------------------
	// SELFTEST is ACTIVE LOW on J1-29, so an ON switch reads 0.
	assign stat_dout = { ~selftest, audbusy_n, vblank, hblank };

endmodule
