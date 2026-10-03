`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones address decode.
//
//  Schematic sheet 2: LS32 170E, LS139 140A (both halves), LS138 130A,
//  LS139 170J, the LS00 120C MOBMSB latch and the gates that make /ROM,
//  /SLAPSTIK and /VIDRAM; sheet 3: the LS139 220F program-ROM bank select.
//  Transcribed gate for gate.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Structure ported from
//  `Arcade-Badlands_MiSTer/rtl/main/badlands_addr_decode.sv` (GPL-3.0,
//  same author); every equation below is this board's.
//
//  Things to know before changing anything here:
//
//  1. A19-A22 are not connected on the 68000 side, and A22-A16 reach no
//     I/O decode term.  The 0xFFxxxx map is decoded from A23 and A15..A1
//     only, so it mirrors 128 times through 0x800000-0xFFFFFF and the 512 KB
//     ROM repeats through 0x000000-0x7FFFFF.  The program relies on the
//     mirrors (it writes FF406C for /VSCRL, FF4856 for /MOBWR, FF1E01 for
//     /PFUPPER, and reaches the MOBMSB latch at 0xFE8400), so a decode built
//     from address-range compares will not work.
//  2. Every LS138 130A / LS139 170J strobe is write-only (/G2A = /W) and none
//     decodes BA9, so FF1C00 = FF1E00, FF1D00 = FF1F00 and FF1D80 = FF1F80
//     are the same registers.  /CRAM, /EEROM and the four 140A second-half
//     strobes are not qualified by R/W.
//  3. Nothing here looks at /UDS or /LDS: a write to FF1F80 with only /UDS
//     still kicks the watchdog.  Only the video RAM and the EEPROM use the
//     byte lanes, through /WH and /WL from this module.
//  4. The audio read port is at FF5000 (the program uses FF5001), not at the
//     FF4801 shown in the manual's memory map.
//  5. /VIDRAM also fires for /MOBWR and /VSCRL: those accesses move data over
//     the video data bus too, so they also wait for a PAL 110E slot.
//
//  The gates, in sheet order:
//
//    200E LS14 : R/W -> /R ; /R -> /W ; /AS -> AS (active high)
//    170E LS32 : /WH = /UDS + /W        /WL = /LDS + /W
//                n1  = /A23 + BA15      n2  = n1 + /AS  -> 140A-1 /G
//
//    LS139 140A-1 (A = BA13, B = BA14, G = n2)
//        Y0 -> LS138 130A /G2B       FF0000-FF1FFF
//        Y1 = /CRAM                  FF2000-FF3FFF
//        Y2 -> 140A-2 G              FF4000-FF5FFF
//        Y3 = /EEROM                 FF6000-FF7FFF
//
//    LS139 140A-2 (A = BA11, B = BA12)
//        Y0 = /VSCRL   FF4000        Y2 = /AUDRD   FF5000
//        Y1 = /MOBWR   FF4800        Y3 = /INPUTS  FF5800
//
//    LS138 130A (C,B,A = BA12,BA11,BA10 ; G1 = AS ; /G2A = /W ; /G2B = 140A Y0)
//        Y0 MOBMSB clear FF0000   Y4 /VBLACK  FF1000   (IRQ2 ack)
//        Y1 MOBMSB set   FF0400   Y5 /AUDWR   FF1400
//        Y2 /WAITHBL     FF0800   Y6 /AUDRES  FF1800
//        Y3 /UNLOCK      FF0C00   Y7 -> LS139 170J G   FF1C00
//
//    LS139 170J-1 (A = BA7, B = BA8, G = 130A Y7)
//        Y0 /PFUPPER  FF1C00        Y2 /IRQACK  FF1D00   (IRQ1 ack)
//        Y1 /HSCRL    FF1C80        Y3 /WDOG    FF1D80
//      (170J's second half is the MO ROM bank select, in the video block.)
//
//    120C LS00 : /ROM      = NAND(/A23, AS)
//    150E LS10 : /SLAPSTIK = NAND(ROM1, BA16, BA15)
//    150E/180H : /VIDRAM   = NAND(A23, AS, BA15) & /MOBWR & /VSCRL
//
//    LS139 220F-1 (sheet 3; G = /ROM, A = A17, B = A18, unbuffered)
//        /ROM0 0x00000   /ROM1 0x20000   /ROM2 0x40000   /ROM3 0x60000
//      All sockets have /OE grounded and BA16..BA1 on A15..A0, so the word
//      address of the 512 KB image is simply A18..A1.  0x060000-0x06FFFF
//      holds no program: the 185 pair's 32 KB images fill only
//      0x070000-0x07FFFF.
//
//  The SLAPSTIC socket 170C is empty on this board: A14/A13 pass straight
//  through to the 213 ROM pair, and there is no bank remap.  /SLAPSTIK is
//  still output so it can be seen on a waveform; nothing uses it.
//
//  MOBMSB latch (LS00 120C): a set/reset latch.  A write to FF0400 sets it,
//  a write to FF0000 clears it.  It selects which half of the motion-object
//  list the MOB reads (MAME's `(offset >> 9) & 1`).  The board has no reset
//  for it; `init_reset` is an FPGA power-up initialiser only.
//============================================================================

module skullxbo_addr_decode
(
	input  logic        clk,        // clk_sys -- the MOBMSB latch only
	input  logic        init_reset, // FPGA power-up ONLY (the LS00 has no clear)

	// ---- 68000 bus.  Everything but the latch is pure combinatorial glue. ----
	input  logic        as,         // ACTIVE HIGH copy of /AS (200E LS14 5->6)
	input  logic        rw,         // 1 = read, 0 = write
	input  logic        uds_n,
	input  logic        lds_n,
	// Of A22..A16 only A16 (/SLAPSTIK) and A18:A17 (the ROM bank) are used.
	/* verilator lint_off UNUSEDSIGNAL */
	input  logic [23:1] a,
	/* verilator lint_on UNUSEDSIGNAL */

	// ---- 200E LS14 / 170E LS32 ----
	output logic        r_n,        // /R
	output logic        w_n,        // /W
	output logic        wh_n,       // /WH = /UDS + /W
	output logic        wl_n,       // /WL = /LDS + /W

	// ---- LS139 140A first half ----
	output logic        cram_n,     // Y1  FF2000-FF3FFF  R/W word port
	output logic        eerom_n,    // Y3  FF6000-FF7FFF  odd bytes

	// ---- LS139 140A second half (NOT R/W qualified) ----
	output logic        vscrl_n,    // Y0  FF4000-FF47FF  (program: FF406C)
	output logic        mobwr_n,    // Y1  FF4800-FF4FFF  (program: FF4856)
	output logic        audrd_n,    // Y2  FF5000-FF57FF  (program: FF5001)
	output logic        inputs_n,   // Y3  FF5800-FF5FFF

	// ---- LS138 130A (WRITE ONLY; BA9 undecoded) ----
	output logic        mobmsb_clr_n, // Y0  FF0000
	output logic        mobmsb_set_n, // Y1  FF0400
	output logic        waithbl_n,    // Y2  FF0800
	output logic        unlock_n,     // Y3  FF0C00
	output logic        vblack_n,     // Y4  FF1000  IRQ2 ack
	output logic        audwr_n,      // Y5  FF1400
	output logic        audres_n,     // Y6  FF1800
	output logic        y7_n,         // Y7  -> LS139 170J G

	// ---- LS139 170J first half (WRITE ONLY; BA9 undecoded) ----
	output logic        pfupper_n,  // Y0  FF1C00 / FF1E00  (program: FF1E01 byte)
	output logic        hscrl_n,    // Y1  FF1C80 / FF1E80
	output logic        irqack_n,   // Y2  FF1D00 / FF1F00  IRQ1 ack
	output logic        wdog_n,     // Y3  FF1D80 / FF1F80

	// ---- the three big gates ----
	output logic        rom_n,      // /ROM      = NAND(/A23, AS)
	output logic        slapstik_n, // /SLAPSTIK = NAND(ROM1, BA16, BA15) -- socket EMPTY
	output logic        vidram_n,   // /VIDRAM

	// ---- program ROM (sheet 3) ----
	output logic  [3:0] romsel_n,   // /ROM3../ROM0 from LS139 220F (debug only)
	output logic [17:0] rom_a,      // A18..A1 -- the flat 512 KB WORD address

	// ---- LS00 120C ----
	output logic        mobmsb      // the MO-list bank bit -> VRAMA11 mux C3
);

	// ---------------- 200E LS14 -------------------------------------------
	assign r_n = ~rw;      // /R  low during a READ
	assign w_n =  rw;      // /W  low during a WRITE

	// ---------------- 170E LS32 -------------------------------------------
	assign wh_n = uds_n | w_n;
	assign wl_n = lds_n | w_n;

	// ---------------- the LS32 enable chain -------------------------------
	wire a23   = a[23];
	wire a23_n = ~a[23];
	wire ba15  = a[15];

	wire n1 = a23_n | ba15;       // 170E pins 5,4 -> 6
	wire g140a_n = n1 | ~as;      // 170E pins 2,1 -> 3   = 140A-1 /G (pin 15)
	wire g140a = ~g140a_n;        // "the first half is enabled"

	// ---------------- LS139 140A first half (A = BA13, B = BA14) ----------
	wire [1:0] s140a1 = {a[14], a[13]};
	logic [3:0] y140a1_n;
	// Explicit cases rather than `y[sel] = 0`, which iverilog 12 rejects.
	always_comb begin
		y140a1_n = 4'hF;
		if (g140a) case (s140a1)
			2'd0:    y140a1_n[0] = 1'b0;
			2'd1:    y140a1_n[1] = 1'b0;
			2'd2:    y140a1_n[2] = 1'b0;
			default: y140a1_n[3] = 1'b0;
		endcase
	end
	assign cram_n  = y140a1_n[1];   // FF2000-FF3FFF
	assign eerom_n = y140a1_n[3];   // FF6000-FF7FFF

	// ---------------- LS139 140A second half (A = BA11, B = BA12) ---------
	wire [1:0] s140a2 = {a[12], a[11]};
	// Hoisted out of the always_comb to keep iverilog 12 quiet.
	wire g140a2 = ~y140a1_n[2];
	logic [3:0] y140a2_n;
	always_comb begin
		y140a2_n = 4'hF;
		if (g140a2) case (s140a2)
			2'd0:    y140a2_n[0] = 1'b0;
			2'd1:    y140a2_n[1] = 1'b0;
			2'd2:    y140a2_n[2] = 1'b0;
			default: y140a2_n[3] = 1'b0;
		endcase
	end
	assign vscrl_n  = y140a2_n[0];
	assign mobwr_n  = y140a2_n[1];
	assign audrd_n  = y140a2_n[2];
	assign inputs_n = y140a2_n[3];

	// ---------------- LS138 130A (C,B,A = BA12,BA11,BA10) -----------------
	// G1 = AS (HIGH enables), /G2A = /W (so WRITES only), /G2B = 140A-1 Y0.
	wire g130a = as & ~w_n & ~y140a1_n[0];
	wire [2:0] s130a = {a[12], a[11], a[10]};
	logic [7:0] y130a_n;
	always_comb begin
		y130a_n = 8'hFF;
		if (g130a) case (s130a)
			3'd0:    y130a_n[0] = 1'b0;
			3'd1:    y130a_n[1] = 1'b0;
			3'd2:    y130a_n[2] = 1'b0;
			3'd3:    y130a_n[3] = 1'b0;
			3'd4:    y130a_n[4] = 1'b0;
			3'd5:    y130a_n[5] = 1'b0;
			3'd6:    y130a_n[6] = 1'b0;
			default: y130a_n[7] = 1'b0;
		endcase
	end
	assign mobmsb_clr_n = y130a_n[0];
	assign mobmsb_set_n = y130a_n[1];
	assign waithbl_n    = y130a_n[2];
	assign unlock_n     = y130a_n[3];
	assign vblack_n     = y130a_n[4];
	assign audwr_n      = y130a_n[5];
	assign audres_n     = y130a_n[6];
	assign y7_n         = y130a_n[7];

	// ---------------- LS139 170J first half (A = BA7, B = BA8) ------------
	wire [1:0] s170j = {a[8], a[7]};
	logic [3:0] y170j_n;
	always_comb begin
		y170j_n = 4'hF;
		if (!y7_n) case (s170j)
			2'd0:    y170j_n[0] = 1'b0;
			2'd1:    y170j_n[1] = 1'b0;
			2'd2:    y170j_n[2] = 1'b0;
			default: y170j_n[3] = 1'b0;
		endcase
	end
	assign pfupper_n = y170j_n[0];
	assign hscrl_n   = y170j_n[1];
	assign irqack_n  = y170j_n[2];
	assign wdog_n    = y170j_n[3];

	// ---------------- /ROM, /SLAPSTIK, /VIDRAM -----------------------------
	assign rom_n = ~(a23_n & as);                       // 120C LS00

	// LS139 220F first half: G = /ROM, A = A17, B = A18.
	wire [1:0] s220f = {a[18], a[17]};
	logic [3:0] rsel_n;
	always_comb begin
		rsel_n = 4'hF;
		if (!rom_n) case (s220f)
			2'd0:    rsel_n[0] = 1'b0;
			2'd1:    rsel_n[1] = 1'b0;
			2'd2:    rsel_n[2] = 1'b0;
			default: rsel_n[3] = 1'b0;
		endcase
	end
	assign romsel_n = rsel_n;
	assign rom_a    = a[18:1];

	wire rom1 = ~rsel_n[1];                             // 100E LS04 pin 1 -> 2
	assign slapstik_n = ~(rom1 & a[16] & ba15);         // 150E LS10 -- socket EMPTY

	wire vidram_core_n = ~(a23 & as & ba15);            // 150E LS10 13,2,1 -> 12
	assign vidram_n = vidram_core_n & mobwr_n & vscrl_n;// 180H F08

	// ---------------- LS00 120C, the MOBMSB set/reset latch ---------------
	always_ff @(posedge clk) begin
		if (init_reset)          mobmsb <= 1'b0;   // FPGA power-up only
		else if (!mobmsb_set_n)  mobmsb <= 1'b1;   // a write to FF0400-FF07FF
		else if (!mobmsb_clr_n)  mobmsb <= 1'b0;   // a write to FF0000-FF03FF
	end

endmodule
