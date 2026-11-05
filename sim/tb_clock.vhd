-------------------------------------------------------------------------------
-- tb_clock: the Cyclone V clock generator (rtl/replaced/clock.vhd)
-------------------------------------------------------------------------------
-- Run with: tools/sim.sh sim/run_tb_clock.sh
--
-- The device under test is rtl/replaced/clock.vhd; the `pll` component inside it
-- binds to the sim-only entity sim/models/pll_model.vhd, which produces the four
-- PLL periods exactly (35.555556 / 41.481480 / 8.888888 / 10.370370 ns) and
-- asserts `locked` 1 us after the start. A period measured here is therefore
-- exactly the period expected from the altera_pll parameters, checked with a
-- 0.01 ns tolerance.
--
-- Cases, each printing its own name:
--   freq_28       DS80 = '0': 100 consecutive CLK_BUS periods; CLK_VGA follows the
--                 mux and CLK_GS / CLK_SDR / CLK_VID are 28.125 / 112.5 / 112.5 MHz
--   freq_24       DS80 = '1': CLK_BUS/CLK_VGA 24.107142, CLK_SDR 96.428571 MHz and
--                 CLK_VID stays at the fixed 112.5 MHz
--   reset_mem     RESET_MEM is '1' from the start and stays '1' for at least 16
--                 clk_mem (CLK_SDR) periods after `locked` rises (ARESET falls at
--                 the lock), releasing on a clk_mem rising edge
--   phase_28      DS80 = '0', 2000 CLK_BUS periods: every CLK_BUS rising edge
--                 coincides (within 0.1 ns) with a CLK_SDR rising edge whose
--                 BUS_PHASE is "00", every CLK_BUS high phase is exactly 2
--                 112.5 MHz periods (+/- 0.1 ns), and the frequency over 1000
--                 periods is within 0.01 % of 28.125 MHz
--   phase_24      the same for DS80 = '1' (2 x 10.370370 ns, 24.107142 MHz)
--   switch_x10    DS80 toggled ten times at pseudo-random CLK_BUS edges: no
--                 CLK_BUS or CLK_SDR pulse shorter than the 112.5 MHz half
--                 period minus 0.1 ns, and the phase relation of phase_28 holds
--                 again from the first CLK_BUS edge after every switch
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

-- The device under test (rtl/replaced/clock.vhd): the upstream port list plus the
-- three Stage-2 clock-tree ports.
component clock is
port (
	CLK			: in std_logic;
	DS80			: in std_logic;

	CLK_BUS		: buffer std_logic; -- 28 / 24 (= CLK_SDR / 4)
	CLK_8			: buffer std_logic; -- 8 (the FDC, the FT812 clock output)
	CLK_GS		: buffer std_logic; -- 28 in both video modes (General Sound)
	CLK_SDR		: buffer std_logic; -- clk_mem: 112.5 / 96.428571
	CLK_VID		: out std_logic;    -- 112.5 fixed (video)
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
	BUS_PHASE		: out std_logic_vector(1 downto 0); -- in the CLK_SDR domain
	RESET_MEM		: out std_logic                     -- stretched not-locked
);
end component;

constant T_28  : time := 35.555556 ns;  -- the model's 28.125 MHz period
constant T_24  : time := 41.481480 ns;  -- the model's 24.107142 MHz period
constant T_112 : time := 8.888888 ns;   -- the model's 112.5 MHz period
constant T_96  : time := 10.370370 ns;  -- the model's 96.428571 MHz period
constant T_REF : time := 20 ns;         -- the MiSTer 50 MHz input clock

constant TOL       : time := 0.01 ns;  -- the period tolerance of the brief
constant CO_TOL    : time := 0.1 ns;   -- the edge-coincidence window of the brief
constant MIN_PHASE : time := 17.7 ns;  -- the shortest allowed CLK_BUS phase
constant MIN_PULSE : time := 4.344 ns; -- the switch window: 112.5 MHz half period - 0.1 ns
constant STORM_T   : time := 173 ns;   -- the DS80 toggle period of the storm
constant STORM_N   : natural := 115;   -- 115 toggles: 19.9 us, i.e. 20 us
constant LOCK_T    : time := 1 us;     -- the model's lock time
constant PH_N      : natural := 2000;  -- the CLK_BUS periods of the phase windows
constant FREQ_N    : natural := 1000;  -- the CLK_BUS periods of the frequency windows

-- the monitor below measures while these are asserted
signal mon_run   : boolean := false;  -- switch_storm: CLK_BUS phases
signal mon_phase : boolean := false;  -- bus edge == clk_mem edge with BUS_PHASE "00"
signal mon_high  : boolean := false;  -- CLK_BUS high time = 2 clk_mem periods
signal mon_min   : boolean := false;  -- shortest allowed pulse while switching

