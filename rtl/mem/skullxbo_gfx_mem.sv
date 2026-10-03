`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones SDRAM client arbiter: the 68000 program-ROM word
//  client, the playfield and motion-object stamp byte clients, the MSM6295
//  sample byte client and the download write port, sharing the single
//  skullxbo_sdram controller.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Ported from
//  `Arcade-Badlands_MiSTer/rtl/mem/badlands_gfx_mem.sv` (GPL-3.0, same
//  author; itself from Blasteroids / Xybots / Toobin').  The byte interface
//  and the per-client row buffers are that module's; the CPU-ROM client, the
//  OKI client, the priority order and the refresh watchdog are this core's,
//  because this board serves its program ROM from the same SDRAM.
//
//  SDRAM map:
//    SDRAM byte          size      region     word base   client
//    0x000000-0x07FFFF   512 KB    maincpu    0x000000    cpu  (word, 4-word burst)
//    0x080000-0x11FFFF   640 KB    playfield  0x040000    pf   (byte, 2-word burst)
//    0x120000-0x39FFFF  2560 KB    sprites    0x090000    mo   (byte, 8-word burst)
//    0x3A0000-0x3DFFFF   256 KB    jsa:oki1   0x1D0000    oki  (byte, 4-word burst)
//  The alphanumerics and 6502 ROMs are in block RAM, not here.  Every SDRAM
//  word is {even byte, odd byte}: a byte client takes [15:8] for an even
//  address and [7:0] for an odd one.
//
//  Byte clients.  The board reads one 8-bit stamp ROM at a time, so each
//  graphics client asks for one byte and keeps a small row buffer filled by
//  one burst; only a buffer miss reaches the SDRAM.  skullxbo_rom_loader lays
//  the graphics out so that one hardware fetch is one aligned group:
//    * playfield: a 4-byte group per (bank, code, row) holding both halves
//      of both ROM columns;
//    * sprites: a 16-byte group per (bank, code, row) holding all five
//      planes of both halves, so one 8-word burst delivers a whole 16-dot
//      slice.
//  The whole group is also output (`pf_group`, `mo_group`) so a client can
//  take every byte of a wide fetch from one transaction.  The OKI reads
//  single ADPCM bytes (about one per scanline).  The 68000 asks for a 4-word
//  cache line, passed through on consecutive `cpu_valid` pulses with
//  `cpu_last` on the fourth.
//
//  Protocol.  Byte clients raise `*_req` with the address and hold both;
//  `*_ack` is a one-clk_sys pulse with `*_data` valid (and held until the
//  next ack); the client then drops `*_req`.  One request = one transaction.
//  The CPU raises `cpu_req` with `cpu_addr` / `cpu_blen` and holds it until
//  the `cpu_last` word, then drops it.
//
//  Priority:  download write > PF > MO > CPU program ROM > OKI
//
//  The write port only runs during the download, when nothing reads.  The
//  playfield has the tightest deadline (a fetch every 4 H counts, 32
//  clk_sys) and the motion objects the next (8 H counts), and a late stamp
//  fetch is a visible glitch; a delayed ROM read only costs the 68000 wait
//  states.  So both graphics clients go ahead of the CPU.  A graphics request
//  waits at most for a refresh already started, a transaction already in
//  flight and, for MO, one playfield fill.
//
//  Refresh.  `rfsh_ok` is high only while no client is asking and the
//  arbiter is idle.  A refresh is deferred, never dropped, and a watchdog
//  forces the window open after RFSH_DEFER_MAX clk_sys (512 clk = 8.9 us,
//  well inside the part's refresh budget), so continuous demand cannot
//  starve it.
//============================================================================

module skullxbo_gfx_mem #(
	parameter int AW = 24,
	// word bases of the regions (see the header)
	parameter logic [AW-1:0] PF_BASE  = 24'h040000,   // byte 0x080000
	parameter logic [AW-1:0] MO_BASE  = 24'h090000,   // byte 0x120000
	parameter logic [AW-1:0] OKI_BASE = 24'h1D0000,   // byte 0x3A0000
	// how long a due AUTO_REFRESH may be deferred before the window is forced
	parameter int RFSH_DEFER_MAX = 512
)(
	input  logic          clk,          // clk_sys 57.272727 MHz
	input  logic          reset,

	// ---- 68000 program-ROM word client (skullxbo_prog_rom) ----
	input  logic          cpu_req,
	input  logic [AW-1:0] cpu_addr,     // SDRAM WORD address
	input  logic  [1:0]   cpu_blen,     // words - 1
	output logic          cpu_valid,
	output logic          cpu_last,
	output logic [15:0]   cpu_rdata,

	// ---- playfield stamp byte client ----
	input  logic          pf_req,       // level, HELD with the address
	input  logic [19:0]   pf_addr,      // BYTE offset inside `playfield`, 0..0x9FFFF
	output logic          pf_ack,       // ONE-cycle pulse; pf_data valid in it
	output logic  [7:0]   pf_data,      // HELD until this client's next ack
	output logic [31:0]   pf_group,     // the whole 4-byte group, HELD

	// ---- motion-object stamp byte client ----
	input  logic          mo_req,
	input  logic [21:0]   mo_addr,      // BYTE offset inside `sprites`, 0..0x27FFF9
	output logic          mo_ack,
	output logic  [7:0]   mo_data,
	output logic [127:0]  mo_group,    // the whole 16-byte stamp group, HELD

	// ---- MSM6295 sample byte client ----
	input  logic          oki_req,
	input  logic [17:0]   oki_addr,     // BYTE offset inside `jsa:oki1`, 0..0x3FFFF
	output logic          oki_ack,
	output logic  [7:0]   oki_data,

	// ---- loader write port (WORD address, from skullxbo_sdram_loader) ----
	input  logic          dl_wr,
	input  logic [AW-1:0] dl_waddr,
	input  logic [15:0]   dl_wdata,
	output logic          dl_ack,

	// ---- skullxbo_sdram controller port ----
	output logic          sd_req,
	output logic [AW-1:0] sd_addr,
	output logic          sd_we,
	output logic  [2:0]   sd_blen,
	output logic [15:0]   sd_wdata,
	output logic          rfsh_ok,
	input  logic          sd_ready,
	input  logic          sd_valid,
	input  logic [15:0]   sd_rdata
);

	// ---- the three row buffers -------------------------------------------
	// PF keeps its 4-byte group (2 words), OKI 8 bytes (4 words) and MO the
	// whole 16-byte stamp group (8 words), which is exactly one 16-dot slice.
	logic [15:0] pf_buf  [0:1];   logic [17:0] pf_tag;   logic pf_bufv;
	logic [15:0] mo_buf  [0:7];   logic [17:0] mo_tag;   logic mo_bufv;
	logic [15:0] oki_buf [0:3];   logic [14:0] oki_tag;  logic oki_bufv;

	wire pf_hit  = pf_bufv  && (pf_tag  == pf_addr[19:2]);
	wire mo_hit  = mo_bufv  && (mo_tag  == mo_addr[21:4]);
	wire oki_hit = oki_bufv && (oki_tag == oki_addr[17:3]);

	// ---- per-client request state ----------------------------------------
	typedef enum logic [1:0] { C_IDLE, C_MISS, C_HOLD } cstate_t;
	cstate_t pf_st, mo_st, oki_st;

	// the central FSM raises these for one cycle when a fill completes; the
	// buffer and its tag are updated on the SAME edge.
	logic pf_fill, mo_fill, oki_fill;

	// ---- the central arbiter / SDRAM sequencer ---------------------------
	typedef enum logic [1:0] { G_IDLE, G_REQ, G_WAIT, G_HOLD } gstate_t;
	gstate_t st;

	typedef enum logic [2:0] { OP_WR, OP_CPU, OP_MO, OP_PF, OP_OKI } op_t;
	op_t op;

	logic [2:0]  wcnt;

	wire pf_need  = (pf_st  == C_MISS);
	wire mo_need  = (mo_st  == C_MISS);
	wire oki_need = (oki_st == C_MISS);

	// ---- the refresh window, plus its deferral watchdog -------------------
	localparam int DEFER_W = $clog2(RFSH_DEFER_MAX + 1);
	logic [DEFER_W-1:0] defer;
	wire rfsh_win = (st == G_IDLE) && !dl_wr
	             && !cpu_req && !pf_req && !mo_req && !oki_req
	             && !pf_need && !mo_need && !oki_need;
	assign rfsh_ok = rfsh_win || (defer >= DEFER_W'(RFSH_DEFER_MAX));

	always_ff @(posedge clk) begin
		if (reset)         defer <= '0;
		else if (rfsh_ok)  defer <= '0;
		else if (defer != DEFER_W'(RFSH_DEFER_MAX)) defer <= defer + 1'b1;
	end

	// The playfield goes first when both graphics clients ask (it has the
	// tighter deadline), and both go ahead of the CPU (see the header).
	wire take_pf = pf_need;
	wire take_mo = mo_need && !pf_need;

	// each byte client fetches the aligned group its address falls in:
	// 4 bytes for PF, 8 for OKI, 16 for MO
	wire [AW-1:0] pf_wa  = PF_BASE  + {{(AW-19){1'b0}}, pf_addr[19:2],  1'b0};
	wire [AW-1:0] mo_wa  = MO_BASE  + {{(AW-21){1'b0}}, mo_addr[21:4],  3'b000};
	wire [AW-1:0] oki_wa = OKI_BASE + {{(AW-17){1'b0}}, oki_addr[17:3], 2'b00};

	// The tag is latched with the address the burst was issued for, not read
	// back at fill time, so a client that moved its address mid-transaction
	// cannot mislabel the buffer.
	logic [17:0] pf_tag_l;
	logic [17:0] mo_tag_l;
	logic [14:0] oki_tag_l;

	logic [2:0] blen_l;
	wire  [2:0] wlast = blen_l;

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= G_IDLE; sd_req <= 1'b0; sd_we <= 1'b0; sd_blen <= 3'd0;
			dl_ack <= 1'b0;
			pf_fill <= 1'b0; mo_fill <= 1'b0; oki_fill <= 1'b0;
			pf_bufv <= 1'b0; mo_bufv <= 1'b0; oki_bufv <= 1'b0;
			cpu_valid <= 1'b0; cpu_last <= 1'b0;
			op <= OP_WR; blen_l <= 3'd0;
		end else begin
			dl_ack    <= 1'b0;
			sd_req    <= 1'b0;
			pf_fill   <= 1'b0;
			mo_fill   <= 1'b0;
			oki_fill  <= 1'b0;
			cpu_valid <= 1'b0;
			cpu_last  <= 1'b0;
			case (st)
				// ---- pick a client (write, PF, MO, CPU, OKI)
				G_IDLE: begin
					wcnt <= 3'd0;
					if (dl_wr) begin
						op <= OP_WR; sd_addr <= dl_waddr; sd_we <= 1'b1;
						sd_blen <= 3'd0; blen_l <= 3'd0; sd_wdata <= dl_wdata;
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (take_pf) begin
						op <= OP_PF; sd_addr <= pf_wa; sd_we <= 1'b0;
						sd_blen <= 3'd1; blen_l <= 3'd1;
						pf_tag_l <= pf_addr[19:2];
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (take_mo) begin
						op <= OP_MO; sd_addr <= mo_wa; sd_we <= 1'b0;
						sd_blen <= 3'd7; blen_l <= 3'd7;
						mo_tag_l <= mo_addr[21:4];
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (cpu_req) begin
						op <= OP_CPU; sd_addr <= cpu_addr; sd_we <= 1'b0;
						sd_blen <= {1'b0, cpu_blen}; blen_l <= {1'b0, cpu_blen};
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (oki_need) begin
						op <= OP_OKI; sd_addr <= oki_wa; sd_we <= 1'b0;
						sd_blen <= 3'd3; blen_l <= 3'd3;
						oki_tag_l <= oki_addr[17:3];
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end
				end
				// ---- req asserted for exactly this cycle ----
				G_REQ: begin
					sd_req <= 1'b0; sd_we <= 1'b0;
					st <= G_WAIT;
				end
				// ---- await completion (burst words on consecutive sd_valid) ----
				G_WAIT: begin
					if (op == OP_WR) begin
						if (sd_ready) begin dl_ack <= 1'b1; st <= G_HOLD; end
					end else if (sd_valid) begin
						wcnt <= wcnt + 3'd1;
						case (op)
							OP_CPU: begin
								cpu_rdata <= sd_rdata;
								cpu_valid <= 1'b1;
								if (wcnt == wlast) begin cpu_last <= 1'b1; st <= G_HOLD; end
							end
							OP_MO: begin
								mo_buf[wcnt] <= sd_rdata;
								if (wcnt == wlast) begin
									mo_tag  <= mo_tag_l;
									mo_bufv <= 1'b1;
									mo_fill <= 1'b1;
									st      <= G_HOLD;
								end
							end
							OP_PF: begin
								pf_buf[wcnt[0]] <= sd_rdata;
								if (wcnt == wlast) begin
									pf_tag  <= pf_tag_l;
									pf_bufv <= 1'b1;
									pf_fill <= 1'b1;
									st      <= G_HOLD;
								end
							end
							default: begin   // OP_OKI
								oki_buf[wcnt[1:0]] <= sd_rdata;
								if (wcnt == wlast) begin
									oki_tag  <= oki_tag_l;
									oki_bufv <= 1'b1;
									oki_fill <= 1'b1;
									st       <= G_HOLD;
								end
							end
						endcase
					end
				end
				// ---- one transaction per request: wait for the client to drop it
				G_HOLD: begin
					case (op)
						OP_WR:   if (!dl_wr)           st <= G_IDLE;
						OP_CPU:  if (!cpu_req)         st <= G_IDLE;
						OP_MO:   if (mo_st  != C_MISS) st <= G_IDLE;
						OP_PF:   if (pf_st  != C_MISS) st <= G_IDLE;
						default: if (oki_st != C_MISS) st <= G_IDLE;   // OP_OKI
					endcase
				end
				default: st <= G_IDLE;
			endcase
		end
	end

	// ---- byte selection: EVEN byte address -> D15:8, ODD -> D7:0 ----------
	wire [15:0] pf_w  = pf_buf [pf_addr[1]];
	wire [15:0] mo_w  = mo_buf [mo_addr[3:1]];
	wire [15:0] oki_w = oki_buf[oki_addr[2:1]];
	wire  [7:0] pf_b  = pf_addr[0]  ? pf_w[7:0]  : pf_w[15:8];
	wire  [7:0] mo_b  = mo_addr[0]  ? mo_w[7:0]  : mo_w[15:8];
	wire  [7:0] oki_b = oki_addr[0] ? oki_w[7:0] : oki_w[15:8];

	// ---- the whole group ---------------------------------------------------
	// The row buffer, output whole: byte i is the even lane (D15:8) of word i/2
	// when i is even and the odd lane when it is odd.  Registered with `*_ack`
	// and held like `*_data`.
	wire [31:0] pf_grp_w = { pf_buf[1][7:0], pf_buf[1][15:8],
	                         pf_buf[0][7:0], pf_buf[0][15:8] };
	wire [127:0] mo_grp_w = { mo_buf[7][7:0], mo_buf[7][15:8],
	                          mo_buf[6][7:0], mo_buf[6][15:8],
	                          mo_buf[5][7:0], mo_buf[5][15:8],
	                          mo_buf[4][7:0], mo_buf[4][15:8],
	                          mo_buf[3][7:0], mo_buf[3][15:8],
	                          mo_buf[2][7:0], mo_buf[2][15:8],
	                          mo_buf[1][7:0], mo_buf[1][15:8],
	                          mo_buf[0][7:0], mo_buf[0][15:8] };

	// ---- the three client state machines ---------------------------------
	always_ff @(posedge clk) begin
		if (reset) begin
			pf_st  <= C_IDLE; pf_ack  <= 1'b0; pf_data  <= 8'h00;
			pf_group <= 32'd0;  mo_group <= 128'd0;
			mo_st  <= C_IDLE; mo_ack  <= 1'b0; mo_data  <= 8'h00;
			oki_st <= C_IDLE; oki_ack <= 1'b0; oki_data <= 8'h00;
		end else begin
			pf_ack  <= 1'b0;
			mo_ack  <= 1'b0;
			oki_ack <= 1'b0;

			case (pf_st)
				C_IDLE: if (pf_req) begin
					if (pf_hit) begin
						pf_data  <= pf_b;
						pf_group <= pf_grp_w;
						pf_ack   <= 1'b1;
						pf_st   <= C_HOLD;
					end else pf_st <= C_MISS;
				end
				C_MISS: if (pf_fill) begin
					pf_data  <= pf_b;
					pf_group <= pf_grp_w;
					pf_ack   <= 1'b1;
					pf_st   <= C_HOLD;
				end
				default: if (!pf_req) pf_st <= C_IDLE;      // C_HOLD
			endcase

			case (mo_st)
				C_IDLE: if (mo_req) begin
					if (mo_hit) begin
						mo_data  <= mo_b;
						mo_group <= mo_grp_w;
						mo_ack   <= 1'b1;
						mo_st   <= C_HOLD;
					end else mo_st <= C_MISS;
				end
				C_MISS: if (mo_fill) begin
					mo_data  <= mo_b;
					mo_group <= mo_grp_w;
					mo_ack   <= 1'b1;
					mo_st   <= C_HOLD;
				end
				default: if (!mo_req) mo_st <= C_IDLE;      // C_HOLD
			endcase

			case (oki_st)
				C_IDLE: if (oki_req) begin
					if (oki_hit) begin
						oki_data <= oki_b;
						oki_ack  <= 1'b1;
						oki_st   <= C_HOLD;
					end else oki_st <= C_MISS;
				end
				C_MISS: if (oki_fill) begin
					oki_data <= oki_b;
					oki_ack  <= 1'b1;
					oki_st   <= C_HOLD;
				end
				default: if (!oki_req) oki_st <= C_IDLE;    // C_HOLD
			endcase
		end
	end

endmodule
