`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones graphics-ROM fetch adapter: one hardware stamp fetch
//  is one SDRAM transaction, and its bytes are taken from the group the
//  arbiter returns.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  This is the only video file that knows the SDRAM fetch protocol.  The
//  playfield (skullxbo_pf) and the motion objects (skullxbo_mo_fetch) ask for
//  "the stamp bytes at this address" and wait for `data_valid`.
//
//  Why the fetch is wide: on the board every ROM of a plane group is
//  addressed identically and read at once.
//    * the playfield's "R" column (PFD15:8) and "P" column (PFD7:0) share
//      A15:0, so one fetch is a 16-bit word;
//    * the motion object's five planes share MOROMA17:0 and MOHALF, so one
//      fetch is 40 bits, and a 16-dot slice is two of those, 80 bits.
//
//  The arbiter port (skullxbo_gfx_mem) is byte-wide: `req` is a level held
//  with `addr` until `ack`, a one-clk pulse.  Alongside the byte it returns
//  `group`, the whole aligned group (row buffer) the byte came from.
//  skullxbo_rom_loader lays the graphics out so one hardware fetch lies in
//  one group:
//
//      playfield  GROUP = 4 bytes: [0] P h0  [1] P h1  [2] R h0  [3] R h1
//                 fetch_addr = the "P" byte, BEATS = 2, STRIDE = 2
//                 -> lane 0 = PFD7:0 ("P"), lane 1 = PFD15:8 ("R")
//
//      sprites    GROUP = 16 bytes, one stamp slice:
//                 [2p + h] = plane p (p = 0..4) of MOHALF h
//                 fetch_addr = the group base, BEATS = 10, STRIDE = 1
//                 -> lane k = plane k>>1, MOHALF k&1: one fetch is the whole
//                    16-dot slice, both halves.
//
//  Budget:
//      PF  one 16-bit word per four playfield pixels = 4 H counts = 32 clk_sys
//      MO  one 16-dot slice per eight H counts = 63 clk_sys
//          (issued at `stb_d`, used at the next `slice_stb`)
//
//  A fetch takes the arbiter's latency + 2 clk_sys, whatever BEATS is.
//  `late` fires if a fetch is requested while one is still outstanding;
//  skullxbo_video ORs the two into `gfx_late`, which should never be set.
//============================================================================

module skullxbo_gfx_client #(
	parameter int AW     = 22,         // the arbiter's byte-address width
	parameter int GROUP  = 16,         // the arbiter's group size, in BYTES
	parameter int BEATS  = 2,          // bytes this fetch takes from the group
	parameter int STRIDE = 2           // the step between them INSIDE the group
)(
	input  logic          clk,
	input  logic          reset,

	// ---- video side -------------------------------------------------------
	input  logic          fetch,        // one clk pulse: start a fetch
	input  logic [AW-1:0] fetch_addr,   // the BYTE address of lane 0
	output logic [8*BEATS-1:0] data,    // the assembled plane group, HELD
	output logic          data_valid,   // a whole group has arrived
	output logic          late,         // a fetch arrived with one outstanding

	// ---- memory side (skullxbo_gfx_mem) ----------------------------------
	output logic          req,          // LEVEL, HELD with the address
	output logic [AW-1:0] addr,         // BYTE offset inside this region
	output logic [3:0]    blen,         // the fetch width in bytes, = BEATS
	input  logic          ack,          // ONE-clk pulse; group valid in it
	input  logic [8*GROUP-1:0] group    // the whole aligned group
);

	localparam int GB = $clog2(GROUP);   // the byte index inside the group

	logic [8*BEATS-1:0] data_r;
	logic               busy;
	logic [GB-1:0]      base;

	assign data = data_r;
	assign blen = BEATS[3:0];

	// Lane k is the group byte `base + k*STRIDE`.  The scatter guarantees that
	// every lane of a fetch lies inside the same group; the modulo is only a
	// safety net.
	logic [8*BEATS-1:0] pick;
	always_comb begin
		pick = '0;
		for (int k = 0; k < BEATS; k++)
			pick[8*k +: 8] = group[8*((int'(base) + k*STRIDE) % GROUP) +: 8];
	end

	always_ff @(posedge clk) begin
		late <= 1'b0;
		if (reset) begin
			req        <= 1'b0;
			addr       <= '0;
			base       <= '0;
			busy       <= 1'b0;
			data_r     <= '0;
			data_valid <= 1'b0;
		end else begin
			// A fetch while one is outstanding would lose the group in flight.
			// The transaction in flight is left alone (the address may not
			// change mid-transaction) and the new fetch is dropped; `late`
			// reports it.
			if (fetch) begin
				data_valid <= 1'b0;
				if (busy) late <= 1'b1;
			end

			if (busy) begin
				if (req && ack) begin
					req        <= 1'b0;
					busy       <= 1'b0;
					data_valid <= 1'b1;
					data_r     <= pick;
				end
			end else if (fetch) begin
				busy <= 1'b1;
				addr <= fetch_addr;
				base <= fetch_addr[GB-1:0];
				req  <= 1'b1;
			end
		end
	end

endmodule
