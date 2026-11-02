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
--   outclk_0  28.125 MHz   675 / 24
--   outclk_1  24.107142 MHz 675 / 28
--   outclk_2  112.5 MHz    675 / 6
--
-- Each period is a constant rounded to 1 ps, so every generated period is
-- exactly that time and a testbench can compare against it (the periods are
-- whole numbers of picoseconds and their halves whole numbers of femtoseconds,
-- which is GHDL's time resolution).
--
-- The outputs run from time zero: only `locked` models the start-up (it rises
-- 1 us after the model starts, and rtl/replaced/clock.vhd turns it into ARESET).
library IEEE;
use IEEE.std_logic_1164.all;

entity pll is
port (
	refclk   : in  std_logic;
	rst      : in  std_logic;
	outclk_0 : out std_logic := '0';
	outclk_1 : out std_logic := '0';
	outclk_2 : out std_logic := '0';
	locked   : out std_logic := '0'
);
end pll;

architecture model of pll is

constant T_28  : time := 35.555 ns;  -- 28.125 MHz
constant T_24  : time := 41.481 ns;  -- 24.107142 MHz
constant T_112 : time := 8.888 ns;   -- 112.5 MHz

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

lock: process
begin
	locked <= '0';
	wait for 1 us;
	locked <= '1';
	wait;
end process;

end model;
