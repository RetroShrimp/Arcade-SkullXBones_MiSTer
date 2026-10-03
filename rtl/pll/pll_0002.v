`timescale 1ns/10ps
//============================================================================
//  Skull & Crossbones core PLL: Altera PLL (Cyclone V fPLL), hand-parameterised.
//  The same PLL as the Vindicators and Bad Lands cores (same clk_sys).
//
//  Adapted from the Toobin' core's rtl/pll/pll_0002.v (same megafunction
//  instantiation, different counters) rather than re-running the MegaWizard,
//  so the parameters are readable here.
//
//  refclk = CLK_50M (FPGA_CLK1_50, 50.000000 MHz)
//
//  outclk_0 = clk_sys  = 57.272727 MHz = 50 x 63 / 5 / 11
//      M = 63, N = 5  -> VCO = 630.000 MHz (the Cyclone V fPLL VCO range is
//      600..1600 MHz, so 630 MHz is legal on this speed grade; the fitter's
//      PLL Summary confirms the counters).
//      C = 11 -> 630 / 11 = 57.272727... MHz.
//      Target is 4 x the 14.318181 MHz board crystal = 57.272724 MHz; the
//      error is +3.3 Hz = 0.06 ppm.  Every game rate is an integer division:
//        /4 = 14.318181 MHz (pixel)    /8 = 7.159091 MHz (68000)
//        /16 = 3.579545 MHz (YM2151)   /32 = 1.789772 MHz (JSA 6502)
//
//  outclk_1 = clk_sdram = the same 57.272727 MHz, phase-shifted, for the
//      SDRAM_CLK pin.  The Cyclone V fPLL shifts in VCO/8 = 198.41 ps steps
//      (88 taps per period); Quartus rejects any other value and any negative
//      one.  The shift is +13095 ps = tap 66 = 270 degrees, from the
//      Vindicators core's hardware sweep at this clock (good window 225-315
//      degrees).  On this core 225, 245.5, 270 and 294.5 degrees were all
//      clean on hardware, and 270 is kept.
//============================================================================

module  pll_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'  -- clk_sys, 57.272727 MHz
	output wire outclk_0,

	// interface 'outclk1'  -- SDRAM_CLK, 57.272727 MHz, +13095 ps = tap 66 = 270 deg (see the header)
	output wire outclk_1,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(2),
		.output_clock_frequency0("57.272727 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("57.272727 MHz"),
		.phase_shift1("13095 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("0 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule
