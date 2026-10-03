`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones SDRAM loader: packs the download byte stream into
//  16-bit words and writes them through the single write port of
//  skullxbo_gfx_mem.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Ported from
//  `Arcade-Badlands_MiSTer/rtl/mem/badlands_sdram_loader.sv` (GPL-3.0,
//  same author; itself from Blasteroids / Xybots / Toobin').
//
//  skullxbo_rom_loader has already computed each byte's SDRAM byte address,
//  so the word address is simply that address >> 1.
//
//  Byte lanes: the even byte address goes to D15:8 and the odd one to D7:0,
//  for the whole SDRAM image (see skullxbo_rom_loader).  Even and odd bytes
//  of a word are consecutive in the stream, so the even byte is latched and
//  the word is written on the odd byte.  `wr_busy` is combinational, high
//  while a word is outstanding (and in the cycle one completes); it must
//  drive `ioctl_wait` so the stream cannot outrun the SDRAM.
//
//  This is a single write path through the gfx_mem controller port, not a
//  separate client behind the read arbiter: Quartus has pruned write clients
//  placed behind the arbiter before.  After any arbiter change, check the
//  map report for "Lost fanout" on the request / we nets.
//============================================================================

module skullxbo_sdram_loader #(
	parameter int AW = 24
)(
	input  logic          clk,
	input  logic          reset,

	// ---- the byte stream from skullxbo_rom_loader (the SDRAM regions only) --
	input  logic          ld_wr,
	input  logic [23:0]   ld_addr,        // SDRAM BYTE address
	input  logic  [7:0]   ld_data,
	output logic          wr_busy,        // -> ioctl_wait (back-pressure)

	// ---- gfx_mem write port ----
	output logic          dl_wr,
	output logic [AW-1:0] dl_waddr,       // SDRAM WORD address
	output logic [15:0]   dl_wdata,
	input  logic          dl_ack
);

	wire any_ev = ld_wr && !ld_addr[0];   // the even (first) byte of a word
	wire any_od = ld_wr &&  ld_addr[0];   // the word-completing (odd) byte

	logic [7:0] hi_buf;                   // the latched even byte -> D15:8

	wire [AW-1:0] word_addr = AW'(ld_addr[23:1]);
	wire [15:0]   word_data = {hi_buf, ld_data};   // even -> D15:8, odd -> D7:0

	typedef enum logic [0:0] { L_IDLE, L_WR } lstate_t;
	lstate_t st;

	// combinational back-pressure: busy while writing, or the cycle a word
	// completes
	assign wr_busy = (st == L_WR) || (st == L_IDLE && any_od);

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= L_IDLE; dl_wr <= 1'b0;
		end else begin
			// The even byte is latched in any state, so a late one can never
			// leave the next odd byte paired with a stale high byte.
			if (any_ev) hi_buf <= ld_data;
			case (st)
				L_IDLE: begin
					dl_wr <= 1'b0;
					if (any_od) begin
						dl_waddr <= word_addr;
						dl_wdata <= word_data;
						dl_wr    <= 1'b1;
						st       <= L_WR;
					end
				end
				L_WR: begin
					if (dl_ack) begin dl_wr <= 1'b0; st <= L_IDLE; end
				end
				default: st <= L_IDLE;
			endcase
		end
	end

	// Simulation-only overrun check, in its own process so no synthesisable
	// always_ff contains a system task.  A word-completing (odd) byte arriving
	// while the previous word is still outstanding cannot be recovered -- it
	// means `ioctl_wait` is not wired to `wr_busy`.
`ifndef ALTERA_RESERVED_QIS
	always @(posedge clk)
		if (!reset && st == L_WR && any_od)
			$display("ERROR: skullxbo_sdram_loader overrun - a word-completing byte arrived while a write was outstanding; ioctl_wait is not wired to wr_busy");
`endif

endmodule
