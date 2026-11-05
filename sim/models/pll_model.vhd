-------------------------------------------------------------------------------
-- pll: simulation model of the Cyclone V clock generator rtl/pll.v
-------------------------------------------------------------------------------
-- Sim-only. The real pll is a Verilog wrapper around altera_pll (rtl/pll.v,
-- rtl/pll/pll_0002.v) and cannot be simulated in GHDL. rtl/replaced/clock.vhd
-- declares pll as a component, so this entity binds to it by default binding.
--
-- The periods below are the frequencies requested from the altera_pll in
-- rtl/pll/pll_0002.v (50 MHz reference, VCO 675 MHz, phase 0, 50 % duty):
--
--   outclk_0  28.125 MHz    675 / 24
--   outclk_1  24.107142 MHz 675 / 28
--   outclk_2  112.5 MHz     675 / 6
--   outclk_3  96.428571 MHz 675 / 7
--
-- Each period is a constant rounded to a whole number of femtoseconds (GHDL's
-- time resolution), with the two periods that clock the clkdiv4 divider
-- (outclk_2, outclk_3) rounded to an even number so their halves are exact:
-- every clk_bus period (= 4 clk_mem periods in the testbench) then comes out
-- exactly 4 x that constant and a testbench can compare against it.
--
-- The outputs run from time zero, all aligned at 0: only `locked` models the
-- start-up (it rises 1 us after the model starts, and rtl/replaced/clock.vhd
-- turns it into ARESET and RESET_MEM).
library IEEE;
use IEEE.std_logic_1164.all;

entity pll is
port (
	refclk   : in  std_logic;
	rst      : in  std_logic;
	outclk_0 : out std_logic := '0';
	outclk_1 : out std_logic := '0';
	outclk_2 : out std_logic := '0';
	outclk_3 : out std_logic := '0';
	locked   : out std_logic := '0'
);
end pll;

architecture model of pll is

constant T_28  : time := 35555556 fs;  -- 28.125 MHz
constant T_24  : time := 41481480 fs;  -- 24.107142 MHz
constant T_112 : time := 8888888 fs;   -- 112.5 MHz
constant T_96  : time := 10370370 fs;  -- 96.428571 MHz

begin

gen28: process
begin
	loop
		outclk_0 <= '1'; wait for T_28 / 2;
		outclk_0 <= '0'; wait for T_28 / 2;
	end loop;
end process;

gen24: process
begin
	loop
		outclk_1 <= '1'; wait for T_24 / 2;
		outclk_1 <= '0'; wait for T_24 / 2;
	end loop;
end process;

gen112: process
begin
	loop
		outclk_2 <= '1'; wait for T_112 / 2;
		outclk_2 <= '0'; wait for T_112 / 2;
	end loop;
end process;

gen96: process
begin
	loop
		outclk_3 <= '1'; wait for T_96 / 2;
		outclk_3 <= '0'; wait for T_96 / 2;
	end loop;
end process;

lock: process
begin
	locked <= '0';
	wait for 1 us;
	locked <= '1';
	wait;
end process;

end model;
