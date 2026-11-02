-------------------------------------------------------------------------------
-- tb_clock: the Cyclone V clock generator (rtl/replaced/clock.vhd)
-------------------------------------------------------------------------------
-- Run with: tools/sim.sh sim/run_tb_clock.sh
--
-- The device under test is rtl/replaced/clock.vhd; the `pll` component inside it
-- binds to the sim-only entity sim/models/pll_model.vhd, which produces the three
-- PLL periods exactly (35.555 / 41.481 / 8.888 ns) and asserts `locked` 1 us after
-- the start. A period measured here is therefore exactly the period expected from
-- the altera_pll parameters, checked with a 0.01 ns tolerance.
--
-- Cases, each printing its own name:
--   freq_28       DS80 = '0': 100 consecutive CLK_BUS periods; CLK_VGA follows the
--                 mux and CLK_GS / CLK_SDR are the PLL's 28.125 / 112.5 MHz outputs
--   freq_24       DS80 = '1': the same periods at 24.107142 MHz
--   switch_storm  DS80 toggled every 173 ns for 20 us: no CLK_BUS high or low phase
--                 shorter than 17.7 ns, and the period settles within 4 periods
--                 after the last toggle
--   rgb_enable    DS80 = '0': CLK_ADC (the pixel enable) high on 1 of every 4
--                 CLK_BUS cycles, one CLK_RGB rising edge per 4 cycles and only
--                 coinciding with a CLK_BUS rising edge; DS80 = '1': 1 of every 2
--   cpu_enable    ENA_CPU high on 1 of 8, 1 of 4, 1 of 2 and every CLK_BUS cycle
--                 for TURBO = "00", "01", "10", "11"
--   areset        ARESET = '1' until the model locks, then '0' (run first: the lock
--                 happens at 1 us)
--
-- CLK_12 and CLK_8 are tied to '0' (unused by profi.vhd) and are not checked.
library IEEE;
use IEEE.std_logic_1164.all;

entity tb_clock is
end tb_clock;

architecture sim of tb_clock is

-- The device under test (rtl/replaced/clock.vhd): the upstream port list unchanged.
component clock is
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
end component;

constant T_28  : time := 35.555 ns;  -- the model's 28.125 MHz period
constant T_24  : time := 41.481 ns;  -- the model's 24.107142 MHz period
constant T_112 : time := 8.888 ns;   -- the model's 112.5 MHz period
constant T_REF : time := 20 ns;      -- the MiSTer 50 MHz input clock

constant TOL       : time := 0.01 ns;  -- the period tolerance of the brief
constant MIN_PHASE : time := 17.7 ns;  -- the shortest allowed CLK_BUS phase
constant STORM_T   : time := 173 ns;   -- the DS80 toggle period of the storm
constant STORM_N     : natural := 115; -- 115 toggles: 19.9 us, i.e. 20 us
constant LOCK_T    : time := 1 us;     -- the model's lock time

-- the monitor below measures while this is asserted
signal mon_run : boolean := false;

shared variable mon_viol   : boolean := false;  -- a CLK_BUS phase below MIN_PHASE
shared variable t_bus_rise : time := 0 ns;      -- the time of the last CLK_BUS rise

-- the 50 MHz MiSTer clock
signal clk50 : std_logic := '0';

-- the unit under test
signal ds80 : std_logic := '0';
signal turbo : std_logic_vector(1 downto 0) := "00";
signal wait_cpu : std_logic := '0';
signal clk_bus, clk_8, clk_gs, clk_sdr, clk_12, clk_rgb, clk_vga, clk_adc : std_logic;
signal ena_div2, ena_div4, ena_div8, ena_div16 : std_logic;
signal ena_div2n, ena_div4n, ena_div8n, ena_div16n : std_logic;
signal ena_cpu, ena_cpu_n, ena_rgb, ce_14, ce_8 : std_logic;
signal areset : std_logic;

begin

refclk: process
begin
	clk50 <= '0';
	wait for T_REF / 2;
	loop
		clk50 <= '1'; wait for T_REF / 2;
		clk50 <= '0'; wait for T_REF / 2;
	end loop;
end process;

