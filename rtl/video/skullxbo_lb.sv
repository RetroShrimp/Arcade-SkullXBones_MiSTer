`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones motion-object line buffers (schematic sheet 9:
//  80J/70J and 80K/70K, the F163 counters 90J/100J/110J and 90K/100K/110K,
//  the LS244/LS125 write drivers, F398 50J/40J + F174 60J).
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  Structure: two banks, each a pair of 2 K x 8 SRAMs.  80J/80K hold
//  MOPIX4:0 and 70J/70K hold {MOTL, MOPAL3:0, MOPRI1:0, MOMISC}.  A10 of all
//  four is grounded, so only the lower 1 K of each is used: 2 banks x 1024 x
//  13 bits.  The address is a ten-bit F163 chain clocked by 14MB, with a
//  synchronous clear (/RSTLBn) and a synchronous load from MHPOS9:0
//  (/LDLBn).
//
//  Which bank is written:
//      /LDLB0 = OR(/1VMOB, /LOADLB)      /LDLB1 = OR(/LOADLB, 1VMOB)
//      /RSTLB0 = NAND(RSTLB, /1V)        /RSTLB1 = NAND(RSTLB, 1V)
//
//  LOADLB (the write side) selects by 1VMOB and RSTLB (which restarts the
//  read pointer at the left edge) selects by 1V.  They are opposite because
//  /1VOD carries 1V, not /1V: 20N is non-inverting so its Q3 is /1V, and 25L
//  is inverting so its Q2 (the net /1VOD) is 1V; 1VMOB follows it.  Hence
//  bank 0 is written while 1V = 1 and read while 1V = 0, and vice versa: the
//  bank written during line L is read during line L+1, and the MOB builds
//  line N+1 during line N.  (MAME has no line buffers; this one-line delay is
//  real hardware behaviour.)
//
//  Transparency and erasing.  The write enable is gated so pen 0, the
//  transparent pen, is never written (see skullxbo_mo_fetch for the
//  polarity).  Nothing on the schematic erases the buffer: there is no clear
//  cycle and no second write port.  So either the MOB writes a full-width
//  background pass, or stale pixels from two lines earlier would survive.
//  MAME clears its motion-object bitmap every frame, which matches the first
//  reading, so `LB_ERASE = 1` (the default) starts every write pass from an
//  empty buffer.
//
//  How the erase works: the location one dot behind the read pointer is
//  zeroed as the read pass walks it.  The read pass of bank B during line N
//  clears 0..911 of bank B, and bank B is the write bank during line N+1, so
//  every write pass starts empty.  The clear address is `rcnt` and the read
//  address `rcnt + LB_RD_ADJ`, so they never collide and each memory stays a
//  plain simple-dual-port RAM.  (A one-bit per-location "generation" tag is
//  not equivalent: it leaves a ghost every four lines.)  `LB_ERASE = 0` is
//  the literal no-erase reading.
//============================================================================

module skullxbo_lb #(
	parameter bit LB_ERASE  = 1'b1,
	parameter int LB_RD_ADJ = 1      // read-pointer alignment, in dots
)(
	input  logic        clk,
	input  logic        reset,
	input  logic        ce_14m,      // 14MB — one dot

	// ---- bank control ----------------------------------------------------
	input  logic        wbank,       // 1VMOB: which bank the MOB is writing
	input  logic        line_tick,   // one clk at the LINKRES/SLIP point
	input  logic        rstlb,       // the F163 synchronous clear (read side)

	// ---- the write side --------------------------------------------------
	input  logic        loadlb,      // /LOADLB: load MHPOS into the counter
	input  logic [9:0]  wpos,
	input  logic [4:0]  pen,         // MOPIX4:0, the TRUE pen
	input  logic [7:0]  attr,        // {MOTL, MOPAL3:0, MOPRI1:0, MOMISC}
	input  logic        live,        // /GS & /LBnEN: this slice is real

	// ---- the read side (F398 50J/40J + F174 60J, one 14MB stage) --------
	output logic [4:0]  lbpix,
	output logic [3:0]  lbpal,
	output logic [1:0]  lbpri,
	output logic        lbtl,
	output logic        lbmisc,

	// ---- debug outputs --------------------------------------------------
	output logic [9:0]  wcnt,
	output logic [9:0]  rcnt
);

	localparam int DW = 13;           // {attr[7:0], pen[4:0]}

	logic [DW-1:0] mem0 [0:1023];
	logic [DW-1:0] mem1 [0:1023];
	logic [DW-1:0] q0, q1;

	wire rbank = ~wbank;

	// ---------------------------------------------------------------------
	// The F163 counters
	// ---------------------------------------------------------------------
	always_ff @(posedge clk) begin
		if (reset) begin
			wcnt <= 10'd0;
			rcnt <= 10'd0;
		end else if (ce_14m) begin
			wcnt <= loadlb ? wpos : (wcnt + 10'd1);
			rcnt <= rstlb  ? 10'd0 : (rcnt + 10'd1);
		end
	end

	// ---------------------------------------------------------------------
	// The memories — one write port each, shared between the MOB's write (when
	// this bank is the WRITE bank) and the erase sweep (when it is the READ
	// bank).  The two are mutually exclusive by construction.
	// ---------------------------------------------------------------------
	// The write is suppressed on the transparent pen (the /LBWRn gate) and when
	// the slice is not live (/GS).
	wire          we    = ce_14m & live & (pen != 5'd0);
	wire [DW-1:0] wdata = {attr, pen};
	// On the RSTLB tick the read side presents the address the restarted
	// counter continues from (LB_RD_ADJ - 1), not rcnt + LB_RD_ADJ = 912: the
	// erase sweep never reaches 912..1023, so reading 912 there would show
	// whatever an object once wrote at that address, at screen x = 0.
	wire [9:0]    radr  = rstlb ? (LB_RD_ADJ[9:0] - 10'd1)
	                            : (rcnt + LB_RD_ADJ[9:0]);

	// The erase sweep walks one dot BEHIND the read address, so a location is
	// zeroed only after the read pass has already presented it.
	wire          ers   = ce_14m & (LB_ERASE != 0);

	always_ff @(posedge clk) begin
		if (ce_14m)             q0 <= mem0[radr];
		if (we && !wbank)       mem0[wcnt] <= wdata;
		else if (ers && rbank == 1'b0) mem0[rcnt] <= '0;
	end
	always_ff @(posedge clk) begin
		if (ce_14m)             q1 <= mem1[radr];
		if (we &&  wbank)       mem1[wcnt] <= wdata;
		else if (ers && rbank == 1'b1) mem1[rcnt] <= '0;
	end

	wire [DW-1:0] q = rbank ? q1 : q0;

	assign lbpix  = q[4:0];
	assign lbmisc = q[5];
	assign lbpri  = q[7:6];
	assign lbpal  = q[11:8];
	assign lbtl   = q[12];

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, line_tick, 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
