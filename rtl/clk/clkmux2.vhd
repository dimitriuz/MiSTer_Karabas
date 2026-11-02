-------------------------------------------------------------------------------
-- clkmux2: glitch-free two-clock multiplexer (the Cyclone V BUFGMUX)
-------------------------------------------------------------------------------
-- Replaces the Xilinx BUFGMUX of upstream src/rtl/clock/clock.vhd: the bus clock is
-- clk_28 with DS80 = '0' and clk_24 with DS80 = '1', two frequencies of one PLL, and
-- the machine keeps running through the switch.
--
-- One branch per input clock. The select is sampled twice on the falling edge of the
-- branch's own clock, so it is synchronised to that clock and the sample only ever
-- changes while the clock is low; the branch enable is the second sample, gated by the
-- other branch having turned off, so the two enables are never high at the same time.
-- Both enables only ever change on the falling edge of their own clock, when that clock
-- is low: the gate can neither chop a pulse nor produce a glitch, and a branch that is
-- off simply costs its cycles. The branch that is on passes every cycle.
--
-- Before the select has been sampled the first time, branch 0 is enabled: DS80 resets
-- to '0' in the machine, so the bus clock is there from the first clk0 cycle.
--
-- Quartus binds this component by name; the same clocks are related (one PLL), so the
-- timing closure of the two sample chains is an ordinary synchronous path.
library IEEE;
use IEEE.std_logic_1164.all;

entity clkmux2 is
port (
	clk0    : in  std_logic;  -- the clock selected with sel = '0'
	clk1    : in  std_logic;  -- the clock selected with sel = '1'
	sel     : in  std_logic;
	clk_out : out std_logic
);
end clkmux2;

architecture rtl of clkmux2 is

signal d0, d1 : std_logic := '1';  -- the sel samples, clocked by clk0 ('0' => branch 0)
signal q0, q1 : std_logic := '0';  -- the sel samples, clocked by clk1
signal en0 : std_logic := '1';
signal en1 : std_logic := '0';

begin

branch0: process (clk0)
begin
	if falling_edge(clk0) then
		d0 <= not sel;
		d1 <= d0;
		en0 <= d1 and not en1;
	end if;
end process;

branch1: process (clk1)
begin
	if falling_edge(clk1) then
		q0 <= sel;
		q1 <= q0;
		en1 <= q1 and not en0;
	end if;
end process;

clk_out <= (clk0 and en0) or (clk1 and en1);

end rtl;
