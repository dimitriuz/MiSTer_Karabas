-- Replaces upstream src/rtl/clock/clock.vhd @ 01dcd6c (tools/upstream-pins.txt); keep the enable logic identical.
-------------------------------------------------------------------------------
-- Clocks
-------------------------------------------------------------------------------
-- Only the clock generation changes from the Xilinx original: the entity and its port
-- list are upstream's (the unisim library is simply gone) and so is every enable below
-- the ARESET line, which the machine is built around.
--
--   kg_pll  (IBUFG + PLL_BASE + BUFG) -> pll     (rtl/pll.v: one altera_pll, VCO 675
--                                                  MHz on the 50 MHz MiSTer clock)
--   BUFGMUX                           -> clkmux2 (rtl/clk/clkmux2.vhd)
--   BUFGCE                            -> clkgate (rtl/clk/clkgate.vhd)
--
-- The three outputs of that PLL are 28.125 MHz (the bus of the 40-column mode),
-- 24.107142 MHz (the bus of the 80-column DS80 mode) and 112.5 MHz, all with phase 0.
-- The sdc cuts clk_bus <-> clk_sdr as asynchronous, so every path between them must
-- go through a cdc_fifo (as the SDRAM bridge and the video CDC do). What the
-- Xilinx PLL gave and this one does not:
--
--   clk_gs  = clk_28, not a second 28.125 MHz PLL output of the same frequency and
--             phase; it stays out of the bus mux, the General Sound part of the machine
--             runs at 28 MHz in both video modes
--   clk_sdr = 112.5 MHz, not the 84.375 MHz of the Xilinx PLL: the SDRAM bridge of this
--             port is clocked at 112.5 MHz
--   clk_12, clk_8 = '0': profi.vhd has both declarations commented out and routes them
--             only to the MIDI clock and the FT812 clock pin drivers of the
--             karabas_go/mini tops, which this port does not use
--
-- clk_adc carries the pixel enable instead of the bus clock: a MiSTer core clocks its
-- video chain with one clock, so what it needs is the enable that the gated clk_rgb runs
-- on (profi.vhd: ADC_CLK <= clk_adc).
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.conv_integer;
use IEEE.numeric_std.all;
-- std_logic_unsigned for the "+" of the two counters below, not `all`: with all of it
-- visible, GHDL cannot choose between its "=" and std_logic_1164's for the
-- `turbo = "11"` comparisons of the enable logic (Quartus resolves them to
-- std_logic_1164's, and for these operands both are plain equality of the vectors).
use IEEE.std_logic_unsigned."+";

entity clock is
port (
	CLK			: in std_logic;
	DS80			: in std_logic;
	
	CLK_BUS		: buffer std_logic; -- 28 / 24
	CLK_8			: buffer std_logic; -- 8 (the FDC, the FT812 clock output)
	CLK_GS		: buffer std_logic; -- 28 in both video modes (General Sound)
	CLK_SDR		: buffer std_logic; -- 84 (sdram)
	CLK_12      : buffer std_logic; -- 12
	CLK_RGB 		: buffer std_logic; -- 7 / 12
	CLK_VGA		: buffer std_logic; -- 28 / 24
	CLK_ADC		: buffer std_logic;
	
	ENA_DIV2		: buffer std_logic; -- 14 p
	ENA_DIV4		: buffer std_logic; -- 7 p
	ENA_DIV8		: buffer std_logic; -- 3.5 p 
	ENA_DIV16   : buffer std_logic; -- 1.75 p

	ENA_DIV2N	: buffer std_logic; -- 14 n
	ENA_DIV4N	: buffer std_logic; -- 7 n
	ENA_DIV8N	: buffer std_logic; -- 3.5 n
	ENA_DIV16N  : buffer std_logic; -- 1.75 n
	
	ENA_CPU 		: buffer std_logic; -- 3.5/7/14/28 / 3/6/12/24
	ENA_CPU_N	: buffer std_logic;
	ENA_RGB 		: buffer std_logic; -- 7/12
	
	CE_14			: buffer std_logic;
	CE_8			: buffer std_logic; -- 8 MHz on average (SAA1099)
	
	TURBO			: in std_logic_vector(1 downto 0);
	WAIT_CPU		: in std_logic;
	ARESET 		: out std_logic
);
end clock;

architecture rtl of clock is

signal ena_cnt : std_logic_vector(5 downto 0) := "000000";
signal locked : std_logic := '0';
signal clk_28, clk_24 : std_logic;
signal clk_112 : std_logic;
signal clk_bus_i, clk_rgb_i : std_logic;  -- the mux and the gate, wired to the buffer ports
signal acc8 : std_logic_vector(16 downto 0) := (others => '0');

-- The Cyclone V units, declared as components rather than instantiated as
-- `entity work.`: Quartus 17 cannot bind a VHDL direct entity instantiation to a Verilog
-- module, and pll (rtl/pll.v) is Verilog. In the GHDL testbench the entity `pll` of
-- sim/models/pll_model.vhd binds to the component by default binding.
component pll is
port (
	refclk   : in  std_logic;
	rst      : in  std_logic;
	outclk_0 : out std_logic; -- 28.125
	outclk_1 : out std_logic; -- 24.107
	outclk_2 : out std_logic; -- 112.5
	locked   : out std_logic
);
end component;

component clkmux2 is
port (
	clk0    : in  std_logic;
	clk1    : in  std_logic;
	sel     : in  std_logic;
	clk_out : out std_logic
);
end component;

component clkgate is
port (
	clk  : in  std_logic;
	en   : in  std_logic;
	gclk : out std_logic
);
end component;

begin

-- 50 MHz -> 28.125, 24.107142, 112.5 MHz (rtl/pll.v: one altera_pll, VCO 675 MHz, the
-- counters resolved by Quartus at build time). The sdc cuts clk_bus <-> clk_sdr as
-- asynchronous, so every path between them must go through a cdc_fifo (as the SDRAM
-- bridge and the video CDC do).
U2: pll port map (
	refclk   => CLK,
	rst      => '0',
	outclk_0 => clk_28,
	outclk_1 => clk_24,
	outclk_2 => clk_112,
	locked   => locked
);
CLK_GS  <= clk_28;
CLK_SDR <= clk_112;

U9 : clkmux2 port map (clk0 => clk_28, clk1 => clk_24, clk_out => clk_bus_i, sel => ds80);
U10: clkgate port map(clk => clk_bus_i, gclk => clk_rgb_i, en => ena_rgb);
clk_bus <= clk_bus_i;
clk_rgb <= clk_rgb_i;
clk_vga <= clk_bus;
clk_adc <= ena_rgb; -- the pixel enable, not a clock: see the note at the top
clk_12 <= '0';
clk_8 <= '0';

ARESET <= not locked;

-- 8 MHz clock enable on clk_bus for the SAA1099 (8 MHz is its clock in the SAM Coupe): a phase accumulator,
-- 8 / 28.125 * 2^16 = 18641, 8 / 24.107 * 2^16 = 21748 (7.99997 / 7.99993 MHz on average, one clk_bus of jitter).
-- The SAA1099 ran on clk_8 before, with the CPU writes and its output crossing to clk_bus unsynchronised.
process (clk_bus)
begin
	if rising_edge(clk_bus) then
		if ds80 = '1' then
			acc8 <= ('0' & acc8(15 downto 0)) + 21748;
		else
			acc8 <= ('0' & acc8(15 downto 0)) + 18641;
		end if;
	end if;
end process;
CE_8 <= acc8(16);

-- ena counters
process (clk_bus)
begin
	if falling_edge(clk_bus) then
		ena_cnt <= ena_cnt + 1;
	end if;
end process;

process (clk_bus)
begin
	if rising_edge(clk_bus) then
		ENA_DIV2 <= ena_cnt(0);
		ENA_DIV4 <= ena_cnt(1) and ena_cnt(0);
		ENA_DIV8 <= ena_cnt(2) and ena_cnt(1) and ena_cnt(0);
		ENA_DIV16 <= ena_cnt(3) and ena_cnt(2) and ena_cnt(1) and ena_cnt(0);

		ENA_DIV2N <= not ena_cnt(0);
		ENA_DIV4N <= not ena_cnt(1) and not ena_cnt(0);
		ENA_DIV8N <= not ena_cnt(2) and not ena_cnt(1) and not ena_cnt(0);
		ENA_DIV16N <= not ena_cnt(3) and not ena_cnt(2) and not ena_cnt(1) and not ena_cnt(0);
		
		if (ds80 = '1') then
			ENA_RGB <= ena_cnt(0); -- 12
		else
			ENA_RGB <= ena_cnt(0) and ena_cnt(1); -- 7
		end if;
		
		CE_14 <= ena_cnt(0);

		if (WAIT_CPU = '1') then 
			ENA_CPU <= '0';
			ENA_CPU_N <= '0';
		elsif turbo = "11" then -- 28
			ENA_CPU <= '1';
			ENA_CPU_N <= '1';
		elsif turbo = "10" then -- 14
			ENA_CPU <= ena_cnt(0);
			ENA_CPU_N <= not(ena_cnt(0));
		elsif turbo = "01" then -- 7
			ENA_CPU <= ena_cnt(1) and ena_cnt(0);
			ENA_CPU_N <= not(ena_cnt(1)) and not(ena_cnt(0));
		else
			ENA_CPU <= ena_cnt(2) and ena_cnt(1) and ena_cnt(0); -- 3.5
			ENA_CPU_N <= not(ena_cnt(2)) and not(ena_cnt(1)) and not(ena_cnt(0));
		end if;
	end if;
end process;

end rtl;