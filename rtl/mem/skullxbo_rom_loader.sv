`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones ROM download router: splits the MiSTer index-0 ioctl
//  stream into its six regions and sends each to SDRAM or block RAM.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Ported from
//  `Arcade-Badlands_MiSTer/rtl/mem/badlands_rom_loader.sv` (GPL-3.0,
//  same author; itself from Blasteroids / Xybots / Toobin').  The stream map,
//  the regions and the address scatter are this core's.
//
//  The download stream (built by the MRA):
//    stream base   size       MAME region   destination
//    0x000000      0x080000   maincpu       SDRAM 0x000000  (68000 program)
//    0x080000      0x0A0000   playfield     SDRAM 0x080000  (PF stamps, scattered)
//    0x120000      0x190000   sprites       SDRAM 0x120000  (MO stamps, scattered)
//    0x2B0000      0x008000   chars         block RAM: the 250K alpha ROM
//    0x2B8000      0x010000   jsa:cpu       block RAM: the 6502 ROM at 1B
//    0x2C8000      0x040000   jsa:oki1      SDRAM 0x3A0000
//    total         0x308000   (3,178,496 bytes)
//
//  No holes or padding, so the decode is a plain comparison chain.
//  `char_addr` and `snd_addr` count from 0 within their region.
//
//  Graphics scatter.  In MAME's region order the bytes of one hardware
//  graphics fetch are 0x50000 apart (2 playfield columns, or 5 motion-object
//  planes), so each byte would need its own SDRAM row activate, which is too
//  slow.  The loader writes each byte to a computed address that puts a whole
//  fetch in one aligned group, read as one burst from one open row:
//
//    playfield   p    = ioctl_addr - 0x080000
//                is_R = p >= 0x50000                  ("R" column = PFD15:8)
//                q    = p - (is_R ? 0x50000 : 0)
//                     = bank*0x10000 + code*16 + row*2 + half
//                new  = {q[18:1], is_R, q[0]}
//                a 4-byte group per (bank, code, row): P h0, P h1, R h0, R h1
//
//    sprites     s     = ioctl_addr - 0x120000
//                plane = s / 0x50000
//                off   = s - plane*0x50000
//                      = bank*0x10000 + code*16 + row*2 + half
//                new   = {off[18:1], plane[2:0], off[0]}
//                a 16-byte group per (bank, code, row): byte [2p+h] = plane p,
//                half h; bytes 10..15 unused.  One burst of 8 words delivers
//                all ten bytes of a 16-dot stamp slice.
//
//  Bit 0 is unchanged in both formulas, so consecutive even/odd stream bytes
//  still form one 16-bit SDRAM word.  The padding grows the MO region to
//  0x280000 bytes, so the samples sit at 0x3A0000 and the image ends at
//  0x3E0000 (3.9 MB of the 32 MB module).
//
//  There is no EEPROM region: the EEPROM is loaded through index 2 by
//  skullxbo_nvram_io.
//
//  Byte order.  In the MRA's `<interleave output="16">`, map="01" is the
//  first byte of each word (D15:8), so download byte 2N is the 68000 word's
//  high byte and 2N+1 the low byte.  Every SDRAM word uses this packing (even
//  byte address = D15:8), so the program ROM hands SDRAM words to the 68000
//  unchanged and a byte client picks [15:8] for even and [7:0] for odd
//  addresses.  Getting it backwards byte-swaps every opcode with no error.
//
//  Fills already in the stream: maincpu 0x060000-0x06FFFF is 0xFF (no ROM
//  fitted) and sprites 0x170000-0x18FFFF is 0x00 (plane 4 has only three of
//  its five ROMs).  The playfield bytes are stored raw: MAME inverts that
//  region after loading, but on the board the inversion happens in the SOS-1
//  shifter, and this core does the same.
//
//  Back-pressure: the block-RAM regions take a byte per clock.  The SDRAM
//  regions go through skullxbo_sdram_loader, whose `wr_busy` drives
//  `ioctl_wait`; hps_io then holds the current byte, so no handling is needed
//  here.
//
//  Outputs are registered (one clk_sys after ioctl_wr).  `rom_loaded` goes
//  high at the end of an index-0 download only, so an NVRAM restore alone
//  cannot start the CPU.
//============================================================================

module skullxbo_rom_loader
(
	input  logic        clk,
	input  logic        reset,          // ~pll_locked ONLY (never the game reset)

	// ---- HPS ioctl download channel ----
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,     // byte offset into the index-0 stream
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,

	// ---- the four SDRAM regions, as ONE byte stream with its SDRAM address --
	output logic        sdram_wr,
	output logic [23:0] sdram_addr,     // SDRAM BYTE address (scattered, above)

	// ---- chars -> the alphanumerics ROM (250K, 27256) ----
	output logic        char_wr,
	output logic [14:0] char_addr,      // 0..0x7FFF -- the device's own address

	// ---- jsa:cpu -> the 6502 program ROM (1B, 27512) ----
	output logic        snd_wr,
	output logic [15:0] snd_addr,       // 0..0xFFFF -- the 6502's own offset

	// shared byte for every destination (they never strobe in the same cycle)
	output logic  [7:0] rom_data,

	// ---- high once the index-0 download has ended ----
	output logic        rom_loaded
);

	// The download stream map (see the header).
	localparam [26:0] BASE_PROG  = 27'h000000;
	localparam [26:0] BASE_PF    = 27'h080000;
	localparam [26:0] BASE_SPR   = 27'h120000;
	localparam [26:0] BASE_CHAR  = 27'h2B0000;
	localparam [26:0] BASE_SND   = 27'h2B8000;
	localparam [26:0] BASE_OKI   = 27'h2C8000;
	localparam [26:0] END_STREAM = 27'h308000;

	// SDRAM base of each region.
	localparam [23:0] SD_PROG = 24'h000000;   // 0x080000 bytes, linear
	localparam [23:0] SD_PF   = 24'h080000;   // 0x0A0000 bytes, 4-byte groups
	localparam [23:0] SD_MO   = 24'h120000;   // 0x280000 bytes, 16-byte groups
	localparam [23:0] SD_OKI  = 24'h3A0000;   // 0x040000 bytes, linear
	localparam [26:0] PLANE   = 27'h050000;   // the raw per-plane / per-column stride

	wire is_idx0 = (ioctl_index == 16'd0);
	wire wr      = ioctl_download & ioctl_wr & is_idx0;

	wire in_prog = wr && (ioctl_addr <  BASE_PF);
	wire in_pf   = wr && (ioctl_addr >= BASE_PF)   && (ioctl_addr < BASE_SPR);
	wire in_spr  = wr && (ioctl_addr >= BASE_SPR)  && (ioctl_addr < BASE_CHAR);
	wire in_char = wr && (ioctl_addr >= BASE_CHAR) && (ioctl_addr < BASE_SND);
	wire in_snd  = wr && (ioctl_addr >= BASE_SND)  && (ioctl_addr < BASE_OKI);
	wire in_oki  = wr && (ioctl_addr >= BASE_OKI)  && (ioctl_addr < END_STREAM);

	// ---- playfield: is_R picks the column, q is the device byte offset ------
	wire [26:0] pf_p    = ioctl_addr - BASE_PF;          // 0 .. 0x9FFFF
	wire        pf_is_r = (pf_p >= PLANE);
	wire [26:0] pf_q    = pf_is_r ? (pf_p - PLANE) : pf_p;
	wire [19:0] pf_new  = {pf_q[18:1], pf_is_r, pf_q[0]};

	// ---- sprites: plane = s / 0x50000, off = s mod 0x50000 -----------------
	// 0x50000 = 5 * 0x10000, so the quotient is decided by the five compares on
	// the top five bits and the remainder is one 0x10000-granular subtraction.
	wire [26:0] mo_s    = ioctl_addr - BASE_SPR;         // 0 .. 0x18FFFF
	wire  [4:0] mo_q64  = mo_s[20:16];                   // 0 .. 24
	wire  [2:0] mo_pl   = (mo_q64 < 5'd5)  ? 3'd0 :
	                      (mo_q64 < 5'd10) ? 3'd1 :
	                      (mo_q64 < 5'd15) ? 3'd2 :
	                      (mo_q64 < 5'd20) ? 3'd3 : 3'd4;
	wire  [4:0] mo_pl5  = {2'b00, mo_pl} + {mo_pl, 2'b00};        // 5 * plane
	wire  [2:0] mo_ohi  = 3'(mo_q64 - mo_pl5);                    // 0 .. 4
	wire [18:0] mo_off  = {mo_ohi, mo_s[15:0]};
	wire [21:0] mo_new  = {mo_off[18:1], mo_pl, mo_off[0]};

	// 24 bits, not 27: the SDRAM image ends at byte 0x3DFFFF.
	wire [23:0] sdram_byte =
		  in_pf  ? (SD_PF  + 24'(pf_new))
		: in_spr ? (SD_MO  + 24'(mo_new))
		: in_oki ? (SD_OKI + 24'(ioctl_addr - BASE_OKI))
		:          (SD_PROG + 24'(ioctl_addr));

	logic [7:0] data_r;

	always_ff @(posedge clk) begin
		data_r     <= ioctl_dout;
		sdram_wr   <= (in_prog | in_pf | in_spr | in_oki) & ~reset;
		char_wr    <= in_char & ~reset;
		snd_wr     <= in_snd  & ~reset;
		sdram_addr <= sdram_byte;
		char_addr  <= 15'(ioctl_addr - BASE_CHAR);
		snd_addr   <= 16'(ioctl_addr - BASE_SND);
	end

	assign rom_data = data_r;

	// rom_loaded latches on the falling edge of the index-0 download.  `reset`
	// (~pll_locked) gives it a defined power-up value.
	wire  dl0 = ioctl_download & is_idx0;
	logic dl0_d;
	always_ff @(posedge clk) begin
		if (reset) begin
			dl0_d      <= 1'b0;
			rom_loaded <= 1'b0;
		end else begin
			dl0_d <= dl0;
			if (dl0)        rom_loaded <= 1'b0;   // a download is in progress
			else if (dl0_d) rom_loaded <= 1'b1;   // the first cycle after it ends
		end
	end

	/* verilator lint_off UNUSEDSIGNAL */
	// BASE_PROG is 0 and kept only to document the map.  The high bits of the
	// two scatter intermediates are always zero.
	wire _unused = &{1'b0, BASE_PROG[0], pf_q[26:19], mo_s[26:21], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
