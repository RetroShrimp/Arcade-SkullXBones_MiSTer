`timescale 1ns/1ps
//============================================================================
//  28C16-45 (2 K x 8) EEPROM at 170A, plus the LS74 30H-A unlock flop and the
//  LS08 60E gate that drives its /OE.  Schematic sheet 3.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Ported from
//  `Arcade-Badlands_MiSTer/rtl/main/badlands_eeprom_2816.sv` (GPL-3.0,
//  same author; itself from Blasteroids / Xybots / Toobin').  Bad Lands'
//  2816A is wired the same way, so the block-RAM notes below carry over.
//
//  Wiring:
//    A10..A0 = BA11..BA1      D7..D0 = BD7:0 (the odd / low byte lane)
//    /CE = /EEROM (0xFF6000-0xFF7FFF)
//    /OE = LS08 60E          /WE = /WL (every low-lane 68000 write)
//
//  The part holds 2 KB at the odd bytes 0xFF6001 ... 0xFF6FFF; BA12 is not
//  decoded, so it mirrors through 0xFF7FFF.  Every game setting lives here:
//  the board has no DIP switches.  (The two extra wait states an EEPROM
//  access takes are generated in skullxbo_dtack.)
//
//  Unlock / lock:
//    LS74 30H-A : D = GND, CK = /WL (rising = end of any low-lane write),
//                 /PRE = /UNLOCK (a write to FF0C00), /CLR = /RESET
//    LS08 60E   : /OE = Q AND /RESET
//
//    after /RESET              Q = 0, /OE = 0   locked: reads work, the part
//                                               ignores /WE
//    after a write to FF0C00   Q = 1, /OE = 1   unlocked: the next write
//                                               programs a byte; reads float
//    at the end of that write  Q = 0, /OE = 0   locked again
//
//  The lock works through /OE, not /WE: /WE always follows /WL.  Because /WL
//  is not address qualified, any low-lane write re-locks the part, so the
//  program masks interrupts around each unlock + write pair.  /PRE is level
//  sensitive, so skullxbo_main holds /UNLOCK across the end of its own cycle
//  to keep that write from re-locking itself.
//
//  Programming time: the part is self-timed (at most 10 ms per byte, pins
//  floating meanwhile).  `WRITE_CYCLES` sets it.
//
//  Erased state.  A factory 28C16 reads 0xFF, but an FPGA RAM powers up at
//  0x00.  So the array erases itself to 0xFF after any init window in which
//  no NVRAM image (or an all-zero one) arrived; the game then writes its own
//  defaults, as a new board does.  `programmed` is marked `preserve`: its
//  data input is the constant 1, and without it Quartus deletes the register
//  and the erase never runs on the device.  One erase pass takes 36 us, far
//  inside the ~50 ms power-on reset.
//
//  Storage.  One write port and two registered read ports (68000 and NVRAM
//  save) is the only shape Quartus maps to Cyclone V block RAM here; it
//  duplicates the array per read port (4 M10K).  An asynchronous read port
//  or a second write port turns into thousands of ALMs.  `cpu_rdata` is valid
//  one clk_sys after `cpu_addr`, well inside the EEPROM wait states.
//============================================================================

module skullxbo_eeprom_28c16 #(
	parameter int CLK_HZ       = 57272727,
	parameter int WRITE_CYCLES = CLK_HZ / 100      // 10 ms, the data-sheet bound
)(
	input  logic        clk,
	input  logic        init_reset,   // FPGA / PLL init and an NVRAM restore
	input  logic        reset,        // the board /RESET net, ACTIVE HIGH

	// /UNLOCK is the 30H flop's /PRE and is level sensitive, so this port takes
	// the level "a write to FF0C00 is in progress", not a pulse.
	input  logic        unlock,       // LEVEL
	input  logic        any_write,    // 1-clk PULSE: /WL RISING -- ANY low-lane write
	input  logic        cpu_we,       // 1-clk pulse: that write had /EEROM asserted
	input  logic [10:0] cpu_addr,     // BA11:1
	input  logic  [7:0] cpu_wdata,    // BD7:0
	output logic  [7:0] cpu_rdata,    // BD7:0
	output logic        busy,
	output logic        oe_n,         // LS08 60E pin 11 -> 170A pin 20
	output logic        unlocked,     // 30H Q
	output logic        write_accepted,

	// MiSTer NVRAM restore / save-back (skullxbo_nvram_io)
	input  logic        load_we,
	input  logic [10:0] load_addr,
	input  logic  [7:0] load_data,
	input  logic [10:0] dump_addr,
	output logic  [7:0] dump_data
);

	localparam int BUSY_W = (WRITE_CYCLES <= 1) ? 1 : $clog2(WRITE_CYCLES + 1);
	logic [BUSY_W-1:0] busy_ctr;
	logic [7:0] mem [0:2047];

	// ---- power-up erase (see the header) --------------------------------
	/* verilator lint_off MULTIDRIVEN */
	/* verilator lint_off PROCASSINIT */
	(* preserve *) logic programmed = 1'b0;
	logic        ld_seen    = 1'b0;
	logic        ld_nonzero = 1'b0;
	logic        por_run    = 1'b0;
	/* verilator lint_on PROCASSINIT */
	/* verilator lint_on MULTIDRIVEN */
	logic [10:0] por_addr;

`ifndef ALTERA_RESERVED_QIS
	// Simulation only, and it models the FPGA rather than the part: an inferred
	// RAM powers up at 0x00, which is NOT a 28C16's erased state.  The erase
	// pass below is what turns it into the factory 0xFF, in simulation exactly
	// as on the device.
	initial for (int i = 0; i < 2048; i++) mem[i] = 8'h00;
