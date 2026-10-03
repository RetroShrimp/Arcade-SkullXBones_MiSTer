`timescale 1ns/1ps
//============================================================================
//  MiSTer NVRAM load / save controller for the Skull & Crossbones 28C16
//  EEPROM at 170A.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Ported from
//  `Arcade-Badlands_MiSTer/rtl/main/badlands_nvram_io.sv` (GPL-3.0,
//  same author; itself from Blasteroids / Xybots / Toobin'), adapted to this
//  core's 2 KB part.
//
//  The EEPROM is loaded and saved only on `ioctl_index == 2`, the MRA's
//  `<nvram index="2" size="2048"/>` channel.  The ROM download (index 0) is
//  ignored here: its low addresses are the 68000 program and would overwrite
//  the settings.
//
//  The board has no DIP switches: coinage, difficulty, health options and
//  the high-score table all live in this EEPROM and are set from the game's
//  self test.
//
//  Save request: a programmed byte sets `dirty`; after SETTLE_CYCLES without
//  another write, one upload is requested, so a burst of option writes turns
//  into a single save.  `dirty` survives a board or watchdog reset, as the
//  EEPROM contents do; only FPGA initialisation or an NVRAM load clears it.
//  If a write coincides with an upload start, the write wins and is saved
//  again later.
//============================================================================

module skullxbo_nvram_io #(
	// ~1.17 s at 57.272727 MHz: long enough that a burst of option writes from
	// one self-test page produces a single upload.
	parameter int unsigned SETTLE_CYCLES = 67_108_863
)(
	input  logic        clk,
	input  logic        init_reset,

	input  logic        write_accepted,   // from skullxbo_eeprom_28c16

	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_upload,

	output logic        load_we,
	output logic [10:0] load_addr,
	output logic  [7:0] load_data,
	output logic [10:0] dump_addr,
	input  logic  [7:0] dump_data,

	output logic        ioctl_upload_req,
	output logic  [7:0] ioctl_upload_index,
	output logic  [7:0] ioctl_din
);

	// Index 2 only (see the header).  The 2 KB part takes ioctl_addr[10:0]; a
	// longer file simply wraps.
	wire index2_nvram = (ioctl_index == 16'd2);

	assign load_we   = ioctl_download & ioctl_wr & index2_nvram;
	assign load_addr = ioctl_addr[10:0];
	assign load_data = ioctl_dout;
	assign dump_addr = ioctl_addr[10:0];

	localparam int SETTLE_W = (SETTLE_CYCLES <= 1) ? 1 : $clog2(SETTLE_CYCLES + 1);
	logic [SETTLE_W-1:0] settle;
	logic dirty;
	wire  settled      = (settle == SETTLE_W'(SETTLE_CYCLES));
	wire  upload_start = ioctl_upload & index2_nvram;

	always_ff @(posedge clk) begin
		if (init_reset) begin
			dirty  <= 1'b0;
			settle <= '0;
		end else if (write_accepted) begin
			dirty  <= 1'b1;      // a new byte cannot be cleaned by a concurrent upload
			settle <= '0;
		end else if (load_we || upload_start) begin
			dirty  <= 1'b0;
			settle <= '0;
		end else if (dirty && !settled) begin
			settle <= settle + 1'b1;
		end
	end

	assign ioctl_upload_req   = dirty & settled;
	assign ioctl_upload_index = 8'd2;
	assign ioctl_din          = dump_data;

	/* verilator lint_off UNUSEDSIGNAL */
	// ioctl_addr[26:11] selects nothing: the part is 2 KB and the index-2 file
	// is 2 KB.
	wire _unused_hi = &{1'b0, ioctl_addr[26:11]};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
