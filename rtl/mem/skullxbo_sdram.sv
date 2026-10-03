`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones SDRAM controller for the MiSTer SDRAM module.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Ported from
//  `Arcade-Badlands_MiSTer/rtl/mem/badlands_sdram.sv` (GPL-3.0, same
//  author), itself from Xybots / Toobin' and ultimately a SystemVerilog
//  re-implementation of the Arcade-Atari-system1 `sdram.vhd` command and
//  mode encoding.  The state machine is the Bad Lands one: both cores run
//  clk_sys at 57.272727 MHz, so every timing constant is unchanged.
//
//  Target part: MT48LC16M16A2-class, 4 banks x 13-bit row x 9-bit column
//  x16, CL2, READ/WRITE with auto-precharge, AUTO_REFRESH while idle.
//
//  Bursting: a controller that precharges after every random 16-bit read
//  cannot keep up with the four clients; more words per row activate is the
//  only lever.  All four clients burst:
//
//    program ROM cache     4 words (blen = 3), one cache line
//    playfield stamps      2 words (blen = 1), one 4-byte group
//    motion-object stamps  8 words (blen = 7), the whole 10-byte stamp slice
//    MSM6295 samples       4 words (blen = 3)
//
//  `rfsh_ok`: an AUTO_REFRESH may only start while it is high.  Tied to 1
//  this is the sibling cores' controller exactly; skullxbo_gfx_mem drives it
//  from "no client is asking".  `ready` is gated by `rfsh_req & rfsh_ok`, not
//  `rfsh_req` alone, so a refresh that is due but not yet allowed does not
//  also stall the clients.
//
//  Host interface: when `ready` is high, pulse `req` for one cycle with
//  addr / we / wdata / blen.  `ready` drops during the access.  Read data
//  returns on `rdata` with one `valid` pulse per word, in address order.  A
//  request that coincides with a due refresh is latched and served after it.
//  `addr` is a 16-bit word address {BA[1:0], ROW[12:0], COL[8:0]}; `blen` is
//  words - 1 (0/1/3/7).  A burst must not cross a 512-word row (every
//  client's group is aligned).  Writes are always single-word.
//
//  Reset must be ~pll_locked only, never the game reset: `reset` drives
//  SDRAM_CKE, and a reset during the ROM download would restart the 200 us
//  init and silently lose every word already written.
//
//  SDRAM_CLK is driven in Arcade-SkullXBones.sv from a phase-shifted PLL
//  output.  Read data is captured open-loop at bcyc >= CL+1, so whether it
//  arrives in time depends on the board, the module and that phase; timing
//  analysis and simulation cannot check it.  The shipped phase was swept on
//  hardware.
//
//  Timing at 57.272727 MHz (17.4603 ns).  Minimum delays round up; the
//  refresh interval rounds down.
//
//    tINIT  200 us  -> 11455 clk   power-up wait
//    tRFC    66 ns  ->     4 clk   AUTO_REFRESH cycle time
//    tRC     60 ns  ->     4 clk   ACTIVE -> ACTIVE, same bank
//    tRCD    18 ns  ->     2 clk   ACTIVE -> READ/WRITE
//    tRP     18 ns  ->     2 clk   PRECHARGE recovery
//    tMRD    12 ns  ->     1 clk   LOAD MODE -> next command
//    tREFI 7.8 us   ->   446 clk   AUTO_REFRESH interval
//    CL             =     2 clk    read latency
//
//  tRC needs no counter: the shortest ACTIVE-to-ACTIVE path (a single write)
//  is 6 clk.
//
//  Transaction lengths in clk_sys from leaving S_IDLE:
//    burst-8 read : ACT 1 + tRCD 2 + BURST 11 + tRP 2 = 16 ; words at +8..+15
//    burst-4 read : ACT 1 + tRCD 2 + BURST 7  + tRP 2 = 12 ; words at +8..+11
//    burst-2 read : ACT 1 + tRCD 2 + BURST 5  + tRP 2 = 10 ; words at +8, +9
//    single word  : ACT 1 + tRCD 2 + RD/WR 1  + tRP 2 =  6
//    refresh      : REF 1 + tRFC 4                    =  5
//
//  Two things that look like bugs but are not:
//    * `rfsh_req` is set by the interval counter and cleared by S_IDLE in the
//      same always_ff.  If they collide the clear wins, but S_IDLE is entering
//      S_REF at that moment, so the refresh still happens.
//    * `ready` uses the old `rfsh_req`, so a host can pulse `req` in the cycle
//      a refresh becomes due; the `pending` latch catches that request.
//
//  Command, address and write-data pins are registered, so each is a clean
//  register-to-pin path that Quartus packs into the I/O registers (the
//  combinational path misses setup against the shifted SDRAM_CLK).  Read
//  capture is one cycle later to match.  The address and bank registers hold
//  their value on cycles with no address, which the chip ignores, to reduce
//  pin switching.
//============================================================================

module skullxbo_sdram #(
	parameter int CLK_KHZ  = 57273,   // controller clock in kHz
	parameter int ROW_BITS = 13,
	parameter int COL_BITS = 9
) (
	input  logic        clk,
	input  logic        reset,        // MUST be ~pll_locked only (see header)

	// ---- host word port ----
	input  logic [ROW_BITS+COL_BITS+1:0] addr,
	input  logic [15:0] wdata,
	input  logic        we,
	input  logic [2:0]  blen,         // read burst: words-1 (0/1/3/7)
	input  logic        req,
	output logic [15:0] rdata,
	output logic        valid,
	output logic        ready,

	// ---- refresh permission (see the header) ----
	// An AUTO_REFRESH may only start while this is high.
	input  logic        rfsh_ok,

	// ---- SDRAM chip pins (SDRAM_CLK is driven in Arcade-SkullXBones.sv) ----
	inout  wire  [15:0] SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic [1:0]  SDRAM_BA,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_CKE,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nWE
);

// ---- timing, in clk cycles (see the header table) ---------------------------
// CLK_KHZ is cycles per millisecond, so ns -> cycles is  ns * CLK_KHZ / 1e6
// and us -> cycles is  us * CLK_KHZ / 1e3.  Written that way to keep every
// intermediate product inside a 32-bit int (200000 * 57273 would not fit).
localparam int tINIT = (   200*CLK_KHZ +     999) /    1000;   // 200 us, ceil
localparam int tRFC  = (    66*CLK_KHZ +  999999) / 1000000;   //  66 ns, ceil
localparam int tRCD  = (    18*CLK_KHZ +  999999) / 1000000;   //  18 ns, ceil
localparam int tRP   = (    18*CLK_KHZ +  999999) / 1000000;   //  18 ns, ceil
localparam int tMRD  = (    12*CLK_KHZ +  999999) / 1000000;   //  12 ns, ceil
localparam int tREFI_RAW = (7800*CLK_KHZ) / 1000000;           // 7.8 us, floor
localparam int tREFI = (tREFI_RAW > 0) ? tREFI_RAW : 1;
localparam logic [15:0] tREFI_LAST = 16'(tREFI - 1);
localparam int CL = 2;

localparam logic [3:0] CMD_LMR=4'b0000, CMD_REFRESH=4'b0001, CMD_PRECHARGE=4'b0010,
                       CMD_ACTIVE=4'b0011, CMD_WRITE=4'b0100, CMD_READ=4'b0101,
                       CMD_NOP=4'b0111;
// mode register: burst length 1, sequential, CL=2, standard operation, single write
localparam logic [12:0] MODE_REG = {3'b000, 1'b1, 2'b00, 3'b010, 1'b0, 3'b000};

localparam int AW     = ROW_BITS + COL_BITS + 2;
localparam int BA_HI  = AW-1,  BA_LO  = AW-2;
localparam int ROW_HI = COL_BITS + ROW_BITS - 1, ROW_LO = COL_BITS;

typedef enum logic [3:0] {
	S_INIT, S_PRE, S_TRP_I, S_REFI, S_TRC_I, S_MRD, S_TMRD,
	S_IDLE, S_ACT, S_TRCD, S_BURST, S_WR, S_RECOV, S_REF, S_TRC
} state_t;
state_t state;

logic [15:0] dly;
logic [3:0]  ref_init;
logic [15:0] rfsh_ctr;
logic        rfsh_req;

logic           we_l;
logic [15:0]    wdata_l;
logic [AW-1:0]  addr_l;
logic [2:0]     blen_l;
logic [3:0]     bcyc;             // burst cycle: READs at 0..blen_l, data at CL+1..
logic           pending;          // a captured request awaiting service

// ---- combinational command / address / DQ-OE from the single-cycle states ----
logic [3:0]  cmd;
logic [12:0] a_comb;
logic [1:0]  ba_comb;
logic        dq_oe;

// Column address on A; A10 = auto-precharge.  COL_BITS<=9 so the column sits in
// A[8:0] and A10 is free.  Built as one concatenation (iverilog mishandles
// partial bit-selects inside always_comb).  A10 asserts only on the LAST read of
// a burst so the row stays open for the intermediate reads; writes enter S_WR
// with bcyc==0 and blen_l==0 and so always auto-precharge.
wire [COL_BITS-1:0] col_cur  = addr_l[COL_BITS-1:0] + {{(COL_BITS-4){1'b0}}, bcyc};
wire                ap_last  = (bcyc == {1'b0, blen_l});
wire [12:0] col_a = {2'b00, ap_last, {(10-COL_BITS){1'b0}}, col_cur};
localparam logic [12:0] PRE_ALL = 13'h0400; // A10=1 = precharge all banks

// Pre-extracted as continuous-assign wires; iverilog mishandles constant
// part-selects inside always_* blocks (drives "all bits").
wire [1:0]           ba_w  = addr_l[BA_HI:BA_LO];
wire [ROW_BITS-1:0]  row_w = addr_l[ROW_HI:ROW_LO];
wire [12:0]          row_a = {{(13-ROW_BITS){1'b0}}, row_w};

always_comb begin
	cmd = CMD_NOP; a_comb = '0; ba_comb = '0; dq_oe = 1'b0;
	case (state)
		S_PRE:  begin cmd = CMD_PRECHARGE; a_comb = PRE_ALL; end
		S_REFI: cmd = CMD_REFRESH;
		S_MRD:  begin cmd = CMD_LMR; a_comb = MODE_REG; end
		S_ACT:  begin cmd = CMD_ACTIVE; ba_comb = ba_w; a_comb = row_a; end
		S_BURST: if (bcyc <= {1'b0, blen_l}) begin cmd = CMD_READ; ba_comb = ba_w; a_comb = col_a; end
		S_WR:   begin cmd = CMD_WRITE; ba_comb = ba_w; a_comb = col_a; dq_oe = 1'b1; end
		S_REF:  cmd = CMD_REFRESH;
		default: ;
	endcase
end

logic [3:0]  cmd_r;  logic [12:0] a_r;  logic [1:0] ba_r;
logic        dqoe_r; logic [15:0] wdata_r;

// `cmd_r` keeps its reset: a clear ALONE is packable into an I/O register.
wire cmd_has_addr = (cmd == CMD_PRECHARGE) || (cmd == CMD_LMR)
                 || (cmd == CMD_ACTIVE)    || (cmd == CMD_READ)
                 || (cmd == CMD_WRITE);

always_ff @(posedge clk) begin
	if (reset) begin cmd_r <= CMD_NOP; dqoe_r <= 1'b0; end
	else       begin cmd_r <= cmd;     dqoe_r <= dq_oe; end
	if (cmd_has_addr) begin a_r <= a_comb; ba_r <= ba_comb; end
	wdata_r <= wdata_l;
end

assign SDRAM_CKE = ~reset;
assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd_r;
assign SDRAM_A   = a_r;
assign SDRAM_BA  = ba_r;
assign SDRAM_DQ  = dqoe_r ? wdata_r : 16'hzzzz;
assign {SDRAM_DQMH, SDRAM_DQML} = 2'b00;
// A due refresh only blocks the host while it is also permitted; otherwise a
// refresh waiting for permission would stall the clients it is waiting for.
assign ready     = (state == S_IDLE) && !(rfsh_req && rfsh_ok) && !pending;

// helper: wait state that decrements dly, jumps to NEXT when it hits 0.
`define SXB_SDRAM_WAIT(NEXT) begin if (dly != 0) dly <= dly - 1'b1; else state <= NEXT; end