shared variable mon_viol     : boolean := false;  -- a CLK_BUS phase below MIN_PHASE
shared variable viol_phase   : boolean := false;  -- a bus edge outside the relation
shared variable viol_high    : boolean := false;  -- a bus high phase outside 2 periods
shared variable viol_min     : boolean := false;  -- a bus or clk_mem pulse below MIN_PULSE
shared variable t_bus_rise   : time := 0 ns;      -- the time of the last CLK_BUS rise
shared variable t_mem_rise   : time := 0 ns;      -- the time of the last CLK_SDR rise

-- the 50 MHz MiSTer clock
signal clk50 : std_logic := '0';

-- the unit under test
signal ds80 : std_logic := '0';
signal turbo : std_logic_vector(1 downto 0) := "00";
signal wait_cpu : std_logic := '0';
signal clk_bus, clk_8, clk_gs, clk_sdr, clk_vid, clk_12, clk_rgb, clk_vga, clk_adc : std_logic;
signal bus_phase : std_logic_vector(1 downto 0);
signal reset_mem : std_logic;
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
	CLK_VID => clk_vid,
	CLK_12 => clk_12, CLK_RGB => clk_rgb, CLK_VGA => clk_vga, CLK_ADC => clk_adc,
	ENA_DIV2 => ena_div2, ENA_DIV4 => ena_div4, ENA_DIV8 => ena_div8,
	ENA_DIV16 => ena_div16, ENA_DIV2N => ena_div2n, ENA_DIV4N => ena_div4n,
	ENA_DIV8N => ena_div8n, ENA_DIV16N => ena_div16n,
	ENA_CPU => ena_cpu, ENA_CPU_N => ena_cpu_n, ENA_RGB => ena_rgb,
	CE_14 => ce_14, CE_8 => ce_8,
	TURBO => turbo, WAIT_CPU => wait_cpu, ARESET => areset,
	BUS_PHASE => bus_phase, RESET_MEM => reset_mem
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

-- the phase relation: stamp every clk_mem (CLK_SDR) rising edge with its time.
stamp_mem: process (clk_sdr)
begin
	if rising_edge(clk_sdr) then
		t_mem_rise := now;
	end if;
end process;

-- phase_28/24/switch_x10: every CLK_BUS rising edge must sit on a clk_mem rising edge
-- (CO_TOL) whose BUS_PHASE is "00". The wait for 0 ns moves the read of BUS_PHASE one
-- delta after the edge: BUS_PHASE is the clkdiv4 counter, registered in the same
-- process and same delta as the clk_bus register itself, and the concurrent output
-- buffer needs that delta to carry it to the port. (A wait statement is illegal in a
-- sensitized process, so this one waits on the edge itself.)
proc_phase: process
begin
	loop
		wait until rising_edge(clk_bus);
		wait for 0 ns;
		if mon_phase then
			if bus_phase /= "00" or (now - t_mem_rise) > CO_TOL then
				viol_phase := true;
			end if;
		end if;
	end loop;
end process;

-- phase_28/24: the CLK_BUS high phase is exactly two clk_mem periods (the 50 % duty
-- the falling-edge ena_cnt of clock.vhd needs). ds80 is stable while mon_high is on.
proc_high: process (clk_bus)
	variable tr : time := 0 ns;
	variable want : time;
begin
	if rising_edge(clk_bus) then
		tr := now;
	elsif falling_edge(clk_bus) and mon_high then
		if ds80 = '0' then
			want := 2 * T_112;
		else
			want := 2 * T_96;
		end if;
		if (now - tr) < want - CO_TOL or (now - tr) > want + CO_TOL then
			viol_high := true;
		end if;
	end if;
end process;

-- switch_x10: neither CLK_BUS nor clk_mem may produce a pulse shorter than the
-- 112.5 MHz half period (minus the 0.1 ns window) across a DS80 switch.
proc_min_bus: process (clk_bus)
	variable have_rise : boolean := false;
	variable have_fall : boolean := false;
	variable tr, tf : time := 0 ns;
begin
	if rising_edge(clk_bus) then
		tr := now;
		if have_fall and mon_min and (tr - tf) < MIN_PULSE then
			viol_min := true;
		end if;
		have_rise := true;
	elsif falling_edge(clk_bus) then
		tf := now;
		if have_rise and mon_min and (tf - tr) < MIN_PULSE then
			viol_min := true;
		end if;
		have_fall := true;
	end if;
end process;

proc_min_mem: process (clk_sdr)
	variable have_rise : boolean := false;
	variable have_fall : boolean := false;
	variable tr, tf : time := 0 ns;
begin
	if rising_edge(clk_sdr) then
		tr := now;
		if have_fall and mon_min and (tr - tf) < MIN_PULSE then
			viol_min := true;
		end if;
		have_rise := true;
	elsif falling_edge(clk_sdr) then
		tf := now;
		if have_rise and mon_min and (tf - tr) < MIN_PULSE then
			viol_min := true;
		end if;
		have_fall := true;
	end if;
end process;

