-------------------------------------------------------------------------------
-- clkgate: a clock that only runs while the enable is set (the Cyclone V BUFGCE)
-------------------------------------------------------------------------------
-- Replaces the Xilinx BUFGCE of upstream src/rtl/clock/clock.vhd, which clocks the
-- video chain with the pixel enable: instead of every rising edge of clk_bus, the
-- downstream logic sees one clock per enabled cycle.
--
-- The enable is sampled on the falling edge of clk, so the register only ever changes
-- while clk is low and gclk = clk and en_r can neither chop a pulse nor produce a
-- glitch: a gated clock pulse always has a full clk high phase. The enable is generated
-- by logic clocked by the rising edge of the same clk (the enable process of clock.vhd),
-- so it is stable for a whole half cycle when it is sampled here.
library IEEE;
use IEEE.std_logic_1164.all;

entity clkgate is
port (
	clk  : in  std_logic;
	en   : in  std_logic;
	gclk : out std_logic
);
end clkgate;

architecture rtl of clkgate is

signal en_r : std_logic := '0';

begin

sample: process (clk)
begin
	if falling_edge(clk) then
		en_r <= en;
	end if;
end process;

gclk <= clk and en_r;

end rtl;
