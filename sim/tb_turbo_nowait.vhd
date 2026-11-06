-------------------------------------------------------------------------------
-- tb_turbo_nowait: the CPU on the no-wait SDRAM controller (system check)
-------------------------------------------------------------------------------
-- Run with: tools/sim.sh sim/run_tb_turbo_nowait.sh
--
-- Successor of sim/tb_turbo_wait.vhd on the Stage 2 controller: clock +
-- pll model, the upstream T80s (with the TS_O/MC_O ports, analysed from the
-- prepare_upstream output), rtl/mem/sdram_nowait.vhd and the SDRAM chip model
-- sim/models/sdram_chip.vhd with ROWS => 64 and REFRESH_US => 500.0, as in
-- tb_sdram_nowait. No wait path exists at all: WAIT_n = '1', WAIT_CPU = '0'.
--
-- Wiring (profi.vhd, memory.vhd): T80s CLK => clk_bus, CEN => ENA_CPU,
-- DI => cpu_dout; the controller gets MREQ_n/RD_n/WR_n/IORQ_n, addr =
-- "00000" & A (memory.vhd's main map), wr_en = '1' (every address the TB
-- sees is RAM - memory.vhd's cpu_wr_en is its RAM address decode), din = DO;
-- bus_phase and reset_mem come from clock.vhd. SDRAM_CLK = not clk_mem
-- delayed 1 ns (the top's altddio behaviour).
--
-- The program (loaded at 0x0000) runs from SDRAM preloaded straight into the
-- chip model's array (sdram_chip_pkg.sdram_chip_mem, written before the
-- controller's init ends and rewritten between the phases while the CPU is
-- in reset); port B is idle. Program: 256 writes of (256 - i) mod 256 to
-- 0x4000 + i, the sum 0x80 to 0x5000, then INC (HL) over 0x4000..0x400F
-- (each writes its old byte + 1, a read-modify-write through the controller)
-- and PUSH HL (0x4010 -> 0x7FFF <- 0x40, 0x7FFE <- 0x10), then HALT. Every
-- CPU write cycle - the strobes of one cycle are split by WR_n rising - is
-- compared against the expected sequence, EXP_N = 275 writes in all.
--
-- Phases: DS80 0 and 1, each at turbo "00" "01" "10" "11". The controller is
-- never reset between phases (a second 100 us init would break the chip's
-- 500 us sliding refresh window); every phase resets only the CPU. With no
-- wait the T-state counts are equal, so the times to HALT must stand in the
-- ratio 8 : 4 : 2 : 1 (the CPU clock is the bus /8, /4, /2, /1). Measured
-- from the first T1 after cpu_reset_n rises (TS_O = "001"; during reset the
-- T80 core holds TS_O = "000") to the clock edge on which HALT_n falls; both
-- are CPU-clock edges, so the ratio is exact - the check requires |t(00) -
-- 2 t(01)|, |t(01) - 2 t(10)| and |t(10) - 2 t(11)| within one clk_bus
-- period of that DS80 mode. Budget per phase: 9 ms (turbo 00 needs ~4.2 ms
-- at DS80 = 0, ~4.9 at DS80 = 1).
--
-- Per phase the run prints one line, per DS80 setting one line with the four
-- times; the last line is the verdict `tb_turbo_nowait: PASS` or
-- `tb_turbo_nowait: FAIL <reason>`. The chip model's violation counter and
-- the controller's b_overrun must both stay zero over the whole run; the
-- controller's sim-only assertions stop GHDL with severity failure (the run
-- script reports that as a FAIL too).
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.sdram_chip_pkg.all;

entity tb_turbo_nowait is
end tb_turbo_nowait;