main: process

	type clk_id is (BUS_C, VGA_C, GS_C, SDR_C, VID_C);
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
	variable t_lock : time;
	variable seed : natural := 42;

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
				when VID_C => wait until rising_edge(clk_vid);
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

	-- the CLK_BUS frequency over `cycles` periods, within 0.01 % of 1 / `period`
	procedure check_freq(period : in time; cycles : in natural; good : out boolean) is
		variable t0, t1, d : time;
	begin
		wait until rising_edge(clk_bus);
		t0 := now;
		for i in 1 to cycles loop
			wait until rising_edge(clk_bus);
		end loop;
		t1 := now;
		d := t1 - t0;
		good := d >= (cycles * period) - (cycles * period) / 10000
		    and d <= (cycles * period) + (cycles * period) / 10000;
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
	t_lock := now;
	ok := ok and now >= LOCK_T;
	wait for 100 ns;
	ok := ok and areset = '0';
	if ok then pass("areset"); else fail("areset"); end if;

	-- reset_mem: '1' from the start (the PLL is unlocked) and it must stay '1' for at
	-- least 16 clk_mem periods after the lock at t_lock, releasing on a clk_mem rising
	-- edge (the stretched synchronous release of clock.vhd). ------------------------
	ok := reset_mem = '1';
	wait until reset_mem = '0';
	ok := ok and (now - t_lock >= 16 * T_112) and (now - t_mem_rise <= CO_TOL);
	if ok then pass("reset_mem"); else fail("reset_mem"); end if;

	-- freq_28: DS80 = '0' -> CLK_BUS and CLK_VGA 28.125 MHz, CLK_GS 28.125 MHz,
	-- CLK_SDR and CLK_VID 112.5 MHz ---------------------------------------------------
	ds80 <= '0';
	rise(4);
	ok := true;
	check_periods(BUS_C, T_28, 100, ok);
	check_periods(VGA_C, T_28, 100, ok);
	check_periods(GS_C,  T_28, 100, ok);
	check_periods(SDR_C, T_112, 200, ok);
	check_periods(VID_C, T_112, 200, ok);
	if ok then pass("freq_28"); else fail("freq_28"); end if;

	-- freq_24: DS80 = '1' -> 24.107142 MHz on the bus, 96.428571 MHz on clk_mem;
	-- CLK_VID keeps running at the fixed 112.5 MHz -------------------------------------
	ds80 <= '1';
	wait for 1 us;                 -- the switch is over in about 4 periods
	ok := true;
	check_periods(BUS_C, T_24, 100, ok);
	check_periods(VGA_C, T_24, 100, ok);
	check_periods(SDR_C, T_96, 200, ok);
	check_periods(VID_C, T_112, 200, ok);
	if ok then pass("freq_24"); else fail("freq_24"); end if;

	-- phase_28: DS80 = '0', 2000 CLK_BUS periods: every bus edge on a clk_mem edge with
	-- BUS_PHASE "00", every high phase 2 clk_mem periods, 1000 periods within 0.01 % of
	-- 28.125 MHz ------------------------------------------------------------------------
	ds80 <= '0';
	wait for 1 us;
	mon_phase <= true;
	mon_high  <= true;
	ok := true;
	check_freq(T_28, FREQ_N, ok);
	rise(PH_N - FREQ_N);
	mon_phase <= false;
	mon_high  <= false;
	if viol_phase or viol_high or not ok then
		ok := false;
	end if;
	if ok then pass("phase_28"); else fail("phase_28"); end if;

	-- phase_24: the same for DS80 = '1' (2 x 10.370370 ns, 24.107142 MHz) ---------------
	ds80 <= '1';
	wait for 1 us;
	mon_phase <= true;
	mon_high  <= true;
	ok := true;
	check_freq(T_24, FREQ_N, ok);
	rise(PH_N - FREQ_N);
	mon_phase <= false;
	mon_high  <= false;
	if viol_phase or viol_high or not ok then
		ok := false;
	end if;
	if ok then pass("phase_24"); else fail("phase_24"); end if;

	-- switch_x10: DS80 ten times at pseudo-random CLK_BUS edges; across every switch no
	-- CLK_BUS or clk_mem pulse below MIN_PULSE, and the phase relation holds again from
	-- the first CLK_BUS edge after the switch (mon_phase never goes off) -----------------
	mon_phase <= true;
	mon_min   <= true;
	viol_phase := false;
	viol_min := false;
	for i in 1 to 10 loop
		seed := (seed * 37 + 11) mod 4096;
		n := 13 + seed mod 97;               -- 13 .. 109 CLK_BUS periods between switches
		rise(n);
		ds80 <= not ds80;
	end loop;
	rise(8);                                  -- settle after the last switch
	mon_phase <= false;
	mon_min   <= false;
	ok := not (viol_phase or viol_min);
	if ok then pass("switch_x10"); else fail("switch_x10"); end if;

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
