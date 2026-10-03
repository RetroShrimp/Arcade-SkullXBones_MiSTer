`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones colour RAM 40E / 50E, the /CRAMD pixel steal and the
//  HC273 40B/40C output registers (schematic sheet 10).
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  The RAM: two 137534-001 2 K x 8 parts = 2048 x 16 at FF2000-FF2FFE, a
//  16-bit word port for the CPU (LS245 50B/50C), /CS = /OE = GND,
//  /WE = /CRWR.  The video side addresses it with CRAMA10:1 from the F153
//  muxes plus PAL 10F pin 14 as A10.  The physical A10 is the complement of
//  MAME's, but the CPU side is inverted by the same PAL output, so this
//  module simply stores the software-visible map (bit for bit MAME's FF2000
//  image); skullxbo_prio outputs that A10 as `shadow`.
//
//  The pixel steal: LS74 70C makes /CRAMD a one-14MA-cycle low pulse per CPU
//  colour-RAM access; F398 40J delays it one 14MB into /CRAMOO; and
//  VIDCLK = OR(CRAMOO, /14MA) is held high for that cycle, freezing the
//  HC273 outputs.  The CPU steals exactly one pixel.  MAME does not model
//  this.  /CRWR = OR(/CRAMOO, /W, /14MA) is the write pulse inside the
//  stolen cycle.
//
//  Pipeline:
//      F174 50F/40F  register all eleven address bits on /14MA rising   1 dot
//      colour RAM -> HC273 40B/40C on VIDCLK                           1 dot
//  so the colour-RAM address reaches the DAC two dots later.
//
//  /BLANK = AND(/VBLANK, /HBLANK) is the HC273s' asynchronous /MR: during
//  blanking all colour bits go to 0 and the DAC outputs blanking level.
//============================================================================

module skullxbo_cram (
	input  logic        clk,
	input  logic        reset,
	input  logic        ce_14m,

	// ---- the video address path -----------------------------------------
	input  logic [9:0]  cram_a,      // CRAMA10:1 from the F153 muxes
	input  logic        shadow,      // the software-visible A10
	input  logic        blank_n,     // /BLANK -> HC273 /MR

	// ---- the CPU port (FF2000-FF2FFE, 16 bits in one cycle) -------------
	input  logic        cram_cs,     // /CRAM asserted for this bus cycle
	input  logic        cram_we,
	input  logic [10:0] cram_cpu_a,  // the SOFTWARE index (BA11:1)
	input  logic [15:0] cram_din,
	output logic [15:0] cram_dout,

	// ---- preload port (tied off in the core) ----------------------------
	input  logic        init_wr,
	input  logic [10:0] init_a,
	input  logic [15:0] init_d,

	// ---- outputs ---------------------------------------------------------
	output logic [15:0] colour,      // the HC273 word: {RGB0, R5:1, G5:1, B5:1}
	output logic [10:0] pix_index,   // the software palette index (debug)
	output logic        cramd_n      // /CRAMD, back into PAL 10F pin 1
);

	logic [15:0] cram [0:2047];

	// ---------------------------------------------------------------------
	// /CRAMD — one 14MA cycle per CPU colour-RAM access
	// ---------------------------------------------------------------------
	// `cram_cs` is a 68000-side strobe on clk_sys and its rising edge lands on
	// any of the four clk_sys cycles of a `14MA` period, so the edge has to be
	// held until the next `ce_14m`; comparing it directly against `ce_14m`
	// would drop three requests in four.
	logic cramd_r, cram_cs_d, cs_pend;
	always_ff @(posedge clk) begin
		if (reset) begin
			cramd_r   <= 1'b0;
			cram_cs_d <= 1'b0;
			cs_pend   <= 1'b0;
		end else begin
			cram_cs_d <= cram_cs;
			if (ce_14m) begin
				cramd_r <= cs_pend | (cram_cs & ~cram_cs_d);
				cs_pend <= 1'b0;
			end else if (cram_cs & ~cram_cs_d) begin
				cs_pend <= 1'b1;
			end
		end
	end
	assign cramd_n = ~cramd_r;

	// ---------------------------------------------------------------------
	// F174 50F / 40F — the address pipeline stage
	// ---------------------------------------------------------------------
	wire [10:0] vidx = {shadow, cram_a};
	logic [10:0] idx_r;
	logic        steal_r;

	always_ff @(posedge clk) begin
		if (reset) begin
			idx_r   <= 11'd0;
			steal_r <= 1'b0;
		end else if (ce_14m) begin
			idx_r   <= cramd_r ? {cram_cpu_a} : vidx;
			steal_r <= cramd_r;
		end
	end
	// `pix_index` is exported from the SECOND stage so that it is aligned with
	// `colour` (and hence with the `de` the video top pipelines alongside it).
	always_ff @(posedge clk) begin
		if (reset)       pix_index <= 11'd0;
		else if (ce_14m) pix_index <= idx_r;
	end

	// ---------------------------------------------------------------------
	// The RAM and the HC273 output registers
	// ---------------------------------------------------------------------
	logic [15:0] rq;

	always_ff @(posedge clk) begin
		if (init_wr)                       cram[init_a]    <= init_d;
		// Qualified by `steal_r`, not `cramd_r`.  On the board /CRWR is built
		// from /CRAMOO, which is /CRAMD delayed one 14MB: the cycle in which
		// the F153 mux has put the CPU index on `idx_r` and VIDCLK is held
		// high.  `steal_r` is that cycle.  skullxbo_main builds `cram_we` the
		// same way (`ce_14m & ~cramoo_n & ~rw`), a one-clk pulse after
		// `cramd_r` has already fallen.
		else if (steal_r && cram_we)       cram[cram_cpu_a] <= cram_din;
		rq <= cram[idx_r];
	end

	// ---------------------------------------------------------------------
	// The CPU read port: valid one clk_sys after the stolen cycle, and held
	// ---------------------------------------------------------------------
	// The CPU's address reaches the array only in the stolen cycle, so `rq`
	// carries the CPU's word for that one 14MA cycle and then returns to the
	// video stream.  The 68000 has no wait state from the colour RAM and
	// latches the data at the end of its bus cycle (~20 clk_sys after /AS),
	// so the word is held here until then.
	logic steal_q;
	always_ff @(posedge clk) begin
		steal_q <= steal_r;
		if (steal_q) cram_dout <= rq;
	end

	// VIDCLK is held HIGH through the stolen cycle, so the HC273 keeps the
	// previous pixel; /BLANK clears it asynchronously.
	always_ff @(posedge clk) begin
		if (reset)         colour <= 16'd0;
		else if (!blank_n) colour <= 16'd0;
		else if (ce_14m && !steal_r) colour <= rq;
	end

endmodule
