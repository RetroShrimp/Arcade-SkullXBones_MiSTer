`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones 68000 program ROM: the eight 27512 sockets of sheet 3,
//  served from SDRAM through a small direct-mapped cache with 4-word lines
//  and a next-line prefetch.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  The cache shape, the two-stage
//  block-RAM pipeline, the read-during-write guard, the invalidate walk and
//  the next-line prefetch are ported from
//  `Arcade-Vindicators_MiSTer/rtl/mem/vind_cpurom_sdram.sv` (GPL-3.0,
//  same author), reduced to one way; the sizing, the DTACK-stall interface
//  and the 0x060000 hole are this core's.
//
//  Why SDRAM: 512 KB would need 512 M10K blocks, nearly the whole device
//  (553), so the program ROM cannot be block RAM.
//
//  Why a cache: a ROM cycle on the board has no wait states, so the 68000
//  latches its word about 20 clk_sys after /AS.  An SDRAM round trip is
//  13-15 clk_sys when idle and longer when the graphics clients are busy, so
//  it does not reliably fit.  A cache hit answers in one clk_sys, like block
//  RAM; a miss raises `stall`, which skullxbo_main uses to hold /DTACK off
//  for ROM reads only.  That adds wait states the board does not have, but
//  keeps the CPU locked to the raster (stretching the CPU clock instead, as
//  Vindicators does, would shift every CPU video-RAM slot).  At the default
//  size the boot checksum and the attract loop run from the cache.
//
//  Structure: direct mapped, LINES sets of 4 words, one 4-word SDRAM burst
//  per fill (a line never crosses an SDRAM row).  Word-address bits
//  [IDX+1:2] are the set index, [17:IDX+2] the tag, [1:0] the word.  The
//  default LINES = 2048 keeps 16 KB resident in 20 M10K blocks.
//
//  Prefetch: while the CPU reads a resident line whose successor is absent,
//  the successor is fetched, so straight-line code never misses.  That needs
//  a second tag lookup in the same cycle, so the tag array is kept as two
//  identical copies (one per set index) rather than relying on Quartus to
//  infer a two-read-port RAM.  Line N+1 is always a different set, so a
//  prefetch never evicts the line being read.
//
//  Block-RAM hazards and how they are handled:
//    1. Read during write: the arrays use M10K "don't care" mode, so the cycle
//       after any tag write is forced to miss (`blk`) for that set.
//    2. Valid bits cannot be cleared in one cycle: `reset` starts a walk that
//       invalidates one set per clk_sys and holds `ready` low until done.
//       `reset` is `init_reset | ~rom_loaded`, so it finishes long before the
//       68000 starts.
//    3. A write-forward ternary on an array read stops Quartus inferring the
//       RAM, so the reads stay plain `q <= mem[raddr]`.
//
//  The 0x060000-0x06FFFF hole: the 185A/185C ROM images are 32 KB each and
//  fill only 0x070000-0x07FFFF.  The download image holds 0xFF there (an
//  unprogrammed EPROM), so no special case is needed; the program never
//  reads it.
//
//  There is no SLAPSTIC (socket 170C is empty): the 512 KB is one flat image
//  addressed by the 68000's A18..A1.
//============================================================================

module skullxbo_prog_rom #(
	parameter int AW = 24,
	// WORD address of the `maincpu` region inside SDRAM (byte 0x000000)
	parameter logic [AW-1:0] PROG_BASE = 24'h000000,
	parameter int PROG_WORDS = 'h40000,     // 512 KB = 256 K words
	parameter int LINES      = 2048         // sets; each is 4 words
)(
	input  logic          clk,
	input  logic          reset,            // init_reset | ~rom_loaded

	// ---- 68000 side ----
	input  logic          rd,               // /ROM asserted on a READ
	input  logic [17:0]   addr,             // the 68000's A18..A1
	output logic [15:0]   data,             // valid 1 clk_sys after addr ON A HIT
	output logic          ready,            // `data` belongs to the current addr
	output logic          stall,            // rd & ~ready: hold /DTACK off

	// ---- skullxbo_gfx_mem read port (highest priority client) ----
	output logic          c_req,
	output logic [AW-1:0] c_addr,
	output logic  [1:0]   c_blen,
	input  logic          c_valid,
	input  logic          c_last,
	input  logic [15:0]   c_rdata
);

	localparam int LINE_WORDS = 4;
	localparam int OFF_BITS   = 2;                        // $clog2(LINE_WORDS)
	localparam int IDX_BITS   = $clog2(LINES);
	localparam int LINE_BITS  = 18 - OFF_BITS;            // 16: the address of a line
	localparam int TAG_BITS   = LINE_BITS - IDX_BITS;
	localparam int TW         = TAG_BITS + 1;             // {valid, tag}
	localparam int DAW        = IDX_BITS + OFF_BITS;      // data-array address
	// The first line past the end of the ROM.  At the default PROG_WORDS the
	// program fills the whole 18-bit word space, so that line number does not
	// fit in LINE_BITS; truncated to 0 it would silently disable the prefetch.
	// With FULL_SPACE the test becomes "the successor did not wrap".
	localparam int LINES_TOTAL = PROG_WORDS / LINE_WORDS;
	localparam bit FULL_SPACE  = (LINES_TOTAL >= (1 << LINE_BITS));

	assign c_blen = 2'(LINE_WORDS - 1);

	// ==== storage ==========================================================
	(* ramstyle = "no_rw_check, M10K" *) logic [15:0]   dmem [0:LINES*LINE_WORDS-1];
	(* ramstyle = "no_rw_check, M10K" *) logic [TW-1:0] tmem_a [0:LINES-1];
	(* ramstyle = "no_rw_check, M10K" *) logic [TW-1:0] tmem_b [0:LINES-1];

	// ==== stage 0: the lookup addresses, straight off `addr` ===============
	wire [IDX_BITS-1:0] cur_idx = addr[IDX_BITS+OFF_BITS-1:OFF_BITS];
	wire [OFF_BITS-1:0] cur_off = addr[OFF_BITS-1:0];
	wire [IDX_BITS-1:0] pf_idx  = cur_idx + 1'b1;

	logic [17:0] addr_r;
	logic        rd_r;
	always_ff @(posedge clk) begin
		addr_r <= addr;
		rd_r   <= rd;
	end

	// ==== stage 1: what the registered arrays are describing ===============
	wire [LINE_BITS-1:0] s_line = addr_r[17:OFF_BITS];
	wire [IDX_BITS-1:0]  s_idx  = s_line[IDX_BITS-1:0];
	wire [TAG_BITS-1:0]  s_tag  = s_line[LINE_BITS-1:IDX_BITS];
	wire [LINE_BITS-1:0] n_line = s_line + 1'b1;
	wire [IDX_BITS-1:0]  n_idx  = n_line[IDX_BITS-1:0];
	wire [TAG_BITS-1:0]  n_tag  = n_line[LINE_BITS-1:IDX_BITS];
	wire                 n_in_rom = FULL_SPACE ? (n_line != '0)
	                                           : (n_line < LINE_BITS'(LINES_TOTAL));

	// ==== the write ports (driven combinationally from the fill engine) ====
	logic                dw_we;
	logic [DAW-1:0]      dw_addr;
	logic                tw_we;
	logic [IDX_BITS-1:0] tw_idx;
	logic [TW-1:0]       tw_data;

	logic [15:0]   d_q;
	logic [TW-1:0] t_cur, t_nxt;

	always_ff @(posedge clk) begin
		if (dw_we) dmem[dw_addr] <= c_rdata;
		d_q <= dmem[{cur_idx, cur_off}];
		if (tw_we) tmem_a[tw_idx] <= tw_data;
		if (tw_we) tmem_b[tw_idx] <= tw_data;
		t_cur <= tmem_a[cur_idx];
		t_nxt <= tmem_b[pf_idx];
	end

	// ---- read-during-write guard (hazard 1) -------------------------------
	logic                tw_en_q;
	logic [IDX_BITS-1:0] tw_idx_q;
	always_ff @(posedge clk) begin
		tw_en_q  <= tw_we;
		tw_idx_q <= tw_idx;
	end
	wire blk = tw_en_q && (tw_idx_q == s_idx);

	// ==== the invalidate walk (hazard 2) ===================================
	// Power-up value = "walk in progress", and any RISING edge of `reset`
	// restarts it, so a fresh ioctl download can never leave a stale line.
	logic                clr_run;
	logic [IDX_BITS-1:0] clr_idx;
	logic                reset_q;
	// Quartus uses the `initial` values as register power-up values.
	// `reset_q = 0` makes the first clock see a rising edge of a `reset` that
	// is already high at power-up, which starts the walk.
	initial begin
		clr_run = 1'b1;
		clr_idx = '0;
		reset_q = 1'b0;
	end
	// plain `always`, not `always_ff`: IEEE 1800 9.2.2.4 forbids a second
	// process writing an always_ff variable, and the `initial` above is one.
	always @(posedge clk) begin
		reset_q <= reset;
		if (reset && !reset_q) begin
			clr_run <= 1'b1;
			clr_idx <= '0;
		end else if (clr_run) begin
			clr_idx <= clr_idx + 1'b1;
			if (clr_idx == IDX_BITS'(LINES-1)) clr_run <= 1'b0;
		end
	end

	// ==== the tag compare ==================================================
	wire hit       = t_cur[TW-1] && (t_cur[TAG_BITS-1:0] == s_tag) && !blk && !clr_run;
	wire n_present = t_nxt[TW-1] && (t_nxt[TAG_BITS-1:0] == n_tag);

	assign data  = d_q;
	assign ready = hit && (addr_r == addr);
	assign stall = rd & ~ready;

	// ==== fill engine ======================================================
	typedef enum logic [1:0] { F_IDLE, F_REQ, F_FILL, F_SETTLE } fstate_t;
	fstate_t st;

	logic [IDX_BITS-1:0] f_idx;
	logic [TAG_BITS-1:0] f_tag;
	logic [OFF_BITS-1:0] f_off;

	// A demand fill is wanted when the address the CPU is STILL holding missed.
	// A prefetch is wanted when it hit and the next line is absent.
	wire miss_now = rd_r && (addr_r == addr) && !hit && !blk && !clr_run;
	wire want_pf  = rd_r && hit && !n_present && n_in_rom && !clr_run;

	wire do_dem = (st == F_IDLE) && miss_now;
	wire do_pf  = (st == F_IDLE) && !miss_now && want_pf;
	wire fill_start = do_dem | do_pf;
	wire fill_done  = (st == F_FILL) && c_valid && c_last;

	wire [LINE_BITS-1:0] start_line = do_dem ? s_line : n_line;
	wire [IDX_BITS-1:0]  start_idx  = do_dem ? s_idx  : n_idx;
	wire [TAG_BITS-1:0]  start_tag  = do_dem ? s_tag  : n_tag;

	always_comb begin
		// data: one word per burst beat
		dw_we   = (st == F_FILL) && c_valid;
		dw_addr = {f_idx, f_off};

		// tags: the walk clears every set; a starting fill invalidates its
		// victim; a completing fill validates it with its new tag.
		tw_we   = 1'b0;
		tw_idx  = clr_idx;
		tw_data = '0;
		if (clr_run) begin
			tw_we   = 1'b1;
			tw_idx  = clr_idx;
			tw_data = '0;                       // valid = 0
		end else if (fill_start) begin
			tw_we   = 1'b1;
			tw_idx  = start_idx;
			tw_data = '0;
		end else if (fill_done) begin
			tw_we   = 1'b1;
			tw_idx  = f_idx;
			tw_data = {1'b1, f_tag};
		end
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= F_IDLE; c_req <= 1'b0; f_off <= '0;
			f_idx <= '0; f_tag <= '0;
		end else begin
			case (st)
				F_IDLE: begin
					f_off <= '0;
					if (fill_start) begin
						c_addr <= PROG_BASE + AW'({start_line, {OFF_BITS{1'b0}}});
						f_idx  <= start_idx;
						f_tag  <= start_tag;
						c_req  <= 1'b1;
						st     <= F_REQ;
					end
				end
				// hold c_req until the burst's last word (the arbiter contract)
				F_REQ: st <= F_FILL;
				F_FILL: begin
					if (c_valid) begin
						f_off <= f_off + 1'b1;
						if (c_last) begin
							c_req <= 1'b0;
							st    <= F_SETTLE;
						end
					end
				end
				// one dead cycle so the tag arrays' read pipeline shows the write
				// that just completed before another fill can be decided on
				F_SETTLE: st <= F_IDLE;
				default: st <= F_IDLE;
			endcase
		end
	end

endmodule
