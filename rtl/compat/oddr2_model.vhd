-- Quartus 17 stand-in for the Xilinx Spartan-6 ODDR2 primitive, for the elab gate
-- (tools/elab_upstream.sh) only: upstream's own memory.vhd (kept in the elab
-- profile) drives the SRAM /WE through one since 2026-11-20. The core profile
-- replaces that memory.vhd, so nothing in the Karabas MiSTer build uses it.
-- Q follows D0 after a rising C0 and D1 after a rising C1 (the DDR output
-- register); the S/R/CE pins and the INIT/SRTYPE generics are accepted and
-- ignored beyond a synchronous reset to INIT.
library IEEE;
use IEEE.std_logic_1164.all;

entity ODDR2 is
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
end ODDR2;

architecture model of ODDR2 is
	signal q0, q1 : std_logic := to_stdulogic(INIT);
	signal sel    : std_logic := '0';
begin
	process (C0)
	begin
		if rising_edge(C0) then
			if R = '1' then q0 <= '0'; elsif S = '1' then q0 <= '1'; elsif CE = '1' then q0 <= D0; end if;
		end if;
	end process;
	process (C1)
	begin
		if rising_edge(C1) then
			if R = '1' then q1 <= '0'; elsif S = '1' then q1 <= '1'; elsif CE = '1' then q1 <= D1; end if;
		end if;
	end process;
	-- the output switches to the C0 half while C0 is high and to the C1 half otherwise
	Q <= q0 when C0 = '1' else q1;
end model;
