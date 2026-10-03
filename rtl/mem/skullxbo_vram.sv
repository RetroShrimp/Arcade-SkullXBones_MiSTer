`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones video RAM: the two 16-bit memories (208H/235H and
//  221H/250H), the seven F253/LS253 address multiplexers, the F174 address
//  latches, PAL16R8 110E (136072-2143, implemented directly from its fuse
//  dump), the byte-lane write pulses with the /PFUPPER two-pulse colour
//  write, the LS373 170K/140C CPU read latches and the F373 200K
//  motion-object link register.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  The single-array + clock-enable
//  idiom follows `Arcade-Badlands_MiSTer/rtl/mem/badlands_vram.sv`
//  (GPL-3.0, same author); everything else is this board's (Bad Lands has one
//  8 K x 8 RAM on a four-slot schedule, this board two 8 K x 16 RAMs on a
//  PAL-sequenced sixteen-slot schedule).
//
//  1. Phase.  Each H count is two 14MA cycles, (H,a) then (H,b), and the
//  board's `7M` is low in (H,a) and high in (H,b).  This decides which
//  playfield word is fetched first and where the alphanumerics slot sits.
//  `pix` is that `7M` net.
//
//  The PAL and the F174 address latch are both clocked by 14MA.  `ce_14m` is
//  high in the last clk_sys cycle before a 14MA rising edge, so the values
//  seen in that cycle (`h`, `pix`, /VIDRAM, VCYCDONE) are the ones a real
//  PAL16R8 samples at that edge.  This puts SLIPUP in (443,a) and /SLIP in
//  (442,b).
//
//  2. Slot schedule, per 8 H counts (16 14MA cycles), with h = H mod 8:
//
//    (h2,b)  PLAYFIELD  0xFFA000 + ...   the tile colour word (VRAMA13 = 7M = 1)
//    (h3,a)  PLAYFIELD  0xFF8000 + ...   the tile code   word (VRAMA13 = 7M = 0)
//    (h3,b)  ALPHA      0xFFC000 + ...   one word per 16 dots
//    the other 13 cycles                 MOTION OBJECT LINK
//
//  Once per line, in the LINKRES window (H = 442..445), that playfield pair
//  becomes the SLIP fetch: /SLIP is low in (442,b) and SLIPUP high in
//  (443,a).  SLIPUP tri-states muxes 180F and 150F so pull-ups force
//  VRAMA10:7 to 1, giving the address 0xFFCF80 + 2 * VS[8:3].
//
//  A 68000 access gets exactly two 14MA cycles per bus cycle, never starting
//  in (h2,a)..(h3,b), and its /DTACK comes only from VCYCDONE.  RAMCPU is
//  high in the second of the two; /VIDCPU is low in that cycle and the next,
//  to cover the F174 latch delay, which is also why a CPU write produces two
//  write pulses.
//
//  3. Video port.  `vd[15:0]` is the word on the video data bus during the
//  current 14MA cycle.  A consumer captures it with
//
//        always_ff @(posedge clk) if (ce_14m) x <= vd;
//
//  which models the board's rising-edge latches (LS374 180K/210K PF code,
//  190K/220K alpha, LS175 230N PF colour) at the edge ending the cycle.
//  Exactly one of the strobes below is high with `vd`.  They are decoded
//  from the latched address, so the LINKRES window's junk read raises none:
//
//    vd_cpu        the 68000's read word
//    vd_alpha      an alphanumerics word   0xFFC000 + 2*(V[7:3]*64 + H[8:3])
//    vd_pf_colour  a playfield colour word 0xFFA000 + 2*(HS[8:3]*64 + VS[8:3])
//    vd_pf_code    a playfield code word   0xFF8000 + the same offset
//    vd_slip       the MO SLIP entry       0xFFCF80 + 2*VS[8:3]
//    vd_mob        a motion-object word    0xFFD000 + 0x800*MOBMSB + 8*L + 2*MC
//                  (`vd_mob_mc` = the MC1:0 that addressed it)
//
//  `vd_addr` is the address that produced `vd` and `vd_src` its (RASB,RASA)
//  code.  The MOB presents MC1:0 on `mob_mc` one 14MA cycle before the word
//  it wants appears on `vd` (see 4).  The link byte L7:0 is `link_l`.
//
//  4. VRAMA2 / VRAMA1.  The sheet shows these two bits as an unlatched buffer
//  (F244 150C) whose enable leaves the sheet.  Taken literally that cannot
//  work: the RAM address in cycle C+1 is latched from the mux in cycle C, so
//  unlatched low bits would come from a different source (alpha fetches
//  would read the wrong column; the /PFUPPER double write would hit two
//  addresses).  So here VRAMA2:1 are formed at the mux, from `mob_mc` in an
//  MO cycle, and latched with the rest of the address.  For the CPU, alpha
//  and playfield that is identical to the board; for the MOB it means MC1:0
//  is presented one 14MA cycle earlier.
//
//  5. The RAMs: four 8 K x 8 SRAMs on the shared VD15:0 bus, two 16-bit banks.
//
//    bank A  208H (VD15:8) + 235H (VD7:0)   VRAMA14 = 1
//            0xFFC000 alpha + SLIP | 0xFFD000 MO list | 0xFFE000 work RAM
//    bank B  221H (VD15:8) + 250H (VD7:0)   VRAMA14 = 0
//            0xFF8000 tile code | 0xFFA000 tile colour
//
//  /OE is grounded on all four.  A12 is VRAMA13 on three of them and
//  VRAMA13S on 250H alone, which is what makes the /PFUPPER trick work.
//  Stored as four byte arrays (32 M10K).
//
//  6. The /PFUPPER two-pulse colour write:
//    LS27 210F : NOR(BA14, BA13, /VIDCPU)   -> F74 80C-B /CLR
//    F32 40H   : /VWRH OR /VWRL             -> F74 80C-B CK (D = 1)
//    F32 180J  : VRAMA13S = VRAMA13 OR Q    (250H's A12 only)
//    80C /Q    -> LS374 140E /OE
//
//  A CPU write to 0xFF8000-0xFF9FFF releases the flop's clear, then:
//    1. the PAL grants two 14MA periods, so the write strobes pulse twice;
//    2. first pulse: Q = 0, the CPU's byte goes to VD7:0 and the tile code
//       word is written at 0xFF8000 + offset;
//    3. that pulse's rising edge sets Q: VRAMA13S becomes 1 (250H only) and
//       LS374 140E, loaded by the last write to /PFUPPER, drives VD7:0;
//    4. second pulse: that colour byte is written at 0xFFA000 + offset;
//    5. when /VIDCPU releases, the flop is cleared again.
//
//  This is MAME's `playfield_latched_w`, except that only the low byte of the
//  0xFFA000 word is rewritten (harmless: only D3:0 is used) and there is no
//  "latch disabled" state; 140E always holds a value.  The program writes the
//  latch only at FF1E01, as a byte.
//
//  7. The F373 200K link register: D = VD7:0, /OE = GND.  Its G input is not
//  legible on the schematic; the only PAL output that fits is E, which is
//  high in the motion-object slots (LINK_G_FROM_E = 1).  With G = E the latch
//  is also open during the SLIP cycle (/SLIP low forces E high), so the SLIP
//  entry's low byte becomes the line's starting link: that is how "LINKRES
//  resets the link register" works, since an F373 has no clear.
//============================================================================

module skullxbo_vram #(
	// The F373 200K's `G`: 1 = the PAL's `E` (see the header); 0 = the
	// external `mob_link_g`.
	parameter bit LINK_G_FROM_E = 1'b1,
	// 1 = the address mux and `link_l` use the MOB's own link register on
	// `link_ext` instead of the F373 200K copy below.  skullxbo_core sets 1, so
	// the address and the MOB's own list walk use the same link value.
	parameter bit LINK_FROM_MOB = 1'b0
)(
	input  logic        clk,          // clk_sys, 57.272727 MHz
	input  logic        init_reset,   // FPGA power-up only
	input  logic        ce_14m,       // the 14MA rising tick (see header 1)

	// ---------------- the raster (from the video block) -------------------
	input  logic  [8:0] h,            // the SOS-2 H count, 0..455
	input  logic        pix,          // the board's `7M`: 0 in (H,a), 1 in (H,b)
	input  logic  [8:0] v,            // the V bus; only V[7:3] reach the muxes
	input  logic  [8:0] hs,           // PFHS 8HS..256HS; only HS[8:3] are wired
	input  logic  [8:0] vs,           // LS191 1VS..256VS; only VS[8:3] are wired
	input  logic        linkres_n,    // /LINKRES, H = 442..445

	// ---------------- the 68000 side -------------------------------------
	input  logic        as,           // ACTIVE HIGH copy of /AS
	input  logic        rw,           // 1 = read, 0 = write
	input  logic        wh_n,         // /WH = /UDS + /W
	input  logic        wl_n,         // /WL = /LDS + /W
	input  logic        vidram_n,     // /VIDRAM (includes /MOBWR and /VSCRL)
	input  logic        vcycdone,     // LS74 110C-B -> PAL pin 9
	input  logic [14:1] cpu_a,        // BA14:1
	input  logic [15:0] cpu_din,      // BD15:0 on a write
	output logic [15:0] cpu_dout,     // LS373 170K / 140C

	// ---------------- the /PFUPPER colour register (LS374 140E) ----------
	input  logic        pfupper_we,   // 1-clk pulse at the RISING edge of /PFUPPER
	input  logic  [7:0] pfupper_d,    // BD7:0 at that moment

	// ---------------- the MO list interface ------------------------------
	input  logic        mobmsb,       // LS00 120C -> VRAMA11 mux C3
	input  logic  [1:0] mob_mc,       // the MOB's MC1:0 -> VRAMA2/1 (header 4)
	input  logic        mob_link_g,   // only used when LINK_G_FROM_E = 0
	input  logic  [7:0] link_ext,     // only used when LINK_FROM_MOB = 1
	output logic  [7:0] link_l,       // F373 200K Q = L7:0

	// ---------------- the video port (header 3) --------------------------
	output logic [15:0] vd,           // the word on VD during THIS 14MA cycle
	output logic [14:1] vd_addr,      // the VRAM address that produced it
	output logic  [1:0] vd_src,       // {RASB,RASA}: 00 CPU 01 alpha 10 PF 11 MO
	output logic        vd_cpu,
	output logic        vd_alpha,
	output logic        vd_pf_colour,
	output logic        vd_pf_code,
	output logic        vd_slip,
	output logic        vd_mob,
	output logic  [1:0] vd_mob_mc,

	// ---------------- PAL 110E's eight outputs ---------------------------
	output logic        rasa,         // pin 13
	output logic        rasb,         // pin 14
	output logic        slipup,       // pin 15
	output logic        e,            // pin 16
	output logic        slip_n,       // pin 17
	output logic        ramcpu,       // pin 18 -> VCYCDONE, the LS373 latches
	output logic        vidcpu_n,     // pin 19
	output logic        pal_p12,      // pin 12 -- not wired out on the board

	// ---------------- F174 160H's derived nets, for the video block ------
	output logic        h4d14m,       // 4H delayed one 14MA -> the alpha latch clock
	output logic        h4d35h_n,     // /4HD3.5H -> LS175 230N (the PF colour latch)
	output logic        e_d,          // E delayed one 14MA -> MOB pin 10 (MO-CTC)
	output logic        slipup_d_n,   // /SLIPUP delayed one 14MA

	// ---------------- debug outputs (the real pins) ----------------------
	output logic        vmemh_n,
	output logic        vmeml_n,
	output logic        vwrh,         // 1 while the /VWRH pulse of this cycle is due
	output logic        vwrl,
	output logic        pfupper_q     // F74 80C-B Q (the second-pulse selector)
);

	// =====================================================================
	//  PAL16R8 110E (136072-2143): the eight registered equations
	// =====================================================================
	//  From the 136072-2143 fuse dump, decoded with MAME's jedutil.  On a PAL16R8
	//  the D input of each register is the sum of products and the pin is
	//  driven from the register through an INVERTING buffer, with the array
	//  feedback taken from that same node -- so `rfN` is the PIN level and
	//  `/rfN := S` reads `pin_N(next) = NOT(S)`.
	//
	//    pin 1  CLK = 14MA          pin 2  = GND, used by NO product term
	//    pin 3  i3  = 7M            pin 4  i4 = 1H
	//    pin 5  i5  = 2H            pin 6  i6 = 4H
	//    pin 7  i7  = /VIDRAM       pin 8  i8 = /LINKRES
	//    pin 9  i9  = VCYCDONE      pin 11 /OE = GND (never floats)
	//    12 (nc) 13 RASA  14 RASB  15 SLIPUP  16 E  17 /SLIP  18 RAMCPU  19 /VIDCPU
	//
	//  Pin 2 is grounded and used by no equation, which cross-checks the pin
	//  reading.
	wire i3 = pix;          // 7M: 1 in (H,b), 0 in (H,a)
	wire i4 = h[0];         // 1H
	wire i5 = h[1];         // 2H
	wire i6 = h[2];         // 4H
	wire i7 = vidram_n;     // /VIDRAM
	wire i8 = linkres_n;    // /LINKRES
	wire i9 = vcycdone;     // VCYCDONE

	logic rf12, rf13, rf14, rf15, rf16, rf17, rf18, rf19;

	wire d12 = ~(  ( i4 & ~i5 & ~i6)
	             | (~i4 &  i5 & ~i6) );

	wire d13 = ~(  (~i7 & ~i9 &  rf12)
	             | (~i7 & ~i9 & ~rf13 & ~rf14)
	             | (~i4 &  i5 & ~i6) );

	wire d14 = ~(  (~i7 & ~i9 &  rf12)
	             | (~i7 & ~i9 & ~rf13 & ~rf14)
	             | (~i3 &  i4 &  i5 & ~i6) );

	wire d15 = ~(   i8 | ~i3 | i4 | ~i5 | i6 );

	wire d16 = ~(  (~i7 & rf17)
	             | (~i4 &  i5 & ~i6 & rf17)
	             | (~i3 &  i4 &  i5 & ~i6 & rf17) );

	wire d17 = ~(  ~i3 & ~i4 & i5 & ~i6 & ~i8 );

	wire d18 = ~( rf13 | rf14 | ~rf19 );

	wire d19 = ~( ~rf13 & ~rf14 );

	always_ff @(posedge clk) begin
		if (init_reset) begin
			// The part has no reset pin; this is an FPGA power-up value only:
			// the idle state (the MO link owns the bus, nothing is granted).
			rf12 <= 1'b1; rf13 <= 1'b1; rf14 <= 1'b1; rf15 <= 1'b0;
			rf16 <= 1'b1; rf17 <= 1'b1; rf18 <= 1'b0; rf19 <= 1'b1;
		end else if (ce_14m) begin
			rf12 <= d12; rf13 <= d13; rf14 <= d14; rf15 <= d15;
			rf16 <= d16; rf17 <= d17; rf18 <= d18; rf19 <= d19;
		end
	end

	assign pal_p12  = rf12;
	assign rasa     = rf13;
	assign rasb     = rf14;
	assign slipup   = rf15;
	assign e        = rf16;
	assign slip_n   = rf17;
	assign ramcpu   = rf18;
	assign vidcpu_n = rf19;

	// =====================================================================
	//  the seven address multiplexers
	// =====================================================================
	//  `SB` (pin 2) = RASB, `SA` (pin 14) = RASA on all seven, and the four
	//  sources are  00 CPU | 01 alpha | 10 playfield | 11 MO link (confirmed by
	//  /VIDCPU' = NOT(/RASA & /RASB), the net that enables the CPU's data
	//  buffers).
	wire linkres = ~linkres_n;

	// the two gates that feed the playfield column of the table
	wire pf_a12 = linkres_n & hs[8];      // 200F LS08 pin 6 : /LINKRES & 256HS
	wire pf_a11 = hs[7] | linkres;        // 190E LS32 pin 3 : 128HS OR LINKRES

	// Continuous assigns rather than an always_comb, to keep iverilog 12 quiet.
	// The four columns are the schematic's mux inputs, bit for bit.
	wire [14:1] mux_cpu   = cpu_a;                                  // C0
	wire [14:1] mux_alpha = { 1'b1, 1'b0, 1'b0, v[7], v[6], v[5], v[4], v[3],
	                          h[8], h[7], h[6], h[5], h[4], h[3] }; // C1
	wire [14:1] mux_pf    = { linkres, i3, pf_a12, pf_a11,
	                          hs[6], hs[5], hs[4], hs[3],
	                          vs[8], vs[7], vs[6], vs[5], vs[4], vs[3] };  // C2
	wire [14:1] mux_mo    = { 1'b1, 1'b0, 1'b1, mobmsb,
	                          link_l[7], link_l[6], link_l[5], link_l[4],
	                          link_l[3], link_l[2], link_l[1], link_l[0],
	                          mob_mc[1], mob_mc[0] };               // C3

	wire [14:1] mux_sel = rasb ? (rasa ? mux_mo    : mux_pf)
	                           : (rasa ? mux_alpha : mux_cpu);

	// SLIPUP tri-states 180F and 150F; R78/R75/R69/R70 (1K to +5V) then pull
	// VRAMA10:7 to 1.  Together with VRAMA14 = LINKRES = 1, VRAMA13 = 7M = 0,
	// VRAMA12 = /LINKRES & 256HS = 0 and VRAMA11 = 128HS | LINKRES = 1 that is
	// exactly 0xFFCF80 + 2*VS[8:3].
	wire [14:1] mux = slipup ? {mux_sel[14:11], 4'b1111, mux_sel[6:1]}
	                         : mux_sel;

	// =====================================================================
	//  F174 160H / 190H / 120H -- the address latch
	// =====================================================================
	logic [14:1] vram_a;
	logic  [1:0] src_lat;
	logic        slipup_lat;

	// F174 160H's three derived nets: 4H delayed one 14MA, the h == 3
	// decode delayed one 14MA, and E and /SLIPUP delayed one 14MA.
	wire h_is3 = ~h[2] & h[1] & h[0];      // 70E LS02 pin 1

	always_ff @(posedge clk) begin
		if (init_reset) begin
			vram_a     <= '0;
			src_lat    <= 2'b11;
			slipup_lat <= 1'b0;
			h4d14m     <= 1'b0;
			h4d35h_n   <= 1'b1;
			e_d        <= 1'b1;
			slipup_d_n <= 1'b1;
		end else if (ce_14m) begin
			vram_a     <= mux;
			src_lat    <= {rasb, rasa};
			slipup_lat <= slipup;
			h4d14m     <= h[2];            // D13 = 4H  -> Q12 = 4HD14M
			h4d35h_n   <= ~h_is3;          // D6 -> Q7 = /4HD3.5H
			e_d        <= e;               // D4 -> Q5  -> MOB pin 10 (MO-CTC)
			slipup_d_n <= ~slipup;         // D3 -> Q2
		end
	end

	// =====================================================================
	//  /VMEMH, /VMEML, /VWRH, /VWRL and the 80C flop
	// =====================================================================
	//    LS32 190E : 10 = /WH , 9 = /VIDCPU -> 8 = /VMEMH
	//                 5 = /VIDCPU , 4 = /WL -> 6 = /VMEML
	//    F32  180J : 5 = /VMEMH , 4 = 14MA  -> 6 = /VWRH
	//                2 = 14MA   , 1 = /VMEML -> 3 = /VWRL
	//  /VWRH is low only while /VMEMH is low AND 14MA is low -- one ~35 ns pulse
	//  in the second half of each 14MA period, RISING at the next 14MA edge.  So
	//  "a write pulse completes at the ce_14m edge ending this cycle" is exactly
	//  "/VMEMH was low during this cycle", and the PAL's two-cycle grant emits
	//  two of them.
	assign vmemh_n = vidcpu_n | wh_n;
	assign vmeml_n = vidcpu_n | wl_n;
	assign vwrh    = ~vmemh_n;
	assign vwrl    = ~vmeml_n;

	// LS27 210F (a 3-input NOR) -> 80C F74-B /CLR.  The flop is held cleared
	// unless BA14 = 0, BA13 = 0 and /VIDCPU is low -- i.e. unless this is a CPU
	// access to 0xFF8000-0xFF9FFF, the playfield CODE half.
	wire pfu_clr_n = ~cpu_a[14] & ~cpu_a[13] & ~vidcpu_n;

	always_ff @(posedge clk) begin
		if (init_reset)          pfupper_q <= 1'b0;
		else if (!pfu_clr_n)     pfupper_q <= 1'b0;             // /CLR, level
		else if (ce_14m && (vwrh | vwrl)) pfupper_q <= 1'b1;    // CK = OR(/VWRH,/VWRL) rising
	end

	// F32 180J pin 11: VRAMA13S = VRAMA13 OR Q(80C), for 250H only (the
	// playfield low byte).  221H keeps plain VRAMA13, so only the low byte of
	// the 0xFFA000 word is rewritten.
	wire vram_a13s = vram_a[13] | pfupper_q;

	// LS374 140E, the /PFUPPER colour register.  CK = /PFUPPER, i.e. the RISING
	// edge at the END of the write; /OE = /Q(80C), so it drives VD7:0 exactly
	// while pfupper_q is high.
	logic [7:0] pfupper_reg;
	always_ff @(posedge clk) begin
		if (init_reset)       pfupper_reg <= 8'h00;
		else if (pfupper_we)  pfupper_reg <= pfupper_d;
	end

	// =====================================================================
	//  the four 8 K x 8 SRAMs
	// =====================================================================
	logic [7:0] memA_hi [0:8191];   // 208H  ANMOHI
	logic [7:0] memA_lo [0:8191];   // 235H  ANMOLO
	logic [7:0] memB_hi [0:8191];   // 221H  PFHI
	logic [7:0] memB_lo [0:8191];   // 250H  PFLO  (its A12 is VRAMA13S)

`ifndef ALTERA_RESERVED_QIS
	// Simulation only -- Quartus zeroes M10K contents on configuration.  Keeps
	// iverilog and Verilator free of X on an unwritten cell.
	initial begin
		for (int i = 0; i < 8192; i++) begin
			memA_hi[i] = '0; memA_lo[i] = '0;
			memB_hi[i] = '0; memB_lo[i] = '0;
		end
	end