U1: clock port map (
	CLK => clk50, DS80 => ds80,
	CLK_BUS => clk_bus, CLK_8 => clk_8, CLK_GS => clk_gs, CLK_SDR => clk_sdr,
	CLK_12 => clk_12, CLK_RGB => clk_rgb, CLK_VGA => clk_vga, CLK_ADC => clk_adc,
	ENA_DIV2 => ena_div2, ENA_DIV4 => ena_div4, ENA_DIV8 => ena_div8,
	ENA_DIV16 => ena_div16, ENA_DIV2N => ena_div2n, ENA_DIV4N => ena_div4n,
	ENA_DIV8N => ena_div8n, ENA_DIV16N => ena_div16n,
	ENA_CPU => ena_cpu, ENA_CPU_N => ena_cpu_n, ENA_RGB => ena_rgb,
	CE_14 => ce_14, CE_8 => ce_8,
	TURBO => turbo, WAIT_CPU => wait_cpu, ARESET => areset
);

-- switch_storm: while mon_run is asserted, watch every CLK_BUS phase. Both references
-- are rearmed on the CLK_BUS edges in between, so the first measured edge only stamps
-- a time.
monitor: process (clk_bus)
	variable have_rise : boolean := false;
	variable have_fall : boolean := false;
	variable tr, tf : time := 0 ns;
begin
	if not mon_run then
		have_rise := false;
		have_fall := false;
	elsif rising_edge(clk_bus) then
		tr := now;
		if have_fall and (tr - tf) < MIN_PHASE then
			mon_viol := true;
		end if;
		have_rise := true;
	else
		tf := now;
		if have_rise and (tf - tr) < MIN_PHASE then
			mon_viol := true;
		end if;
		have_fall := true;
	end if;
end process;

-- rgb_enable: the window procedure of the test process below compares a CLK_RGB rising
-- edge with the CLK_BUS rising edge of the same time (the two events happen one delta
-- apart), so every CLK_BUS rising edge is stamped here.
stamp: process (clk_bus)
begin
	if rising_edge(clk_bus) then
		t_bus_rise := now;
	end if;
end process;

main: process

	type clk_id is (BUS_C, VGA_C, GS_C, SDR_C);
	type turbo_array is array (natural range <>) of std_logic_vector(1 downto 0);
	type count_array is array (natural range <>) of natural;

	-- ENA_CPU cycles high out of 64 CLK_BUS cycles, per TURBO
	constant CPU_TURBO  : turbo_array(0 to 3)  := ("00", "01", "10", "11");
	constant CPU_EXPECT : count_array(0 to 3)  := (8, 16, 32, 64);

	variable bad : boolean := false;  -- at least one case failed
	variable ok : boolean;
	variable n, high_adc, rise_rgb : natural;
	variable off_align : boolean;
	variable target : time;

	procedure fail(name : string) is
	begin
		bad := true;
		report "tb_clock: case " & name & " failed";
	end procedure;

	procedure pass(name : string) is
	begin
		report "tb_clock: case " & name & " ok";
	end procedure;

	-- n consecutive rising edges of clk_bus
	procedure rise(count : in natural) is
	begin
		for i in 1 to count loop
			wait until rising_edge(clk_bus);
		end loop;
	end procedure;

	-- cycles consecutive periods of the clock `id`, each within TOL of `period`. The
	-- first period of a run is measured from the first edge found, so switching the
	-- clock under test never shows up here.
	procedure check_periods(id : in clk_id; period : in time; cycles : in natural;
	                        good : inout boolean) is
		variable p, d : time := 0 ns;
	begin
		for i in 1 to cycles loop
			case id is
				when BUS_C => wait until rising_edge(clk_bus);
				when VGA_C => wait until rising_edge(clk_vga);
				when GS_C  => wait until rising_edge(clk_gs);
				when SDR_C => wait until rising_edge(clk_sdr);
			end case;
			if p /= 0 ns then
				d := now - p;
				if d > period + TOL or d < period - TOL then
					good := false;
				end if;
			end if;
			p := now;
		end loop;
	end procedure;

	-- one window of `cycles` consecutive CLK_BUS cycles: the CLK_ADC value of each of them
	-- (a register written by that rising edge, so a consumer sees it for the whole cycle),
	-- the number of CLK_RGB rising edges in it, and whether all of them coincided with a
	-- CLK_BUS rising edge (the stamp process above: the gate is a concurrent assignment, so
	-- a gated edge lands in the delta cycle of the bus edge it belongs to). The window is
	-- half open, the CLK_RGB edge at its closing bus edge counted and the one at its opening
	-- edge left to the window before, so a window whose length is a multiple of the enable
	-- period counts exactly cycles / period of them.
	procedure watch(cycles : in natural; high_count : out natural;
	                rise_count : out natural; misaligned : out boolean) is
		variable m, high, rises : natural := 0;
		variable off : boolean := false;
	begin
		wait until rising_edge(clk_bus);        -- the window opens here
		scan: loop
			wait on clk_bus, clk_rgb;
			if clk_rgb'event and clk_rgb = '1' then
				rises := rises + 1;
				if now /= t_bus_rise then
					off := true;
				end if;
			end if;
			if clk_bus'event and clk_bus = '1' then
				if clk_adc = '1' then
					high := high + 1;
				end if;
				m := m + 1;
				if m = cycles then
					exit scan;
				end if;
			end if;
		end loop scan;
		high_count := high;
		rise_count := rises;
		misaligned := off;
	end procedure;