always_ff @(posedge clk) begin
	valid <= 1'b0;

	if (state != S_INIT && state != S_PRE && state != S_TRP_I &&
	    state != S_REFI && state != S_TRC_I && state != S_MRD && state != S_TMRD) begin
		if (rfsh_ctr >= tREFI_LAST) begin rfsh_ctr <= '0; rfsh_req <= 1'b1; end
		else rfsh_ctr <= rfsh_ctr + 1'b1;
	end

	if (reset) begin
		state <= S_INIT; dly <= tINIT[15:0]; ref_init <= '0;
		rfsh_ctr <= '0; rfsh_req <= 1'b0; pending <= 1'b0;
	end else begin
		case (state)
		// ---- power-up init ----
		S_INIT:  begin if (dly != 0) dly <= dly - 1'b1; else state <= S_PRE; end
		S_PRE:   begin state <= S_TRP_I; dly <= tRP[15:0]-1'b1; end
		S_TRP_I: begin if (dly != 0) dly <= dly-1'b1; else begin state <= S_REFI; ref_init <= '0; end end
		S_REFI:  begin state <= S_TRC_I; dly <= tRFC[15:0]-1'b1; end
		S_TRC_I: begin if (dly != 0) dly <= dly-1'b1;
		               else if (ref_init == 4'd7) state <= S_MRD;
		               else begin ref_init <= ref_init + 1'b1; state <= S_REFI; end end
		S_MRD:   begin state <= S_TMRD; dly <= tMRD[15:0]-1'b1; end
		S_TMRD:  `SXB_SDRAM_WAIT(S_IDLE)

		// ---- normal operation ----
		S_IDLE: begin
			// Capture an incoming request so a coincident refresh cannot drop it.
			if (req && !pending) begin
				we_l <= we; wdata_l <= wdata; addr_l <= addr; pending <= 1'b1;
				blen_l <= we ? 3'd0 : blen;          // writes are always single-word
			end
			if (rfsh_req && rfsh_ok) begin state <= S_REF; rfsh_req <= 1'b0; end
			else if (pending || req) begin pending <= 1'b0; state <= S_ACT; end
		end
		S_ACT:   begin state <= S_TRCD; dly <= tRCD[15:0]-1'b1; end
		S_TRCD:  begin if (dly != 0) dly <= dly-1'b1; else begin state <= we_l ? S_WR : S_BURST; bcyc <= 4'd0; end end
		// READ commands issue at bcyc 0..blen_l (the registered outputs shift them
		// one clk); each word's DQ is captured CL+1 cycles after its READ, i.e. at
		// bcyc CL+1 .. CL+1+blen_l, on consecutive `valid` pulses.
		S_BURST: begin
			bcyc <= bcyc + 4'd1;
			if (bcyc >= 4'(CL+1)) begin rdata <= SDRAM_DQ; valid <= 1'b1; end
			if (bcyc == (4'(CL+1) + {1'b0, blen_l})) begin state <= S_RECOV; dly <= tRP[15:0]-1'b1; end
		end
		S_WR:    begin state <= S_RECOV; dly <= tRP[15:0]-1'b1; end
		S_RECOV: `SXB_SDRAM_WAIT(S_IDLE)
		S_REF:   begin state <= S_TRC; dly <= tRFC[15:0]-1'b1; end
		S_TRC:   `SXB_SDRAM_WAIT(S_IDLE)
		default: state <= S_IDLE;
		endcase
	end
end

`undef SXB_SDRAM_WAIT

endmodule