`endif

	// The address the RAM sees during the CURRENT cycle is `vram_a`; the address
	// for the NEXT cycle is the mux output being latched at this same edge.
	wire [12:0] ridx   = mux[13:1];
	wire [12:0] widx   = vram_a[13:1];
	wire [12:0] widx_b_lo = {vram_a13s, vram_a[12:1]};   // 250H's own A12

	wire bank_a_w = vram_a[14];       // CS2 on 208H/235H, /CS1 on 221H/250H

	logic [7:0] qA_hi, qA_lo, qB_hi, qB_lo;
	logic       bank_q;

	// the bus value this cycle (RAM or one of the write drivers), which is also what
	// a write puts into the cell
	wire [15:0] ram_q = bank_q ? {qA_hi, qA_lo} : {qB_hi, qB_lo};

	assign vd[15:8] = vwrh      ? cpu_din[15:8] : ram_q[15:8];  // LS244 160K
	assign vd[7:0]  = pfupper_q ? pfupper_reg                   // LS374 140E
	                : vwrl      ? cpu_din[7:0]                  // LS244 130E
	                :             ram_q[7:0];

	always_ff @(posedge clk) begin
		if (ce_14m) begin
			// the write pulse that completes at THIS 14MA rising edge
			if (vwrh &&  bank_a_w) memA_hi[widx]      <= vd[15:8];
			if (vwrl &&  bank_a_w) memA_lo[widx]      <= vd[7:0];
			if (vwrh && !bank_a_w) memB_hi[widx]      <= vd[15:8];
			if (vwrl && !bank_a_w) memB_lo[widx_b_lo] <= vd[7:0];
			// the read for the NEXT cycle, at the address the F174 is latching
			qA_hi  <= memA_hi[ridx];
			qA_lo  <= memA_lo[ridx];
			qB_hi  <= memB_hi[ridx];
			qB_lo  <= memB_lo[ridx];
			bank_q <= mux[14];
		end
	end

	// =====================================================================
	//  the CPU read latches LS373 170K / 140C
	// =====================================================================
	//  `G` = RAMCPU, `/OE` = F32 40H pin 3 (low only during a video-RAM READ).
	//  A 74LS373 is TRANSPARENT while G is high and freezes on its falling edge,
	//  so the CPU gets a stable word after its single slot even though VD
	//  immediately reverts to the video fetches.  RAMCPU is high for exactly the
	//  second of the CPU's two granted cycles, and the word on VD in that cycle
	//  is the CPU's (the address latched into it came from the first).
	always_ff @(posedge clk) begin
		if (init_reset)             cpu_dout <= 16'h0000;
		else if (ce_14m && ramcpu)  cpu_dout <= vd;
	end

	// =====================================================================
	//  F373 200K -- the motion-object link register
	// =====================================================================
	//  A transparent latch: `G` follows `E` (see the header) and `/OE` = GND.
	//  Because `/SLIP` low forces `E` high, the SLIP entry's low byte is what
	//  restarts the walk once per line.
	wire link_g = LINK_G_FROM_E ? e : mob_link_g;
	logic [7:0] link_q;
	always_ff @(posedge clk) begin
		if (init_reset)           link_q <= 8'h00;
		else if (ce_14m & link_g) link_q <= vd[7:0];
	end
	assign link_l = LINK_FROM_MOB ? link_ext : link_q;

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused_link = &{1'b0, link_ext, link_q, 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

	// =====================================================================
	//  the video port
	// =====================================================================
	//  Decoded from the LATCHED ADDRESS, so the LINKRES window's junk read at
	//  (442,b) -- a "playfield" cycle whose VRAMA14 is 1 because LINKRES is the
	//  C2 input of that mux -- raises no strobe at all.
	assign vd_addr = vram_a;
	assign vd_src  = src_lat;

	assign vd_cpu       = (src_lat == 2'b00);
	assign vd_alpha     = (src_lat == 2'b01);
	assign vd_pf_colour = (src_lat == 2'b10) & ~slipup_lat & ~vram_a[14] &  vram_a[13];
	assign vd_pf_code   = (src_lat == 2'b10) & ~slipup_lat & ~vram_a[14] & ~vram_a[13];
	assign vd_slip      = (src_lat == 2'b10) &  slipup_lat;
	assign vd_mob       = (src_lat == 2'b11);
	assign vd_mob_mc    = vram_a[2:1];

	/* verilator lint_off UNUSEDSIGNAL */
	// `as` and `rw` reach the logic through /WH, /WL and /VIDRAM.  v[8],
	// v[2:0], hs[2:0] and vs[2:0] are not wired to any mux input on the board.
	wire _unused = &{1'b0, as, rw, v[8], v[2:0], hs[2:0], vs[2:0], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