`endif

	wire ld_data_nz = load_we & (|load_data);
	wire nx_seen    = ld_seen    | load_we;
	wire nx_nonzero = ld_nonzero | ld_data_nz;
	wire por_we     = por_run & ~load_we;

	always_ff @(posedge clk) begin
		if (ld_data_nz || write_accepted) programmed <= 1'b1;

		if (init_reset) begin
			ld_seen    <= nx_seen;
			ld_nonzero <= nx_nonzero;
			por_run    <= nx_seen ? ~nx_nonzero : ~programmed;
			por_addr   <= 11'd0;
		end else begin
			ld_seen    <= 1'b0;
			ld_nonzero <= 1'b0;
			if (load_we || write_accepted) por_run <= 1'b0;
			else if (por_run) begin
				por_addr <= por_addr + 1'b1;
				if (&por_addr) por_run <= 1'b0;
			end
		end
	end

	assign busy = |busy_ctr;

	// LS08 60E: /OE = Q AND /RESET.  Locked (Q = 0) or in reset -> /OE LOW, so
	// the outputs are on and the part ignores /WE.
	assign oe_n = unlocked & ~reset;

	// A write only programs while the part is UNLOCKED (/OE high) and not
	// already busy.  `write_accepted` samples `unlocked` BEFORE the same /WL
	// edge re-locks it, so the byte the game unlocked for does get stored.
	assign write_accepted = cpu_we & unlocked & ~busy;

	// ---- LS74 30H-A ------------------------------------------------------
	// /CLR = /RESET is asynchronous on the part; /UNLOCK (/PRE) is level
	// sensitive and beats the /WL edge of its own cycle.
	always_ff @(posedge clk) begin
		if (init_reset || reset) unlocked <= 1'b0;
		else if (unlock)         unlocked <= 1'b1;
		else if (any_write)      unlocked <= 1'b0;
	end

	// ---- the write decode ------------------------------------------------
	//   load_we  >  init_reset (no write at all)  >  por_we  >  write_accepted
	wire we_load = load_we;
	wire we_por  = ~load_we & ~init_reset & por_we;
	wire we_cpu  = ~load_we & ~init_reset & ~por_we & write_accepted;

	always_ff @(posedge clk) begin
		if (load_we || init_reset) busy_ctr <= '0;
		else begin
			if (busy)   busy_ctr <= busy_ctr - 1'b1;
			if (we_cpu) busy_ctr <= BUSY_W'(WRITE_CYCLES);
		end
	end

	// ---- the cell array: ONE write port, TWO registered read ports -------
	// It has no reset pin, so programming continues across a board reset.  The
	// loader write is deliberately OUTSIDE the init_reset guard: every restored
	// byte arrives while init_reset is high, and guarding it there throws the
	// whole image away.
	wire        mem_we = we_load | we_por | we_cpu;
	wire [10:0] mem_wa = we_load ? load_addr : we_por ? por_addr : cpu_addr;
	wire  [7:0] mem_wd = we_load ? load_data : we_por ? 8'hFF    : cpu_wdata;

	logic [7:0] cpu_q;

	always_ff @(posedge clk) begin
		if (mem_we) mem[mem_wa] <= mem_wd;
		cpu_q     <= mem[cpu_addr];    // read port 1 -- the 68000 (BD7:0)
		dump_data <= mem[dump_addr];   // read port 2 -- the NVRAM upload
	end

	// The I/O pins float while programming and while /OE is high (unlocked).
	// A floating bus reads 0xFF in this core, as for every undriven lane.  The
	// override is registered with the RAM output so both have the same timing.
	logic float_d;
	always_ff @(posedge clk) float_d <= busy | oe_n;
	assign cpu_rdata = float_d ? 8'hFF : cpu_q;

endmodule
