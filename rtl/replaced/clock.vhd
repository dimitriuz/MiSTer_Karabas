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
--   (new, Stage 2)                    -> clkdiv4 (rtl/clk/clkdiv4.vhd)
--
-- The tree of Stage 2 (all four PLL outputs are phase 0 of the same 675 MHz VCO):
--
--   clk_28   28.125 MHz   -> CLK_GS only (General Sound runs at 28 MHz in both video
--                            modes, as in Stage 1; a second same-frequency output of
--                            the Xilinx PLL, which this one folds onto one)
--   (24.107142 MHz: the Xilinx bus frequency of the DS80 mode, no longer used by
--    anything - the request keeps the output, the fitter prunes the counter)
--   clk_112  112.5 MHz    -> CLK_VID (the fixed video clock) and branch 0 of clk_mem
--   clk_96   96.428571    -> clk_mem branch 1
--   clk_mem  = DS80 ? clk_96 : clk_112 (clkmux2 U9)  -> CLK_SDR (the SDRAM bridge)
--   clk_bus  = clk_mem / 4, 50 % duty (clkdiv4 U11)  -> CLK_BUS, CLK_VGA, clk_rgb
--
-- The bus clock is derived from the memory clock instead of coming from its own PLL
-- output, because the SDRAM controller of Task 3 places its bursts on the bus clock
-- and needs a fixed phase between the two (BUS_PHASE, in the clk_mem domain: "00" on
-- the clk_mem edge where a clk_bus rising edge is, then 01, 10, 11), and because one
-- clkmux2 then switches both clocks together on DS80: the phase cannot move across a
-- switch. The 50 % duty matters: the ena_cnt below ticks on the falling edge.
--
-- While DS80 = 0 the bus clock also re-aligns itself to CLK_GS (Stage 3): gs.v samples
-- the host bus on CLK_GS and needs the bus edge there, and the divider's phase against
-- clk_28 used to be whatever reset release or the last DS80 switch left. The
-- t28/hold_req loop below adds one clk_mem of low phase at a time until a CLK_BUS
-- rising edge is a CLK_GS rising edge; it is idle while DS80 = 1, where the bus is
-- 24.107 MHz against the fixed 28.125 MHz CLK_GS and there is nothing to align.
--
-- The sdc keeps clk_bus and clk_mem related (a divide-by-4), and clk_gs (general[0])
-- related to the 28.125 MHz pair clk_mem112/clk_bus28 - the phase relation above is the
-- point of the alignment. The DS80 pair clk_mem96/clk_bus24 and the fixed video output
-- general[2] are cut asynchronous against it: with DS80 = 1 the GS cannot reach the
-- host bus (gs_sel has ~DS80), and the video CDC has its own synchronisers. What the
-- Xilinx PLL gave and this one does not:
--
--   clk_gs  = clk_28, not a second 28.125 MHz PLL output of the same frequency and
--             phase; it stays out of the memory mux, the General Sound part of the
--             machine runs at 28 MHz in both video modes
--   clk_sdr = 112.5 / 96.428571 MHz, not the 84.375 MHz of the Xilinx PLL: the SDRAM
--             side of this port runs at 4x the bus clock (the CPU at turbo 8x), and
--             clk_bus with it (the two DS80 settings move together)
--   clk_12, clk_8 = '0': profi.vhd has both declarations commented out and routes them
--             only to the MIDI clock and the FT812 clock pin drivers of the
--             karabas_go/mini tops, which this port does not use
--
-- Resets: ARESET = not locked, the upstream meaning. RESET_MEM stretches it in the
-- clk_mem domain (async assert, synchronous release, at least 16 clk_mem long) for
-- the memory-side logic, which needs its reset released on the clock it runs on.
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
	
	CLK_BUS		: buffer std_logic; -- 28 / 24 (= CLK_SDR / 4)
	CLK_8			: buffer std_logic; -- 8 (the FDC, the FT812 clock output)
	CLK_GS		: buffer std_logic; -- 28 in both video modes (General Sound)
	CLK_SDR		: buffer std_logic; -- clk_mem: 112.5 / 96.428571 (sdram)
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
	ARESET 		: out std_logic;

	-- Stage 2 additions (upstream maps none of them; profi's U1 does):
	CLK_VID		: out std_logic;    -- 112.5 fixed (the video clock)
	BUS_PHASE	: out std_logic_vector(1 downto 0); -- clk_bus phase, clk_mem domain
	RESET_MEM	: out std_logic     -- not locked, stretched in clk_mem
);
end clock;

