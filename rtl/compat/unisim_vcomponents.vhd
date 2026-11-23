-- Quartus 17 library stub: the vendored vendor-library package `vcomponents`
-- (Xilinx Unisim/Virtex primitive component declarations, referenced by some
-- converted modules) is not present when those libraries are not compiled, and
-- Quartus 17 aborts analysis on the reference. Upstream Vivado builds get it for
-- free; here it is provided as an EMPTY package compiled into library `unisim`
-- (added to the project with -library unisim). Result of the stage-1 spike
-- (docs/superpowers/plans/stage1-assets/compize_proto.py run); nothing in the
-- pinned upstream instantiates a component from this package, except the ODDR2
-- of the Spartan-6 SRAM /WE (upstream memory.vhd, 2026-11-20), declared below; its
-- entity for the elab gate is rtl/compat/oddr2_model.vhd.
library IEEE;
use IEEE.std_logic_1164.all;
package vcomponents is
	component ODDR2
	generic (
		DDR_ALIGNMENT : string := "NONE";
		INIT          : bit    := '0';
		SRTYPE        : string := "SYNC"
	);
	port (
		Q  : out std_logic;
		C0 : in  std_logic;
		C1 : in  std_logic;
		CE : in  std_logic := '1';
		D0 : in  std_logic;
		D1 : in  std_logic;
		R  : in  std_logic := '0';
		S  : in  std_logic := '0'
	);
	end component;
end package vcomponents;
