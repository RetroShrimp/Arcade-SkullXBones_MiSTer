`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones: the Atari MOB (137593-001) motion-object engine at
//  130K, schematic sheet 6.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  MAME's atarimo.cpp is the
//  functional reference for the list semantics.
//
//  The MOB is an undumped custom with no data sheet.  Everything the
//  surrounding hardware forces is implemented literally; every remaining
//  choice is a named parameter, with its default explained below.
//
//  What the pins force.  The part sees VD15:0, 14MB, /CS (= /VWRH OR
//  /MOBWR), /SLIP, /VRES (on the pin named VBLANK), E (on the pin named
//  MO-CTC, an input) and its own /LOADLB fed back on LAT/HP.  It drives
//  MOROMA17:0, MHPOS9:0, MO2H, MO4H, /MOBLD, /GS, MHFLIP, /LOADLB, MOPRI1:0,
//  MOPAL3:0 and MC1:0, the two low video-RAM address bits: MC1:0 selects the
//  word inside a list entry while the F373 200K link register selects the
//  entry.  There is no MOAT7 and the playfield half is disabled.
//
//  There is no vertical-counter input.  The MOB can only know the line from
//  /SLIP (one edge per line), /VRES (one per frame) and the /MOBWR register
//  writes, whose low nibble tags them 0x9 (horizontal scroll) or 0xD
//  (vertical scroll); that is why the program also writes every scroll value
//  to FF4856.
//
//  The list (MAME s_mob_config):
//      entry at 0xFFD000 + 0x800*MOBMSB + 8*link :
//        word 0 : D7:0  = the next link          (D15:8 unused)
//        word 1 : D14:0 = stamp code , D15 = H-flip
//        word 2 : D3:0  = colour , D5:4 = priority , D15:6 = X
//        word 3 : D15:7 = Y , D6:4 = width-1 in tiles , D3:0 = height-1
//
//  Geometry (from atarimo.cpp::render_object).  MAME computes
//  ypos = (-Y - yscroll - 8*height) & 0x1ff and draws tile row ty at
//  sy = ypos + 8*ty.  Screen row y is covered if y - ypos is in
//  [0, 8*height), and y - ypos = (y + yscroll) + Y + 8*height.  y + yscroll
//  is exactly the LS191 counter VS, so the hardware test is a 9-bit add and
//  a compare:
//
//      d  = (VS + Y + 8*height) & 0x1FF        match if d < 8*height
//      ty = d[6:3]                             row = d[2:0]
//
//  (The mask cannot alias: MAME's ypos is within [-272, 240) and y within
//  [0, 240).)
//
//  Horizontally MAME uses xpos = X - xscroll and, for H-flip, starts at
//  xpos + (width-1)*16 with a negative step, so the tile at xpos + 16*k is
//  width-1-k.  The F163 line-buffer counters only count up, so the hardware
//  walks k upward:
//
//      MHPOS(k) = (X - 2*xscroll + 16*k) & 0x3FF
//      stamp(k) = code + ty*width + (MHFLIP ? width-1-k : k)
//
//  Schedule:
//  * /SLIP is low in (442,b), SLIPUP forms the address in (443,a) and the
//    SLIP word is on VD during (443,b); the MOB samples it at the edge into
//    (444,a) (`MOB_SLIP_PHASE`).  LINKRES has already zeroed the link
//    register, so the line's starting link is that word's VD7:0.
//  * The PAL gives the MOB 13 of every 16 14MA cycles, all except (h2,b),
//    (h3,a) and (h3,b).
//  * The pixel side takes one 16-dot stamp slice per 8 H counts, 57 per
//    line.  Matched objects wait in a short queue the emitter drains; the
//    walk stalls when the queue is full, which is what limits objects per
//    line.  (MAME's maxperline = 0 has no limit.)
//  * The walk ends when a link repeats (MAME's `visited[]`,
//    `MOB_END_VISITED`).
//
//  Read order 3, [1, 2], 0 (`MOB_W3_FIRST`).  Word 0 is the link, and
//  reading it last is the only order that lets the walk run with no dead
//  cycle: the link register loads from VD7:0 in the cycle word 0 arrives, so
//  the next entry's first word is addressed in the following cycle.  It is
//  also the only order in which a transparent latch on VD7:0 gated by a
//  motion-object-slot enable (the F373 with G = E) ends up holding the link.
//  Word 3 (Y / size) comes first so an entry that does not cover the line
//  costs two reads, not four; words 1-2 are read only on a match.
//
//  The inferred choices and their defaults:
//  `MOB_CODE_CARRY`  1: the per-tile stamp index is a full 15-bit add that
//        carries into the bank bits MOROMA[17:15], as in MAME's flat code.
//  `MOB_YSRC`        1: the vertical reference is the LS191 VS bus.  The
//        MOB has no such pins, but the SLIP band address is formed from VS,
//        so a private counter that differed would match against a different
//        line than the band it read.  0 selects a private counter loaded only
//        by 0xD-tagged /MOBWR writes.
//  `MOB_LINE_ADJ`    1: the vertical match runs one line ahead of VS (see
//        the parameter).
//  `MOB_TL_CONST` 1 / `MOB_MISC_CONST` 0: MOTL and MOMISC reach the board
//        multiplexed on MHPOS7:6 under LD5, and nothing shows where the MOB
//        gets them.  MOTL = 1 reproduces MAME's shadow rule and MOMISC = 0
//        MAME's "alpha always wins".  `MOB_ATTR_FROM_W0` = 1 instead takes
//        them from word 0's D9:8, the only unused field in the entry.
//  `MOB_SLIP_PHASE`  0: sample at the edge into (444,a); 1 delays one more
//        14MA cycle.
//  `MOB_VRES_YREF`   1: the walk that builds screen line 0 matches against
//        the MOB's own 0xD register (see the parameter).
//============================================================================

module skullxbo_mob #(
	parameter bit MOB_CODE_CARRY   = 1'b1,
	parameter bit MOB_YSRC         = 1'b1,
	parameter bit MOB_TL_CONST     = 1'b1,
	parameter bit MOB_MISC_CONST   = 1'b0,
	parameter bit MOB_ATTR_FROM_W0 = 1'b0,
	parameter bit MOB_END_VISITED  = 1'b1,
	// The F373 200K link register is a transparent latch (see `l` below).
	// 0 models it as an edge-triggered register (test only; wrong).
	parameter bit MOB_LINK_LATCH   = 1'b1,
	parameter int MOB_SLIP_PHASE   = 0,
	// The buffer built in the window that starts at the SLIP capture of line N
	// is displayed on line N+2 (the window itself spans line N+1's visible
	// part), while the SLIP address the mux formed used `VS` = V(N+1).  So the
	// vertical match runs one line ahead of `VS`.  0 gives the literal "match
	// against VS" reading, which puts the whole motion-object layer one
	// scanline low against MAME.
	parameter int MOB_LINE_ADJ     = 1,
	// Depth of the matched-object queue between the walk and the emitter.
	parameter int MOB_QUEUE        = 8,
	// The list-walk read order.  1 = read word 3 (Y / size) first and, when the
	// entry does not cover this line, go straight to word 0 (the link),
	// skipping words 1 and 2: order 3, [1, 2 if match], 0.  Word 0 stays last,
	// so the transparent-latch argument for the F373 is unchanged.  0 = the
	// fixed order 1, 2, 3, 0.
	// Inferred (the MOB is undumped; the schematic fixes only which word MC1:0
	// selects, not the order) but chosen on evidence: with 1, 2, 3, 0 and the
	// CPU's video-RAM stalls, the last tiles of long lines (the BURIED BOOTY
	// vase) are dropped, while a real PCB draws them.  Vindicators'
	// schematic-derived walk reads Y/size + link per entry the same way.
	parameter bit MOB_W3_FIRST     = 1'b1,
	// The vertical reference of the walk that builds screen line 0.  That
	// walk starts at the SLIP sample of the line before /VRES, i.e. before
	// the (444, a) frame window re-loads the LS191s.  1 = that one walk
	// matches against the MOB's own 0xD register (the frame's vertical
	// scroll, written by /MOBWR during VBLANK), which is the line MAME draws
	// there.  Inferred: the MOB has no VS pins, only /MOBWR and /VRES.  The
	// SLIP band this walk starts from is still formed from `VS`.
	// 0 = match against `VS + MOB_LINE_ADJ` on every line.
	parameter bit MOB_VRES_YREF    = 1'b1
)(
	input  logic        clk,
	input  logic        reset,

	// ---- raster ----------------------------------------------------------
	input  logic        ce_14m,      // 14MB — the MOB's master clock
	input  logic        ce_7m,
	input  logic [8:0]  h,
	input  logic        pix,         // 0 = the (H,a) cycle, 1 = (H,b)
	input  logic        linkres,
	input  logic        ce_slip_rise,// /SLIP's rising edge (the line tick)
	input  logic        mo_ctc,      // PAL 110E E this cycle -> MO-CTC
	input  logic        vres_walk,   // this line's SLIP sample starts the line-0 walk

	// ---- the video data bus ---------------------------------------------
	input  logic [15:0] vd,
	input  logic [8:0]  vs,          // the LS191 counter (MOB_YSRC = 1)

	// ---- the CPU register port -----------------------------------------
	// `mobwr_we` is a level (/VWRH & /MOBWR), not a pulse: the MOB's /CS is a
	// level on the board.  The data is its own net, VD15:0 captured by
	// skullxbo_main, not this module's `vd`: `vd` is the live video bus and
	// changes every 14MA cycle.  The write is idempotent while the level is
	// held.
	input  logic        mobwr_we,
	input  logic [15:0] mobwr_d,

	// ---- to the video-RAM address mux -----------------------------------
	output logic [7:0]  l,           // L7:0  — the F373 200K link register
	output logic [1:0]  mc,          // MC1:MC0 -> VRAMA2 / VRAMA1

	// ---- the per-slice emission -----------------------------------------
	output logic        slice_stb,   // one clk pulse at the slice boundary
	output logic        slice_live,  // /GS asserted: this slice is real
	output logic [14:0] mo_code,     // the stamp index -> MOROMA[17:3]
	output logic [2:0]  mo_row,      // MOROMA[2:0]
	output logic        mhflip,      // MHFLIP
	output logic [9:0]  mhpos,       // MHPOS9:0
	output logic [3:0]  mopal,       // MOAT3:0
	output logic [1:0]  mopri,       // MOAT5:4
	output logic        motl,        // multiplexed on MHPOS7 under LD5
	output logic        momisc,      // multiplexed on MHPOS6 under LD5

	// ---- debug outputs --------------------------------------------------
	output logic [8:0]  mob_xscroll,
	output logic [8:0]  mob_yscroll,
	output logic [8:0]  mob_vs,
	output logic [7:0]  slices_this_line,
	output logic [7:0]  entries_this_line
);

	localparam int QW = (MOB_QUEUE <= 2) ? 1 : $clog2(MOB_QUEUE);

	// =====================================================================
	// 1. The /MOBWR register file (0x9 = horizontal, 0xD = vertical)
	// =====================================================================
	logic [8:0] vs_priv;

	always_ff @(posedge clk) begin
		if (reset) begin
			mob_xscroll <= 9'd0;
			mob_yscroll <= 9'd0;
			vs_priv     <= 9'd0;
		end else begin
			if (mobwr_we) begin
				if (mobwr_d[3:0] == 4'h9) mob_xscroll <= mobwr_d[15:7];
				if (mobwr_d[3:0] == 4'hD) begin
					mob_yscroll <= mobwr_d[15:7];
					vs_priv     <= mobwr_d[15:7];
				end
			end else if (ce_slip_rise) begin
				vs_priv <= vs_priv + 9'd1;
			end
		end
	end
	assign mob_vs = MOB_YSRC ? vs : vs_priv;

	// =====================================================================
	// 2. The video-RAM slot map (PAL 110E)
	// =====================================================================
	// The test is on the CURRENT `14MA` cycle: the address this module presents
	// in cycle N is the one the muxes drive in cycle N and the RAM answers in
	// cycle N+1.  In a playfield or alphanumerics slot the muxes ignore `L` and
	// `MC`, so a read issued there would capture that slot's word instead.
	//
	// `mo_ctc` is PAL 110E `E` (pin 16) for this cycle, the net that reaches
	// the MOB as MO-CTC through F174 160H.  `E` is high only in a cycle whose
	// address really is the MOB's: it is low for the playfield pair, the
	// alpha cycle, and whenever a 68000 video-RAM access is pending or
	// granted.  The fixed H schedule alone cannot see the CPU grant, and
	// using it would latch CPU words as list words (garbage slices wherever
	// the 68000 touched video RAM during the picture).  A read is issued only
	// when both agree; a cycle the CPU owns is simply not used.
	wire cur_is_mo = !((h[2:0] == 3'd3) || ((h[2:0] == 3'd2) && pix)) && mo_ctc;

	// =====================================================================
	// 3. The SLIP sample
	// =====================================================================
	wire slip_now = ce_14m &
	                ((MOB_SLIP_PHASE == 0) ? ((h == 9'd443) &  pix)
	                                       : ((h == 9'd444) & ~pix));

	// =====================================================================
	// 4. The slice grid — one 16-dot stamp slice per 8 H counts
	// =====================================================================
	assign slice_stb = ce_7m & (h[2:0] == 3'd7);

	// =====================================================================
	// 5. The list walk
	// =====================================================================
	logic         running;
	logic [7:0]   link;
	logic [1:0]   word_i;
	logic [15:0]  w1, w2, w3;
	logic         cap_v;
	logic [1:0]   cap_w;
	logic [255:0] visited;
	logic         linkres_d;

	// ---- the matched-object queue ---------------------------------------
	logic [MOB_QUEUE-1:0] q_v;
	logic [14:0]   q_code [0:MOB_QUEUE-1];
	logic          q_flip [0:MOB_QUEUE-1];
	logic [3:0]    q_pal  [0:MOB_QUEUE-1];
	logic [1:0]    q_pri  [0:MOB_QUEUE-1];
	logic [9:0]    q_x    [0:MOB_QUEUE-1];
	logic [2:0]    q_w    [0:MOB_QUEUE-1];
	logic [2:0]    q_row  [0:MOB_QUEUE-1];
	logic [3:0]    q_ty   [0:MOB_QUEUE-1];
	logic          q_tl   [0:MOB_QUEUE-1];
	logic          q_misc [0:MOB_QUEUE-1];
	logic [QW-1:0] q_wr, q_rd;

	wire  q_full  = q_v[q_wr];
	wire  q_empty = ~q_v[q_rd];
	logic q_take;                 // the emitter's take; the walk clears the slot

	// ---- the vertical match ----------------------------------------------
	wire [8:0] ent_y  = w3[15:7];
	wire [3:0] ent_h  = w3[3:0];               // height - 1, in tiles
	wire [2:0] ent_w  = w3[6:4];               // width  - 1, in tiles
	wire [8:0] hgt8   = {2'b00, ent_h, 3'b000} + 9'd8;      // 8 * height
	logic      walk_f0;                         // this walk builds screen line 0
	wire [8:0] mvs    = walk_f0 ? mob_yscroll : (mob_vs + MOB_LINE_ADJ[8:0]);
	wire [8:0] dmatch = mvs + ent_y + hgt8;
	wire       match  = (dmatch < hgt8);

	// ---- the F373 200K link register -------------------------------------
	// It is a transparent latch, and that matters.  Word 0 is read last
	// (3, [1, 2], 0); the read issued in the very cycle word 0's data is on
	// `VD` is the next entry's first word, so L7:0 must already carry the new
	// link in that cycle.  A 373 gated by `E` (high in every motion-object
	// slot) does exactly that.  As an edge-triggered register it would cost
	// one entry of pipeline: every entry after the first would take the
	// previous entry's first word (objects drawn with their neighbour's
	// graphic).
	wire link_now = MOB_LINK_LATCH & cap_v & (cap_w == 2'd0);
	assign l  = link_now ? vd[7:0] : link;

	// MOB_W3_FIRST: after word 3 has been issued (`after3`), the next word is
	// decided from word 3 itself -- the word on VD if it lands in this very cycle,
	// otherwise the w3 register it was captured into.
	logic        after3;
	wire  [15:0] w3_now   = (cap_v && (cap_w == 2'd3)) ? vd : w3;
	wire  [8:0]  hgt8_n   = {2'b00, w3_now[3:0], 3'b000} + 9'd8;
	wire  [8:0]  dmatch_n = mvs + w3_now[15:7] + hgt8_n;
	wire         match_n  = (dmatch_n < hgt8_n);
	wire  [1:0]  issue_w  = (MOB_W3_FIRST && after3) ? (match_n ? 2'd1 : 2'd0) : word_i;
	assign mc = issue_w;

	always_ff @(posedge clk) begin
		if (reset) begin
			running   <= 1'b0;
			walk_f0   <= 1'b0;
			link      <= 8'd0;
			word_i    <= MOB_W3_FIRST ? 2'd3 : 2'd1;
			after3    <= 1'b0;
			cap_v     <= 1'b0;
			cap_w     <= 2'd1;
			visited   <= 256'd0;
			linkres_d <= 1'b0;
			q_v       <= '0;
			q_wr      <= '0;
			w1 <= 16'd0; w2 <= 16'd0; w3 <= 16'd0;
			entries_this_line <= 8'd0;
		end else begin
			// LINKRES zeroes the F373 once per line, on its rising edge
			// only: the window is four counts wide and the SLIP word lands
			// inside it, so a level reset would wipe the starting link.
			linkres_d <= linkres;
			if (linkres & ~linkres_d) link <= 8'd0;

			if (q_take) q_v[q_rd] <= 1'b0;

			if (slip_now) begin
				link              <= vd[7:0];
				word_i            <= MOB_W3_FIRST ? 2'd3 : 2'd1;
				after3            <= 1'b0;
				running           <= 1'b1;
				walk_f0           <= MOB_VRES_YREF & vres_walk;
				cap_v             <= 1'b0;
				visited           <= 256'd0;
				entries_this_line <= 8'd0;
				// A new band/line restarts everything.  Objects left in the queue
				// would otherwise bleed onto the next lines, outliving their vertical
				// match.  The walk is re-run from the SLIP link every line, so nothing
				// may survive the restart.
				q_v               <= '0;
				q_wr              <= '0;
			end else if (ce_14m) begin
				// -- capture the word requested one 14MA cycle ago ----------
				if (cap_v) begin
					case (cap_w)
						2'd1: w1 <= vd;
						2'd2: w2 <= vd;
						2'd3: w3 <= vd;
						default: begin
							// word 0 = the LINK.  w3 landed last cycle, so the
							// whole entry is decided here and the link advances
							// in the same cycle — no dead slot.
							visited[link] <= 1'b1;
							if (entries_this_line != 8'hFF)
								entries_this_line <= entries_this_line + 8'd1;
							if (match && !q_full) begin
								q_v   [q_wr] <= 1'b1;
								q_code[q_wr] <= w1[14:0];
								q_flip[q_wr] <= w1[15];
								q_pal [q_wr] <= w2[3:0];
								q_pri [q_wr] <= w2[5:4];
								q_x   [q_wr] <= w2[15:6];
								q_w   [q_wr] <= ent_w;
								q_ty  [q_wr] <= dmatch[6:3];
								q_row [q_wr] <= dmatch[2:0];
								q_tl  [q_wr] <= MOB_ATTR_FROM_W0 ? vd[8]
								                                 : MOB_TL_CONST;
								q_misc[q_wr] <= MOB_ATTR_FROM_W0 ? vd[9]
								                                 : MOB_MISC_CONST;
								q_wr <= q_wr + 1'b1;
							end
							link <= vd[7:0];
							// MAME's loop is `while (!visited[link])` with
							// `visited[link] = 1` before it follows the link, so
							// an entry that links to itself is processed once.
							// `visited[link] <= 1` above is nonblocking, so the
							// array still reads 0 for the current link in this
							// cycle and the self-link has to be spotted
							// explicitly; without it a self-linked entry is
							// queued twice and displaces a later object whenever
							// the queue is full.
								if (MOB_END_VISITED &&
								    (visited[vd[7:0]] || (vd[7:0] == link)))
								running <= 1'b0;
						end
					endcase
				end
				cap_v <= 1'b0;

				// -- issue the next read -------------------------------------
				// The walk stalls with the queue full: that is the per-line
				// capacity limit.
				if (running && cur_is_mo && !(q_full && (issue_w == 2'd0))) begin
					cap_v  <= 1'b1;
					cap_w  <= issue_w;
					if (!MOB_W3_FIRST) begin
						word_i <= (word_i == 2'd3) ? 2'd0 : (word_i + 2'd1);
					end else begin
						case (issue_w)
							2'd3:    begin after3 <= 1'b1; end                  // then 1 or 0
							2'd1:    begin after3 <= 1'b0; word_i <= 2'd2; end  // match: 1, 2, 0
							2'd2:    begin word_i <= 2'd0; end
							default: begin after3 <= 1'b0; word_i <= 2'd3; end  // link read: next entry
						endcase
					end
				end
			end
		end
	end

	// =====================================================================
	// 6. The emitter — one 16-dot stamp slice per 8 H counts
	// =====================================================================
	logic         c_v;
	logic [14:0]  c_code;
	logic         c_flip;
	logic [3:0]   c_pal;
	logic [1:0]   c_pri;
	logic [9:0]   c_x;
	logic [2:0]   c_w;
	logic [2:0]   c_row;
	logic [3:0]   c_ty;
	logic         c_tl, c_misc;
	logic [2:0]   c_k;

	wire take_new = ~c_v & ~q_empty;
	assign q_take = slice_stb & take_new;

	wire [14:0] s_code = take_new ? q_code[q_rd] : c_code;
	wire        s_flip = take_new ? q_flip[q_rd] : c_flip;
	wire [2:0]  s_wid  = take_new ? q_w   [q_rd] : c_w;
	wire [2:0]  s_k    = take_new ? 3'd0         : c_k;
	wire [9:0]  s_x    = take_new ? q_x   [q_rd] : c_x;
	wire [3:0]  s_ty   = take_new ? q_ty  [q_rd] : c_ty;
	wire [2:0]  s_row  = take_new ? q_row [q_rd] : c_row;
	wire [3:0]  s_pal  = take_new ? q_pal [q_rd] : c_pal;
	wire [1:0]  s_pri  = take_new ? q_pri [q_rd] : c_pri;
	wire        s_tl   = take_new ? q_tl  [q_rd] : c_tl;
	wire        s_misc = take_new ? q_misc[q_rd] : c_misc;
	wire        s_live = c_v | ~q_empty;

	// stamp(k) = code + ty*width + (flip ? width-1-k : k)
	wire [3:0]  wid1     = {1'b0, s_wid} + 4'd1;          // 1..8
	wire [3:0]  tx       = s_flip ? (wid1 - 4'd1 - {1'b0, s_k}) : {1'b0, s_k};
	wire [7:0]  rowoff   = {4'd0, s_ty} * {4'd0, wid1};   // ty * width, <= 120
	wire [14:0] tile_off = {7'd0, rowoff} + {11'd0, tx};
	wire [14:0] code_sum = s_code + tile_off;

	always_ff @(posedge clk) begin
		if (reset) begin
			c_v <= 1'b0;  c_k <= 3'd0;  q_rd <= '0;
			slices_this_line <= 8'd0;
			slice_live <= 1'b0;
			mo_code <= 15'd0; mo_row <= 3'd0; mhflip <= 1'b0; mhpos <= 10'd0;
			mopal   <= 4'd0;  mopri  <= 2'd0; motl   <= 1'b0; momisc <= 1'b0;
		end else if (slip_now) begin
			// the emitter restarts with the walk (see the queue flush above)
			slices_this_line <= 8'd0;
			c_v              <= 1'b0;
			c_k              <= 3'd0;
			q_rd             <= '0;
			slice_live       <= 1'b0;
		end else begin
			if (slice_stb) begin
				slice_live <= s_live;
				if (s_live) begin
					mo_code <= MOB_CODE_CARRY
					             ? code_sum
					             : {s_code[14:12], code_sum[11:0]};
					mo_row  <= s_row;
					mhflip  <= s_flip;
					mhpos   <= s_x - {mob_xscroll, 1'b0} + {3'd0, s_k, 4'd0};
					mopal   <= s_pal;
					mopri   <= s_pri;
					motl    <= s_tl;
					momisc  <= s_misc;
					if (slices_this_line != 8'hFF)
						slices_this_line <= slices_this_line + 8'd1;

					if (take_new) begin
						c_v    <= (q_w[q_rd] != 3'd0);
						c_code <= q_code[q_rd];  c_flip <= q_flip[q_rd];
						c_pal  <= q_pal [q_rd];  c_pri  <= q_pri [q_rd];
						c_x    <= q_x   [q_rd];  c_w    <= q_w   [q_rd];
						c_row  <= q_row [q_rd];  c_ty   <= q_ty  [q_rd];
						c_tl   <= q_tl  [q_rd];  c_misc <= q_misc[q_rd];
						c_k    <= 3'd1;
						q_rd   <= q_rd + 1'b1;
					end else begin
						c_k <= c_k + 3'd1;
						if (c_k == c_w) c_v <= 1'b0;
					end
				end else begin
					c_v <= 1'b0;
				end
			end
		end
	end

	/* verilator lint_off UNUSEDSIGNAL */
	// `mobwr_d[6:4]` is VD6:4 -- the MOB register file takes VD15:7 for the
	// value and VD3:0 for the selector; the three bits between are not wired.
	wire _unused = &{1'b0, mob_yscroll, code_sum[14:12], tile_off[14:12], w3_now[6:4],
	                 mobwr_d[6:4], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