architecture rtl of clock is

signal ena_cnt : std_logic_vector(5 downto 0) := "000000";
signal locked : std_logic := '0';
signal not_locked : std_logic;
signal clk_28, clk_96 : std_logic;
signal clk_112 : std_logic;
signal clk_bus_i, clk_mem_i, clk_rgb_i : std_logic;  -- the mux, the divider and the gate, wired to the buffer ports
signal s1, s2 : std_logic := '1';        -- not_locked, synchronised into clk_mem
signal rm_cnt : std_logic_vector(3 downto 0) := "0000";  -- the >= 16 clk_mem stretch
signal r1, r2 : std_logic := '0';        -- two more clk_mem edges after rm_cnt is full
signal reset_mem_i : std_logic;
signal acc8 : std_logic_vector(16 downto 0) := (others => '0');
-- CLK_GS alignment (Stage 3): t28 toggles on every clk_28 rising edge, so one edge per
-- CLK_GS period; sampled into the clk_mem domain (t28_m, t28_d), chg is high for the
-- clk_mem cycle after the edge that follows a CLK_GS rise. al_s1/al_s2 bring DS80 into
-- that domain (al_en = not al_s2); hold_req asks clkdiv4 for one clk_mem of low phase.
signal t28, t28_m, t28_d : std_logic := '0';
signal al_s1, al_s2      : std_logic := '0';
signal hold_req          : std_logic := '0';
signal chg               : std_logic;
signal bus_phase_i : std_logic_vector(1 downto 0);  -- clkdiv4 counter, to the BUS_PHASE port

-- The Cyclone V units, declared as components rather than instantiated as
-- `entity work.`: Quartus 17 cannot bind a VHDL direct entity instantiation to a Verilog
-- module, and pll (rtl/pll.v) is Verilog. In the GHDL testbench the entity `pll` of
-- sim/models/pll_model.vhd binds to the component by default binding.
component pll is
port (
	refclk   : in  std_logic;
	rst      : in  std_logic;
	outclk_0 : out std_logic; -- 28.125
	outclk_1 : out std_logic; -- 24.107 (unconnected)
	outclk_2 : out std_logic; -- 112.5
	outclk_3 : out std_logic; -- 96.428571
	locked   : out std_logic
);
end component;