begin

	-- areset: '1' until the PLL model locks at LOCK_T, then '0'. The first sample is a
	-- little after time zero: ARESET is a concurrent assignment, so it has no value in the
	-- first delta cycle of the run.
	wait for 100 ns;
	ok := areset = '1';
	wait for 800 ns;
	ok := ok and areset = '1' and now < LOCK_T;
	wait until areset = '0';
	ok := ok and now >= LOCK_T;
	wait for 100 ns;
	ok := ok and areset = '0';
	if ok then pass("areset"); else fail("areset"); end if;

	-- freq_28: DS80 = '0' -> CLK_BUS and CLK_VGA 28.125 MHz, CLK_GS 28.125 MHz,
	-- CLK_SDR 112.5 MHz ------------------------------------------------------------
	ds80 <= '0';
	rise(4);
	ok := true;
	check_periods(BUS_C, T_28, 100, ok);
	check_periods(VGA_C, T_28, 100, ok);
	check_periods(GS_C,  T_28, 100, ok);
	check_periods(SDR_C, T_112, 200, ok);
	if ok then pass("freq_28"); else fail("freq_28"); end if;

	-- freq_24: DS80 = '1' -> 24.107142 MHz -----------------------------------------
	ds80 <= '1';
	wait for 1 us;                 -- the switch is over in about 4 periods
	ok := true;
	check_periods(BUS_C, T_24, 100, ok);
	check_periods(VGA_C, T_24, 100, ok);
	if ok then pass("freq_24"); else fail("freq_24"); end if;

	-- switch_storm: DS80 every 173 ns for 20 us; no CLK_BUS phase below 17.7 ns; the
	-- period settles within 4 periods after the last toggle: of the four periods measured
	-- below, the first may still straddle the end of the switch, the three after it are
	-- the exact period of the selected branch ------------------------------------------
	mon_viol := false;
	mon_run <= true;
	for i in 1 to STORM_N loop
		ds80 <= not ds80;
		wait for STORM_T;
	end loop;
	mon_run <= false;
	if ds80 = '1' then
		target := T_24;
	else
		target := T_28;
	end if;
	ok := true;
	check_periods(BUS_C, target, 5, ok);
	if mon_viol then
		ok := false;
	end if;
	if ok then pass("switch_storm"); else fail("switch_storm"); end if;

	-- rgb_enable: CLK_ADC (ENA_RGB, the pixel enable) and the gated CLK_RGB --------------
	-- DS80 = '0': ENA_RGB = ena_cnt(0) and ena_cnt(1) -> one CLK_BUS cycle in 4, and the
	-- gate lets one CLK_BUS cycle in 4 through
	ds80 <= '0';
	wait for 1 us;                 -- a bus switch is over in about 4 periods
	ok := true;
	watch(12, high_adc, rise_rgb, off_align);
	if high_adc /= 3 or rise_rgb /= 3 or off_align then
		ok := false;
	end if;
	-- DS80 = '1': ENA_RGB = ena_cnt(0) -> one CLK_BUS cycle in 2
	ds80 <= '1';
	wait for 1 us;
	watch(8, high_adc, rise_rgb, off_align);
	if high_adc /= 4 or rise_rgb /= 4 or off_align then
		ok := false;
	end if;
	if ok then pass("rgb_enable"); else fail("rgb_enable"); end if;

	-- cpu_enable: ENA_CPU high on 1 of 8, 1 of 4, 1 of 2 and every CLK_BUS cycle -----
	wait_cpu <= '0';
	ok := true;
	for t in 0 to 3 loop
		turbo <= CPU_TURBO(t);
		rise(2);
		n := 0;
		for i in 1 to 64 loop
			wait until rising_edge(clk_bus);
			if ena_cpu = '1' then
				n := n + 1;
			end if;
		end loop;
		if n /= CPU_EXPECT(t) then
			ok := false;
		end if;
	end loop;
	if ok then pass("cpu_enable"); else fail("cpu_enable"); end if;

	-- the summary ---------------------------------------------------------------------
	if bad then
		report "tb_clock: FAIL one or more cases failed" severity failure;
	else
		report "tb_clock: PASS";
	end if;
	wait;

end process;

end sim;
