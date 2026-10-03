`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones: the R-2R DACs RN1/RN2/RN3 and the analogue stage
//  (schematic sheet 10), reduced to 8 bits per channel for MiSTer.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  The colour word (the HC273 40B / 40C outputs):
//      D15      = RGB0     the shared intensity LSB of all three channels
//      D14..D10 = R5..R1
//      D9 ..D5  = G5..G1
//      D4 ..D0  = B5..B1
//  i.e. MAME's IRGB_1555.  The manual's memory map marks D15 "don't care";
//  that is wrong: RGB0 drives the LSB of all three ladders, and most palette
//  words the program writes have D15 set.
//
//  Each channel is a six-bit R-2R ladder whose LSB is the shared RGB0:
//      chan6 = {Cn5..Cn1, RGB0}           0 .. 63
//      chan8 = round(255 * chan6 / 63)
//  The conversion is a 64-entry table below (plain bit replication differs
//  by one LSB on ten codes).
//
//  The pen-zero NORs (30C / 20C F260) fire on Cn5:1 == 0 and pull the channel
//  to black through 7406 open collectors.  RGB0 is not part of the NOR, so
//  Cn5:1 = 0 with RGB0 = 1 is still black.  `BLACK_PULL` models this.
//  Blanking reaches here as all zeros (/BLANK clears the HC273s).
//
//  The two alternative resistor sets drawn in parallel change only the
//  analogue swing, not the digital code.
//============================================================================

module skullxbo_dac #(
	parameter bit BLACK_PULL = 1'b1
)(
	input  logic [15:0] colour,      // the HC273 word
	output logic [7:0]  red,
	output logic [7:0]  green,
	output logic [7:0]  blue
);

	wire       rgb0 = colour[15];
	wire [4:0] r5   = colour[14:10];
	wire [4:0] g5   = colour[9:5];
	wire [4:0] b5   = colour[4:0];

	//     chan8 = round(255 * (Cn5:1 * 2 + RGB0) / 63)
	// enumerated for the 64 six-bit codes.  The cheap bit-replication form
	// ({c6,2'b00} | c6[5:4]) is off by one LSB on ten of the codes, so it is
	// not used.
	function automatic logic [7:0] expand(input logic [4:0] c5,
	                                      input logic       lsb);
		case ({c5, lsb})
			6'd0 : expand = 8'd0;
			6'd1 : expand = 8'd4;
			6'd2 : expand = 8'd8;
			6'd3 : expand = 8'd12;
			6'd4 : expand = 8'd16;
			6'd5 : expand = 8'd20;
			6'd6 : expand = 8'd24;
			6'd7 : expand = 8'd28;
			6'd8 : expand = 8'd32;
			6'd9 : expand = 8'd36;
			6'd10: expand = 8'd40;
			6'd11: expand = 8'd45;
			6'd12: expand = 8'd49;
			6'd13: expand = 8'd53;
			6'd14: expand = 8'd57;
			6'd15: expand = 8'd61;
			6'd16: expand = 8'd65;
			6'd17: expand = 8'd69;
			6'd18: expand = 8'd73;
			6'd19: expand = 8'd77;
			6'd20: expand = 8'd81;
			6'd21: expand = 8'd85;
			6'd22: expand = 8'd89;
			6'd23: expand = 8'd93;
			6'd24: expand = 8'd97;
			6'd25: expand = 8'd101;
			6'd26: expand = 8'd105;
			6'd27: expand = 8'd109;
			6'd28: expand = 8'd113;
			6'd29: expand = 8'd117;
			6'd30: expand = 8'd121;
			6'd31: expand = 8'd125;
			6'd32: expand = 8'd130;
			6'd33: expand = 8'd134;
			6'd34: expand = 8'd138;
			6'd35: expand = 8'd142;
			6'd36: expand = 8'd146;
			6'd37: expand = 8'd150;
			6'd38: expand = 8'd154;
			6'd39: expand = 8'd158;
			6'd40: expand = 8'd162;
			6'd41: expand = 8'd166;
			6'd42: expand = 8'd170;
			6'd43: expand = 8'd174;
			6'd44: expand = 8'd178;
			6'd45: expand = 8'd182;
			6'd46: expand = 8'd186;
			6'd47: expand = 8'd190;
			6'd48: expand = 8'd194;
			6'd49: expand = 8'd198;
			6'd50: expand = 8'd202;
			6'd51: expand = 8'd206;
			6'd52: expand = 8'd210;
			6'd53: expand = 8'd215;
			6'd54: expand = 8'd219;
			6'd55: expand = 8'd223;
			6'd56: expand = 8'd227;
			6'd57: expand = 8'd231;
			6'd58: expand = 8'd235;
			6'd59: expand = 8'd239;
			6'd60: expand = 8'd243;
			6'd61: expand = 8'd247;
			6'd62: expand = 8'd251;
			6'd63: expand = 8'd255;
			default: expand = 8'd0;
		endcase
	endfunction

	wire [7:0] r8 = expand(r5, rgb0);
	wire [7:0] g8 = expand(g5, rgb0);
	wire [7:0] b8 = expand(b5, rgb0);

	assign red   = (BLACK_PULL && (r5 == 5'd0)) ? 8'd0 : r8;
	assign green = (BLACK_PULL && (g5 == 5'd0)) ? 8'd0 : g8;
	assign blue  = (BLACK_PULL && (b5 == 5'd0)) ? 8'd0 : b8;

endmodule
