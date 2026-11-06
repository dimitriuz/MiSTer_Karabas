-------------------------------------------------------------------------------
-- sdram_nowait: the Stage 2 no-wait SDRAM controller
-------------------------------------------------------------------------------
-- RED stub: the entity only, so sim/tb_sdram_nowait.vhd elaborates and shows
-- the tests it runs against a controller that does nothing. The real body
-- follows in the next commit.
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity sdram_nowait is
port (
	clk_mem   : in  std_logic;
	reset     : in  std_logic;
	bus_phase : in  std_logic_vector(1 downto 0);
	ready     : out std_logic;

	cpu_reset_n : in std_logic;
	cpu_ena   : in  std_logic;
	cpu_ts    : in  std_logic_vector(2 downto 0);
	cpu_mc    : in  std_logic_vector(2 downto 0);
	cpu_mreq_n : in std_logic;
	cpu_rd_n   : in std_logic;
	cpu_wr_n   : in std_logic;
	cpu_iorq_n : in std_logic;
	cpu_addr  : in  std_logic_vector(20 downto 0);
	cpu_wr_en : in  std_logic;
	cpu_din   : in  std_logic_vector(7 downto 0);
	cpu_dout  : out std_logic_vector(7 downto 0);

	b_req   : in  std_logic;
	b_we    : in  std_logic;
	b_addr  : in  std_logic_vector(20 downto 0);
	b_din   : in  std_logic_vector(7 downto 0);
	b_dout  : out std_logic_vector(7 downto 0);
	b_done  : out std_logic;
	b_overrun : out std_logic;

	sd_ba  : out std_logic_vector(1 downto 0);
	sd_a   : out std_logic_vector(12 downto 0);
	sd_dqm : out std_logic_vector(1 downto 0);
	sd_ras_n, sd_cas_n, sd_we_n : out std_logic;
	sd_dq  : inout std_logic_vector(15 downto 0)
);
end sdram_nowait;

architecture rtl of sdram_nowait is
begin
	ready     <= '0';
	cpu_dout  <= (others => '0');
	b_dout    <= (others => '0');
	b_done    <= '0';
	b_overrun <= '0';
	sd_ba   <= (others => '0');
	sd_a    <= (others => '0');
	sd_dqm  <= (others => '0');
	sd_ras_n <= '1';
	sd_cas_n <= '1';
	sd_we_n  <= '1';
	sd_dq    <= (others => 'Z');
end rtl;
