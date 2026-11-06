-------------------------------------------------------------------------------
-- sim model of kg_sdpram (the Verilog rtl/mem/kg_sdpram.sv in the Quartus
-- flow): simple dual-port RAM, one write clock, one registered read clock.
-- memory.vhd uses it for the two video RAMs; its component declaration
-- (rtl/replaced/memory.vhd) is the port list of this entity.
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity kg_sdpram is
generic (
	DW        : integer := 8;
	AW        : integer := 10;
	INIT_FILE : string  := ""
);
port (
	clka  : in  std_logic := '0';
	wea   : in  std_logic := '0';
	addra : in  std_logic_vector(AW - 1 downto 0) := (others => '0');
	dina  : in  std_logic_vector(DW - 1 downto 0) := (others => '0');
	clkb  : in  std_logic := '0';
	enb   : in  std_logic := '0';
	addrb : in  std_logic_vector(AW - 1 downto 0) := (others => '0');
	doutb : out std_logic_vector(DW - 1 downto 0)
);
end kg_sdpram;

architecture rtl of kg_sdpram is
	type mem_t is array (0 to 2**AW - 1) of std_logic_vector(DW - 1 downto 0);
	shared variable mem : mem_t := (others => (others => '0'));
begin
	process (clka)
	begin
		if rising_edge(clka) then
			if wea = '1' then
				mem(to_integer(unsigned(addra))) := dina;
			end if;
		end if;
	end process;

	process (clkb)
	begin
		if rising_edge(clkb) then
			if enb = '1' then
				doutb <= mem(to_integer(unsigned(addrb)));
			end if;
		end if;
	end process;
end rtl;
