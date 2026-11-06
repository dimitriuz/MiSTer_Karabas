-------------------------------------------------------------------------------
-- tb_turbo_nowait: the CPU on the no-wait SDRAM controller (system check)
-------------------------------------------------------------------------------
-- Run with: tools/sim.sh sim/run_tb_turbo_nowait.sh
--
-- Successor of sim/tb_turbo_wait.vhd on the Stage 2 controller: clock +
-- pll model, the upstream T80s (with the TS_O/MC_O ports, analysed from the
-- prepare_upstream output), rtl/replaced/memory.vhd (which instantiates
-- rtl/mem/sdram_nowait.vhd) and the SDRAM chip model
-- sim/models/sdram_chip.vhd with ROWS => 64 and REFRESH_US => 500.0, as in
-- tb_sdram_nowait. No wait path exists at all: WAIT_n = '1', WAIT_CPU = '0'.
--
-- Wiring (profi.vhd): T80s CLK => clk_bus, CEN => ENA_CPU, DI => the
-- memory unit's DO; U3 = rtl/replaced/memory.vhd itself (the real core
-- memory unit: it decodes the paging map and cpu_wr_en and instantiates
-- the controller), wired as profi.vhd wires U3 for the ports that matter:
-- the CPU bus, the clock unit's BUS_PHASE/RESET_MEM, the T80's TS_O/MC_O
-- and cpu_reset_n, MEM_READY, TURBO_MODE and DS80; the paging inputs carry
-- a plain Spectrum 128 map (RAM_BANK/RAM_EXT "000", ROM_BANK '0',
-- EXT_ROM_BANK "00", WOROM/CPM/SCO/SCR/TRDOS/DIVMMC_EN '0', REG_E3 x"00",
-- AUTOMAP '0', the GS and video ports tied off, loader inactive). The two
-- video RAMs bind to sim/models/kg_sdpram.vhd. SDRAM_CLK = not clk_mem
-- delayed 1 ns (the top's altddio behaviour).
--
-- The program runs from the boot ROM window (CPU 0x0000, rom_page "10",
-- ROM_BANK 0 -> SDRAM byte address 0x108000 + A -> chip array index
-- 16#108000# + A) and works in RAM page "000101" (0x4000..0x7FFF -> index
-- 16#14000# + A(13:0)); both ranges are preloaded into the chip model's
-- array (sdram_chip_pkg.sdram_chip_mem, written before the controller's
-- init ends and rewritten between the phases while the CPU is in reset);
-- port B is idle. Program: 256 writes of (256 - i) mod 256 to 0x4000 + i,
-- the sum 0x80 to 0x5000, INC (HL) over 0x4000..0x400F (each writes its
-- old byte + 1, a read-modify-write through the controller), PUSH HL, then
-- LD (0x0100),A - a write to a ROM address - and HALT. Every CPU write
-- cycle (the strobes of one cycle are split by WR_n rising) is compared
-- against the expected sequence, EXP_N = 276 writes in all; the 276th,
-- the ROM write, must show on the CPU bus but must NOT reach the chip.
-- After every phase the chip array itself is checked: RAM 0x4000..0x400F
-- hold the incremented bytes, 0x5000 holds 0x80, the stack bytes hold the
-- pushed HL, and the ROM byte at 0x0100 is unchanged - the bus sequence
-- and the array checks together pin cpu_wr_en to what the controller
-- latches at the start sample (T1, before MREQ_n falls).
--
-- Phases: DS80 0 and 1, each at turbo "00" "01" "10" "11". The controller
-- is never reset between phases (a second 100 us init would break the
-- chip's 500 us sliding refresh window); every phase resets only the CPU.
-- With no wait the T-state counts are equal, so the times to HALT must
-- stand in the ratio 8 : 4 : 2 : 1 (the CPU clock is the bus /8, /4, /2,
-- /1). Measured from the first T1 after cpu_reset_n rises (TS_O = "001";
-- during reset the T80 core holds TS_O = "000") to the clock edge on which
-- HALT_n falls; both are CPU-clock edges, so the ratio is exact - the
-- check requires |t(00) - 2 t(01)|, |t(01) - 2 t(10)| and |t(10) - 2 t(11)|
-- within one clk_bus period of that DS80 mode. Budget per phase: 9 ms
-- (turbo 00 needs ~4.2 ms at DS80 = 0, ~4.9 at DS80 = 1).
--
-- Per phase the run prints one line, per DS80 setting one line with the
-- four times; the last line is the verdict `tb_turbo_nowait: PASS` or
-- `tb_turbo_nowait: FAIL <reason>`. The chip model's violation counter
-- must stay zero over the whole run (the controller's b_overrun is tied
-- to open inside memory.vhd); the controller's sim-only assertions stop
-- GHDL with severity failure (the run script reports that as a FAIL too).
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

	-- the program (runs from the ROM window), see the header
	constant PROG_N : natural := 66;
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
		x"32", x"00", x"01",     -- LD (0x0100),A - a ROM address
		x"76"                    -- HALT
	);

	-- 256 loop writes + the sum + 16 INC (HL) + the two PUSH bytes + the
	-- ROM write (its bus cycle; the chip must not see the write itself)
	constant EXP_N : natural := 276;

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
		elsif i = 274 then
			return x"7FFE";
		else
			return x"0100";
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
		elsif i = 274 then
			return x"10";
		else
			return x"80";        -- LD (0x0100),A with the sum
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

	function hx6 (v : natural) return string is
		variable s : string(1 to 6);
		variable x : natural := v;
	begin
		for i in 0 to 5 loop
			s(6 - i) := HEX((x mod 16) + 1);
			x := x / 16;
		end loop;
		return s;
	end function;

	-- VHDL-93 has no image attributes on time/integer/boolean in GHDL's
	-- --std=93c: the report lines below use these small converters
	function bstr (b : in boolean) return string is
	begin
		if b then
			return "yes";
		else
			return "no";
		end if;
	end function;

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

	-- the memory unit (the controller inside it)
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

	-- U3: the real memory unit (paging map, cpu_wr_en, the no-wait
	-- controller inside it), wired as profi.vhd wires it; the loader and
	-- the GS/video ports are tied off, the paging inputs carry the plain
	-- Spectrum 128 map of the header. DI = DO is the profi wiring: the
	-- controller drives its dout early enough for the CPU's latch edge
	-- (checked for every read by tb_sdram_nowait).
	U_MEM: entity work.memory
	port map (
		CLK_BUS => clk_bus, CLK_SDR => clk_mem, ARESET => areset,
		ENA_CPU => ena_cpu, ENA_GS => '1',
		A => a_bus, D => do_bus,
		N_MREQ => mreq_n, N_IORQ => iorq_n, N_WR => wr_n, N_RD => rd_n,
		N_M1 => m1_n,
		loader_act => '0', loader_ram_a => (31 downto 0 => '0'),
		loader_ram_do => x"00", loader_ram_wr => '0',
		DO => di_bus, N_OE => open,
		GS_A => (20 downto 0 => '0'), GS_D => (7 downto 0 => '0'),
		GS_DO => open, GS_N_RD => '1', GS_N_WR => '1', GS_N_RFSH => '1',
		GS_MREQ_N => '1',
		BUS_PHASE => bus_phase, RESET_MEM => reset_mem,
		CPU_TS => ts_o, CPU_MC => mc_o, CPU_RESET_N => cpu_reset_n,
		MEM_READY => ready,
		SDR_BA => sd_ba, SDR_A => sd_a, SDR_DQM => sd_dqm,
		SDR_RAS_N => sd_ras_n, SDR_CAS_N => sd_cas_n, SDR_WE_N => sd_we_n,
		SDR_DQ => dq_bus,
		RAM_BANK => "000", RAM_EXT => "000", TRDOS => '0',
		VA => (13 downto 0 => '0'), VID_PAGE => '0', VID_DO => open,
		VID_RD => '0',
		DS80 => ds80, CPM => '0', SCO => '0', SCR => '0', WOROM => '0',
		ROM_BANK => '0', EXT_ROM_BANK => "00",
		COUNT_BLOCK => '0', CONTENDED => open,
		DIVMMC_EN => '0', AUTOMAP => '0', REG_E3 => x"00",
		TURBO_MODE => turbo
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
	-- this runs: the CPU is in reset and port B is tied off; refreshes
	-- never touch the array, so nothing races). ROM page "10" of ROM_BANK
	-- 0: SDRAM 0x108000 + A; RAM page "000101": SDRAM 0x14000 + A(13:0).
	-- The chip's byte_addr = {col, row, lane} = col * 2**14 + row * 2 +
	-- lane = addr(0): the chip index is the byte address (chip header)
	procedure preload_program is
	begin
		for i in 0 to PROG_N - 1 loop
			sdram_chip_mem(16#108000# + i) := PROG(i);
		end loop;
		for i in PROG_N to 511 loop
			sdram_chip_mem(16#108000# + i) := x"00";
		end loop;
		for i in 0 to 16383 loop
			sdram_chip_mem(16#14000# + i) := x"00";
		end loop;
	end procedure;

	-- the chip array after HALT: the RAM page must hold what the program
	-- computed, and the ROM byte LD (0x0100),A aimed at must be untouched
	-- (cpu_wr_en = 0 for ROM addresses at the controller's sample)
	procedure check_bytes (byte_bad : out boolean) is
		variable want : std_logic_vector(7 downto 0);
	begin
		byte_bad := false;
		for k in 0 to 15 loop
			want := std_logic_vector(to_unsigned((257 - k) mod 256, 8));
			if sdram_chip_mem(16#14000# + k) /= want then
				report "tb_turbo_nowait: chip[" & hx6(16#14000# + k)
					& "] = " & hx2(sdram_chip_mem(16#14000# + k))
					& ", expected " & hx2(want);
				byte_bad := true;
			end if;
		end loop;
		if sdram_chip_mem(16#15000#) /= x"80" then
			report "tb_turbo_nowait: chip[15000] = "
				& hx2(sdram_chip_mem(16#15000#)) & ", expected 80";
			byte_bad := true;
		end if;
		if sdram_chip_mem(16#17FFF#) /= x"40" or sdram_chip_mem(16#17FFE#) /= x"10" then
			report "tb_turbo_nowait: chip stack = "
				& hx2(sdram_chip_mem(16#17FFF#)) & ","
				& hx2(sdram_chip_mem(16#17FFE#)) & ", expected 40,10";
			byte_bad := true;
		end if;
		if sdram_chip_mem(16#108100#) /= x"00" then
			report "tb_turbo_nowait: ROM byte written: chip[108100] = "
				& hx2(sdram_chip_mem(16#108100#)) & ", expected 00";
			byte_bad := true;
		end if;
	end procedure;

	procedure run_phase (name        : in  string;
	                     tv          : in  std_logic_vector(1 downto 0);
	                     tbus_v      : inout time;
	                     halt_at     : inout time;
	                     phase_bad_v : inout boolean) is
		variable t0       : time;
		variable started  : boolean := false;
		variable halted   : boolean := false;
		variable trel     : time;
		variable byte_bad : boolean;
	begin
		-- fresh CPU reset for this turbo setting; the controller keeps
		-- running (refresh stays alive through the M1 and reset windows)
		cpu_reset_n <= '0';
		turbo       <= tv;
		halt_at     := 0 ns;    -- reported even when the phase does not halt
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
		check_bytes(byte_bad);
		phase_bad_v := (not halted) or mon_bad or mon_idx /= EXP_N
		               or viol /= 0 or byte_bad;
		report "tb_turbo_nowait: " & name & " halt at "
			& itos(halt_at / 1 ns) & " ns, " & itos(mon_idx) & "/"
			& itos(EXP_N) & " writes ok, halted=" & bstr(halted)
			& " seq_bad=" & bstr(mon_bad)
			& " bytes_bad=" & bstr(byte_bad) & " viol=" & itos(viol);
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