architecture sim of tb_turbo_nowait is

	-- rtl/replaced/clock.vhd (the port list of sim/tb_sdram_nowait.vhd);
	-- its pll component binds to sim/models/pll_model.vhd by default binding
	component clock is
	port (
		CLK			: in std_logic;
		DS80			: in std_logic;

		CLK_BUS		: buffer std_logic; -- 28 / 24
		CLK_8			: buffer std_logic;
		CLK_GS		: buffer std_logic;
		CLK_SDR		: buffer std_logic; -- clk_mem: 112.5 / 96.43
		CLK_12      : buffer std_logic;
		CLK_RGB 		: buffer std_logic;
		CLK_VGA		: buffer std_logic;
		CLK_ADC		: buffer std_logic;

		ENA_DIV2		: buffer std_logic;
		ENA_DIV4		: buffer std_logic;
		ENA_DIV8		: buffer std_logic;
		ENA_DIV16   : buffer std_logic;

		ENA_DIV2N	: buffer std_logic;
		ENA_DIV4N	: buffer std_logic;
		ENA_DIV8N	: buffer std_logic;
		ENA_DIV16N  : buffer std_logic;

		ENA_CPU 		: buffer std_logic;
		ENA_CPU_N	: buffer std_logic;
		ENA_RGB 		: buffer std_logic;

		CE_14			: buffer std_logic;
		CE_8			: buffer std_logic;

		TURBO			: in std_logic_vector(1 downto 0);
		WAIT_CPU		: in std_logic;
		ARESET 		: out std_logic;
		CLK_VID		: out std_logic;
		BUS_PHASE		: out std_logic_vector(1 downto 0);
		RESET_MEM		: out std_logic
	);
	end component;

	component sdram_nowait is
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
		cpu_wr_en : in std_logic;
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
	end component;

	component sdram_chip is
	generic (
		T_CK_NS    : real := 8.888889;
		CL         : integer := 2;
		TRCD       : integer := 2;
		TRP        : integer := 2;
		TRAS       : integer := 5;
		TRC        : integer := 8;
		TRFC       : integer := 8;
		TWR        : integer := 2;
		REFRESH_US : real := 64000.0;
		ROWS       : integer := 8192;
		POWERUP_US : real := 100.0
	);
	port (
		clk        : in  std_logic;
		cke        : in  std_logic;
		cs_n       : in  std_logic;
		ras_n      : in  std_logic;
		cas_n      : in  std_logic;
		we_n       : in  std_logic;
		ba         : in  std_logic_vector(1 downto 0);
		a          : in  std_logic_vector(12 downto 0);
		dqm        : in  std_logic_vector(1 downto 0);
		dq         : inout std_logic_vector(15 downto 0);
		violations : out natural;
		refreshes  : out natural
	);
	end component;

	-- the program (load at 0x0000), see the header
	constant PROG_N : natural := 63;
	type prog_t is array (0 to PROG_N - 1) of std_logic_vector(7 downto 0);
	constant PROG : prog_t := (
		x"31", x"00", x"80",     -- LD SP,0x8000
		x"21", x"00", x"40",     -- LD HL,0x4000
		x"06", x"00",            -- LD B,0
		x"78",                   -- loop:  LD A,B
		x"77",                   --        LD (HL),A
		x"23",                   --        INC HL
		x"10", x"FB",            --        DJNZ loop
		x"21", x"00", x"40",     -- LD HL,0x4000
		x"06", x"00",            -- LD B,0
		x"AF",                   -- XOR A
		x"86",                   -- loop2: ADD A,(HL)
		x"23",                   --        INC HL
		x"10", x"FC",            --        DJNZ loop2
		x"32", x"00", x"50",     -- LD (0x5000),A = 0x80
		x"21", x"00", x"40",     -- LD HL,0x4000
		x"34", x"23",            -- incblk: INC (HL); INC HL   (x 16)
		x"34", x"23",
		x"34", x"23",
		x"34", x"23",
		x"34", x"23",
		x"34", x"23",
		x"34", x"23",
		x"34", x"23",
		x"34", x"23",
		x"34", x"23",
		x"34", x"23",
		x"34", x"23",
		x"34", x"23",
		x"34", x"23",
		x"34", x"23",
		x"34", x"23",
		x"E5",                   -- PUSH HL
		x"76"                    -- HALT
	);

	-- 256 loop writes + the sum + 16 INC (HL) + the two PUSH bytes
	constant EXP_N : natural := 275;

	function e_a (i : natural) return std_logic_vector is
	begin
		if i < 256 then
			return std_logic_vector(to_unsigned(16#4000# + i, 16));
		elsif i = 256 then
			return x"5000";
		elsif i < 273 then
			return std_logic_vector(to_unsigned(16#4000# + (i - 257), 16));
		elsif i = 273 then
			return x"7FFF";
		else
			return x"7FFE";
		end if;
	end function;

	function e_d (i : natural) return std_logic_vector is
	begin
		if i < 256 then
			return std_logic_vector(to_unsigned((256 - i) mod 256, 8));
		elsif i = 256 then
			return x"80";
		elsif i < 273 then
			-- INC (HL): the byte the loop wrote at this address, plus one
			return std_logic_vector(to_unsigned((257 - (i - 257)) mod 256, 8));
		elsif i = 273 then
			return x"40";        -- PUSH HL with HL = 0x4010
		else
			return x"10";
		end if;
	end function;

	constant HEX : string := "0123456789abcdef";

	function hx4 (v : std_logic_vector(15 downto 0)) return string is
	begin
		return HEX(to_integer(unsigned(v(15 downto 12))) + 1)
		     & HEX(to_integer(unsigned(v(11 downto 8))) + 1)
		     & HEX(to_integer(unsigned(v(7 downto 4))) + 1)
		     & HEX(to_integer(unsigned(v(3 downto 0))) + 1);
	end function;

	function hx2 (v : std_logic_vector(7 downto 0)) return string is
	begin
		return HEX(to_integer(unsigned(v(7 downto 4))) + 1)
		     & HEX(to_integer(unsigned(v(3 downto 0))) + 1);
	end function;

	-- VHDL-93 has no image attributes on time/integer/boolean in GHDL's
	-- --std=93c: the report lines below use these small converters
	function itos (n : in integer) return string is
		variable s : string(1 to 14) := (others => ' ');
		variable v : integer := n;
		variable i : integer := 14;
	begin
		if v = 0 then
			return "0";
		end if;
		while v > 0 loop
			s(i) := HEX((v mod 10) + 1);
			v := v / 10;
			i := i - 1;
		end loop;
		return s(i + 1 to 14);
	end function;

	function bstr (b : in boolean) return string is
	begin
		if b then
			return "yes";
		else
			return "no";
		end if;
	end function;

	-- the monitor below writes, the test process below reads
	shared variable mon_idx : natural := 0;
	shared variable mon_bad : boolean := false;

	-- the 50 MHz MiSTer clock and the clock unit's outputs
	signal clk50    : std_logic := '0';
	signal ds80     : std_logic := '0';
	signal turbo    : std_logic_vector(1 downto 0) := "00";
	signal areset   : std_logic;
	signal clk_bus, clk_mem : std_logic;
	signal bus_phase : std_logic_vector(1 downto 0);
	signal reset_mem : std_logic;
	signal ena_cpu   : std_logic;

	-- the CPU bus
	signal cpu_reset_n : std_logic := '0';
	signal m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n : std_logic;
	signal ts_o, mc_o : std_logic_vector(2 downto 0);
	signal a_bus  : std_logic_vector(15 downto 0);
	signal di_bus : std_logic_vector(7 downto 0) := (others => '0');
	signal do_bus : std_logic_vector(7 downto 0);

	-- the controller
	signal cpu_addr_i : std_logic_vector(20 downto 0);
	signal cpu_wr_en_i : std_logic;
	signal b_over : std_logic;
	signal ready  : std_logic;

	-- SDRAM pins
	signal sd_ba  : std_logic_vector(1 downto 0);
	signal sd_a   : std_logic_vector(12 downto 0);
	signal sd_dqm : std_logic_vector(1 downto 0);
	signal sd_ras_n, sd_cas_n, sd_we_n : std_logic;
	signal dq_bus : std_logic_vector(15 downto 0);
	signal sdram_clk : std_logic;

	signal viol  : natural;
	signal n_ref : natural;

begin

	-- the 50 MHz reference, as in sim/tb_clock.vhd
	refclk: process
	begin
		clk50 <= '0';
		wait for 10 ns;
		loop
			clk50 <= '1'; wait for 10 ns;
			clk50 <= '0'; wait for 10 ns;
		end loop;
	end process;

	U_CLK: clock port map (
		CLK => clk50, DS80 => ds80,
		CLK_BUS => clk_bus, CLK_8 => open, CLK_GS => open, CLK_SDR => clk_mem,
		CLK_12 => open, CLK_RGB => open, CLK_VGA => open, CLK_ADC => open,
		ENA_DIV2 => open, ENA_DIV4 => open, ENA_DIV8 => open,
		ENA_DIV16 => open, ENA_DIV2N => open, ENA_DIV4N => open,
		ENA_DIV8N => open, ENA_DIV16N => open,
		ENA_CPU => ena_cpu, ENA_CPU_N => open, ENA_RGB => open,
		CE_14 => open, CE_8 => open,
		TURBO => turbo, WAIT_CPU => '0', ARESET => areset,
		CLK_VID => open, BUS_PHASE => bus_phase, RESET_MEM => reset_mem
	);

	U_CPU: entity work.T80s
	port map (
		RESET_n => cpu_reset_n,
		CLK     => clk_bus,
		CEN     => ena_cpu,
		WAIT_n  => '1',
		INT_n   => '1',
		NMI_n   => '1',
		BUSRQ_n => '1',
		M1_n    => m1_n,
		MREQ_n  => mreq_n,
		IORQ_n  => iorq_n,
		RD_n    => rd_n,
		WR_n    => wr_n,
		RFSH_n  => rfsh_n,
		HALT_n  => halt_n,
		BUSAK_n => busak_n,
		OUT0    => '1',
		A       => a_bus,
		DI      => di_bus,
		DO      => do_bus,
		TS_O    => ts_o,
		MC_O    => mc_o
	);

	-- memory.vhd's wiring: the main map starts at word 0 (page 0), the write
	-- mask is the RAM address part of cpu_wr_en, the loader port B is idle
	-- (the program is preloaded into the chip model)
	U_SDRAM: sdram_nowait port map (
		clk_mem => clk_mem, reset => reset_mem, bus_phase => bus_phase,
		ready => ready,
		cpu_reset_n => cpu_reset_n, cpu_ena => ena_cpu,
		cpu_ts => ts_o, cpu_mc => mc_o,
		cpu_mreq_n => mreq_n, cpu_rd_n => rd_n, cpu_wr_n => wr_n,
		cpu_iorq_n => iorq_n,
		cpu_addr => cpu_addr_i,
		cpu_wr_en => cpu_wr_en_i,
		cpu_din => do_bus,
		cpu_dout => di_bus,
		b_req => '0', b_we => '0',
		b_addr => (others => '0'), b_din => (others => '0'),
		b_dout => open, b_done => open, b_overrun => b_over,
		sd_ba => sd_ba, sd_a => sd_a, sd_dqm => sd_dqm,
		sd_ras_n => sd_ras_n, sd_cas_n => sd_cas_n, sd_we_n => sd_we_n,
		sd_dq => dq_bus
	);

	sdram_clk <= not clk_mem after 1 ns;   -- the top's altddio behaviour

	U_CHIP: sdram_chip
	generic map (ROWS => 64, REFRESH_US => 500.0)  -- the 8192/64 ms rate
	port map (                                     -- with a tight window
		clk => sdram_clk, cke => '1', cs_n => '0',
		ras_n => sd_ras_n, cas_n => sd_cas_n, we_n => sd_we_n,
		ba => sd_ba, a => sd_a, dqm => sd_dqm, dq => dq_bus,
		violations => viol, refreshes => n_ref
	);

	-- memory.vhd's wiring into the controller (VHDL-93 port maps want plain
	-- signals; wr_en is the pure address part - here: everything is RAM, the
	-- controller latches it at the start sample, where WR_n is not low yet)
	cpu_addr_i <= "00000" & a_bus;
	cpu_wr_en_i <= '1';

	-- every CPU write cycle counted once: several strobes (one per ENA_CPU
	-- clock while WR_n is low) are one write cycle, split when WR_n rises.
	-- The value of the last strobe is the value of the cycle (address and
	-- data hold for the whole write T-states)
	mon: process (clk_bus)
		variable cur_a   : std_logic_vector(15 downto 0);
		variable cur_d   : std_logic_vector(7 downto 0);
		variable have    : boolean := false;
		variable prev_wr : std_logic := '1';
	begin
		if rising_edge(clk_bus) then
			if cpu_reset_n = '1' and mreq_n = '0' and wr_n = '0' and ena_cpu = '1' then
				cur_a := a_bus;
				cur_d := do_bus;
				have  := true;
			end if;
			if have and prev_wr = '0' and wr_n = '1' then
				have := false;
				if mon_idx < EXP_N then
					if cur_a /= e_a(mon_idx) or cur_d /= e_d(mon_idx) then
						report "tb_turbo_nowait: write " & integer'image(mon_idx)
							& " expected " & hx4(e_a(mon_idx)) & "," & hx2(e_d(mon_idx))
							& " got " & hx4(cur_a) & "," & hx2(cur_d);
						mon_bad := true;
					end if;
					mon_idx := mon_idx + 1;
				else
					report "tb_turbo_nowait: extra write "
						& hx4(cur_a) & "," & hx2(cur_d);
					mon_bad := true;
				end if;
			end if;
			prev_wr := wr_n;
		end if;
	end process;

main: process

	constant TMAX : time := 9 ms;

	variable bad       : boolean := false;
	variable phase_bad : boolean;
	variable tbus      : time;
	variable t00, t01, t10, t11 : time;

	procedure rise (count : in natural) is
	begin
		for i in 1 to count loop
			wait until rising_edge(clk_bus);
		end loop;
	end procedure;

	-- the program into the chip model's array (the controller is idle while
	-- this runs: the CPU is in reset and port B is tied off; refreshes never
	-- touch the array, so nothing races)
	procedure preload_program is
	begin
		for i in 0 to PROG_N - 1 loop
			sdram_chip_mem(i) := PROG(i);
		end loop;
		for i in PROG_N to 255 loop
			sdram_chip_mem(i) := x"00";
		end loop;
	end procedure;

	procedure run_phase (name        : in  string;
	                     tv          : in  std_logic_vector(1 downto 0);
	                     tbus_v      : inout time;
	                     halt_at     : inout time;
	                     phase_bad_v : inout boolean) is
		variable t0      : time;
		variable started : boolean := false;
		variable halted  : boolean := false;
		variable trel    : time;
	begin
		-- fresh CPU reset for this turbo setting; the controller keeps
		-- running (refresh stays alive through the M1 and reset windows)
		cpu_reset_n <= '0';
		turbo       <= tv;
		rise(8);
		preload_program;
		mon_idx := 0;
		mon_bad := false;
		rise(4);

		-- one clk_bus period of this mode, the ratio tolerance
		wait until rising_edge(clk_bus);
		t0 := now;
		wait until rising_edge(clk_bus);
		tbus_v := now - t0;

		trel := now;
		cpu_reset_n <= '1';
		watch: loop
			wait until rising_edge(clk_bus);
			if not started and ts_o = "001" then
				t0 := now;        -- the first T1 after the release
				started := true;
			end if;
			if started and halt_n = '0' then
				halted := true;
				halt_at := now - t0;
				exit watch;
			end if;
			if now - trel > TMAX then
				exit watch;
			end if;
		end loop watch;
		rise(4);                  -- the monitor has committed by now
		phase_bad_v := (not halted) or mon_bad or mon_idx /= EXP_N
		               or b_over = '1' or viol /= 0;
		report "tb_turbo_nowait: " & name & " halt at "
			& itos(halt_at / 1 ns) & " ns, " & itos(mon_idx) & "/"
			& itos(EXP_N) & " writes ok, halted=" & bstr(halted)
			& " seq_bad=" & bstr(mon_bad)
			& " over=" & bstr(b_over = '1') & " viol=" & itos(viol);
	end procedure;

	procedure chk_ratio (nm : in string; a, b : in time; tb : in time) is
		variable d : time;
	begin
		d := a - 2 * b;
		if d < 0 ns then
			d := -d;
		end if;
		if d > tb then
			bad := true;
			report "tb_turbo_nowait: FAIL ratio " & nm & ": " & itos(a / 1 ns)
				& " ns vs 2 x " & itos(b / 1 ns) & " ns differ by "
				& itos(d / 1 ps) & " ps > one clk_bus (" & itos(tb / 1 ps)
				& " ps)";
		end if;
	end procedure;

begin

	-- the PLL model locks 1 us after the start, the controller's init runs
	-- ~101 us more, then ready rises; the program is preloaded before that
	-- (the chip array does not care when, the model's power-up window only
	-- forbids *accesses* before 100 us)
	preload_program;
	wait until areset = '0';
	wait until ready = '1';
	rise(8);

	mode: for m in 0 to 1 loop
		if m = 0 then
			ds80 <= '0';
		else
			ds80 <= '1';
		end if;
		rise(200);                 -- the clock mux and the dividers settle

		run_phase("ds80=" & integer'image(m) & " turbo 00", "00",
		          tbus, t00, phase_bad);
		bad := bad or phase_bad;
		run_phase("ds80=" & integer'image(m) & " turbo 01", "01",
		          tbus, t01, phase_bad);
		bad := bad or phase_bad;
		run_phase("ds80=" & integer'image(m) & " turbo 10", "10",
		          tbus, t10, phase_bad);
		bad := bad or phase_bad;
		run_phase("ds80=" & integer'image(m) & " turbo 11", "11",
		          tbus, t11, phase_bad);
		bad := bad or phase_bad;

		report "tb_turbo_nowait: ds80=" & integer'image(m) & " halt ns: "
			& itos(t00 / 1 ns) & " " & itos(t01 / 1 ns) & " "
			& itos(t10 / 1 ns) & " " & itos(t11 / 1 ns)
			& " (clk_bus " & itos(tbus / 100 ps) & " * 100 ps)";
		chk_ratio("t(00) vs 2 t(01)", t00, t01, tbus);
		chk_ratio("t(01) vs 2 t(10)", t01, t10, tbus);
		chk_ratio("t(10) vs 2 t(11)", t10, t11, tbus);
	end loop mode;

	if b_over = '1' then
		bad := true;
		report "tb_turbo_nowait: FAIL b_overrun rose";
	end if;
	if viol /= 0 then
		bad := true;
		report "tb_turbo_nowait: FAIL chip violations = " & itos(viol);
	end if;
	if n_ref <= 0 then
		bad := true;
		report "tb_turbo_nowait: FAIL no refreshes observed";
	end if;

	if bad then
		report "tb_turbo_nowait: FAIL (above)";
	else
		report "tb_turbo_nowait: PASS";
	end if;
	wait;
end process;

end sim;