component clkdiv4 is
port (
	clk_in  : in  std_logic;
	rst     : in  std_logic;
	hold    : in  std_logic;
	clk_out : out std_logic;
	phase   : out std_logic_vector(1 downto 0)
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

-- 50 MHz -> 28.125 / 24.107142 (unused) / 112.5 / 96.428571 MHz (rtl/pll.v: one
-- altera_pll, VCO 675 MHz, the counters resolved by Quartus at build time; the open
-- 24.107 MHz output makes the fitter prune its counter). The 28.125 MHz branch feeds
-- only CLK_GS, the two fast ones the clkmux2 of clk_mem, which clkdiv4 divides by 4
-- into the bus clock - the fixed phase between the two clocks and the reason for the
-- divider are in the header.
U2: pll port map (
	refclk   => CLK,
	rst      => '0',
	outclk_0 => clk_28,
	outclk_1 => open,
	outclk_2 => clk_112,
	outclk_3 => clk_96,
	locked   => locked
);
CLK_GS  <= clk_28;
CLK_SDR <= clk_mem_i;
CLK_VID <= clk_112;

U9 : clkmux2 port map (clk0 => clk_112, clk1 => clk_96, clk_out => clk_mem_i, sel => ds80);
U11: clkdiv4 port map (clk_in => clk_mem_i, rst => reset_mem_i, hold => hold_req,
	clk_out => clk_bus_i, phase => bus_phase_i);
BUS_PHASE <= bus_phase_i;
U10: clkgate port map(clk => clk_bus_i, gclk => clk_rgb_i, en => ena_rgb);
clk_bus <= clk_bus_i;
clk_rgb <= clk_rgb_i;
clk_vga <= clk_bus;
clk_adc <= ena_rgb; -- the pixel enable, not a clock: see the note at the top
clk_12 <= '0';
clk_8 <= '0';

ARESET <= not locked;

-- RESET_MEM: `not locked` for the memory side of the port. The two sample FFs are the
-- classic asynchronous-assert / synchronous-release synchroniser on clk_mem; rm_cnt (a
-- clk_mem clock enable away from being freed) and the two-edge chain r1, r2 behind it
-- stretch the release, so RESET_MEM falls only 17 clk_mem edges (more than 16 whole
-- periods) after `locked` rose, and always on a clk_mem rising edge. The whole chain
-- clears asynchronously while the PLL is unlocked, so a re-lock always restarts the
-- full stretch. clkdiv4 holds its counter at "11" (bus clock held low) while
-- this is high.
not_locked <= not locked;
synchroniser: process (clk_mem_i, not_locked)
begin
	if not_locked = '1' then
		s1 <= '1';
		s2 <= '1';
		rm_cnt <= "0000";
		r1 <= '0';
		r2 <= '0';
	elsif rising_edge(clk_mem_i) then
		s1 <= '0';
		s2 <= s1;
		if rm_cnt /= "1111" then
			rm_cnt <= rm_cnt + 1;
		end if;
		r1 <= rm_cnt(3) and rm_cnt(2) and rm_cnt(1) and rm_cnt(0);
		r2 <= r1;
	end if;
end process;
reset_mem_i <= s2 or not (r1 and r2);
RESET_MEM <= reset_mem_i;

-- CLK_GS alignment while DS80 = 0. Upstream's gs.v reads the host CPU bus (#B3/#BB)
-- directly on CLK_GS, so the bus edge must be the CLK_GS edge: the machine is built
-- around that (STA treats clk_bus28 and clk_gs as related). t28 toggles on every clk_28
-- rising edge; sampled into the clk_mem domain, chg is high in the clk_mem cycle after
-- the edge that follows a CLK_GS rise. The bus rising edge is the clk_mem edge where
-- the counter becomes "00", and in the aligned phase that is the edge the CLK_GS rise
-- is sampled at: chg is seen one edge later, with the counter at "01". Any other
-- counter value means the bus edge is not under the CLK_GS edge, and hold_req stalls
-- clkdiv4 at "11" (one extra clk_mem of low phase), moving the next bus edge one
-- clk_mem later. At most three requests put the edge on the CLK_GS edge; each request
-- is applied and cleared on the same edge, so one request is exactly one clk_mem, and a
-- hold only ever lengthens a low phase (the high phase stays 2 clk_mem, which the bus
-- timing and the falling-edge ena_cnt rely on). While DS80 = 1 CLK_BUS is 24.107 MHz
-- against the fixed 28.125 MHz CLK_GS and nothing can be aligned, so the loop stops
-- (al_s2 follows DS80 into this domain, al_en = not al_s2); hold_req is held clear in
-- reset, so the loop starts clean and the first bus edges after release take only the
-- holds their phase needs.
t28_ff: process (clk_28)
begin
	if rising_edge(clk_28) then
		t28 <= not t28;
	end if;
end process;

chg <= t28_m xor t28_d;

align: process (clk_mem_i)
begin
	if rising_edge(clk_mem_i) then
		t28_m <= t28;
		t28_d <= t28_m;
		al_s1 <= ds80;
		al_s2 <= al_s1;
		if reset_mem_i = '1' then
			hold_req <= '0';
		elsif hold_req = '1' then
			if bus_phase_i = "11" then
				hold_req <= '0';    -- clkdiv4 applies the hold on this same edge
			end if;
		elsif al_s2 = '0' and chg = '1' and bus_phase_i /= "01" then
			hold_req <= '1';
		end if;
	end if;
end process;

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