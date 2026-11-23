-------------------------------------------------------------------------------
-- tb_rom_entry: which ROM page does the FIRST fetch of an entry address read?
-------------------------------------------------------------------------------
-- Run with: tools/sim.sh sim/run_tb_rom_entry.sh
--
-- The no-wait SDRAM controller (rtl/mem/sdram_nowait.vhd) latches the address
-- and with it the ROM/RAM page two clk_mem after T1 starts, before /MREQ falls.
-- Anything that picks a page from the M1 cycle itself must therefore be valid
-- at that sample. This bench runs the real T80s, the real memory unit
-- (rtl/replaced/memory.vhd + controller + chip model) and the real upstream
-- divmmc_map.vhd, plus a copy of profi.vhd's TR-DOS flag logic (dos_act,
-- dos_pre and the dos_early term of tools/prepare_upstream.py; generic EARLY
-- switches dos_early off to show that the bench catches the old behaviour),
-- and checks, at every turbo, the byte the CPU really executes first:
--   kind 0  TR-DOS (no DivMMC): JP #3Dxx from the 48 ROM. The first opcode must
--           come from the TR-DOS ROM (real Beta128; AMS.fdi relies on the RET at
--           #3D30).
--   kind 1  DivMMC: JP #3Dxx with the automap off. The map is immediate, the
--           first opcode must come from the DivMMC RAM window (#2000-#3FFF).
--   kind 2  DivMMC: JP #0008 / #0038 / #0066 with the automap off. The map comes
--           after the fetch: the first opcode is the main ROM's, the next one
--           the DivMMC ROM's.
-- Every case runs a program that ends with LD (#4000),A; HALT. The first opcode
-- is INC A in the "wrong" ROM and DEC A in the "right" one (kinds 0, 1: the
-- right one is DEC A; kind 2: INC A), so the marker byte tells which was
-- executed. Last line: `tb_rom_entry: PASS` or `tb_rom_entry: FAIL <reason>`.
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.sdram_chip_pkg.all;

entity tb_rom_entry is
	generic (EARLY : boolean := true; TRACE_KIND : natural := 99; TRACE_TGT : natural := 0);
end tb_rom_entry;

architecture sim of tb_rom_entry is

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

	function sl (b : boolean) return std_logic is begin if b then return '1'; else return '0'; end if; end function;
	constant EARLY_SL : std_logic := sl(EARLY);

	constant HEX : string := "0123456789abcdef";
	function hx2 (v : std_logic_vector(7 downto 0)) return string is
	begin
		return HEX(to_integer(unsigned(v(7 downto 4))) + 1)
		     & HEX(to_integer(unsigned(v(3 downto 0))) + 1);
	end function;
	function hx4 (v : natural) return string is
		variable s : string(1 to 4);
		variable x : natural := v;
	begin
		for i in 0 to 3 loop
			s(4 - i) := HEX((x mod 16) + 1);
			x := x / 16;
		end loop;
		return s;
	end function;

	signal clk50    : std_logic := '0';
	signal ds80     : std_logic := '0';
	signal turbo    : std_logic_vector(1 downto 0) := "00";
	signal areset   : std_logic;
	signal clk_bus, clk_mem : std_logic;
	signal bus_phase : std_logic_vector(1 downto 0);
	signal reset_mem : std_logic;
	signal ena_cpu   : std_logic;
	signal cpu_reset_n : std_logic := '0';
	signal m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n : std_logic;
	signal ts_o, mc_o : std_logic_vector(2 downto 0);
	signal a_bus  : std_logic_vector(15 downto 0);
	signal di_bus : std_logic_vector(7 downto 0) := (others => '0');
	signal do_bus : std_logic_vector(7 downto 0);
	signal ready  : std_logic;
	signal sd_ba  : std_logic_vector(1 downto 0);
	signal sd_a   : std_logic_vector(12 downto 0);
	signal sd_dqm : std_logic_vector(1 downto 0);
	signal sd_ras_n, sd_cas_n, sd_we_n : std_logic;
	signal dq_bus : std_logic_vector(15 downto 0);
	signal sdram_clk : std_logic;
	signal viol  : natural;
	signal n_ref : natural;

	-- profi.vhd's TR-DOS flag (copy of the process fragment and dos_pre)
	signal divmmc_en : std_logic := '0';
	signal dos_act, dos_pre, dos_early, dos_rom : std_logic := '0';
	signal automap, mapcond : std_logic;
	constant ROM14 : std_logic := '1';       -- 48 ROM selected by #7FFD
	signal hia : std_logic_vector(15 downto 8);
	signal map_rst : std_logic;
	signal dbg_on : std_logic := '0';


begin
	hia <= a_bus(15 downto 8);
	map_rst <= not cpu_reset_n;

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
		RESET_n => cpu_reset_n, CLK => clk_bus, CEN => ena_cpu,
		WAIT_n => '1', INT_n => '1', NMI_n => '1', BUSRQ_n => '1',
		M1_n => m1_n, MREQ_n => mreq_n, IORQ_n => iorq_n, RD_n => rd_n,
		WR_n => wr_n, RFSH_n => rfsh_n, HALT_n => halt_n, BUSAK_n => busak_n,
		OUT0 => '1', A => a_bus, DI => di_bus, DO => do_bus,
		TS_O => ts_o, MC_O => mc_o
	);

	-- TR-DOS flag, as profi.vhd (cpu_m1_n/cpu_mreq_n/hia; the 128 unlock, NMI,
	-- #DFFD and onrom terms are not needed here)
	process (clk_bus)
	begin
		if rising_edge(clk_bus) then
			if cpu_reset_n = '0' then
				dos_act <= '0';
			elsif m1_n = '0' and mreq_n = '0' and hia = x"3D" and ROM14 = '1' then
				dos_act <= '1';
			elsif m1_n = '0' and mreq_n = '0' and a_bus(15 downto 14) /= "00" then
				dos_act <= '0';
			end if;
			if m1_n = '0' and hia = x"3D" and ROM14 = '1' then
				dos_pre <= '1';
			else
				dos_pre <= '0';
			end if;
		end if;
	end process;
	dos_early <= '1' when (m1_n = '0' and hia = x"3D" and ROM14 = '1') else '0';
	dos_rom <= dos_act or (dos_pre and not mreq_n) or (dos_early and EARLY_SL);

	U_MAP: entity work.divmmc_map
	port map (CLK => clk_bus, RESET => map_rst, DIVMMC_EN => divmmc_en,
	          A => a_bus, M1_N => m1_n, MREQ_N => mreq_n,
	          MAPCOND => mapcond, AUTOMAP => automap);

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
		RAM_BANK => "000", RAM_EXT => "000", TRDOS => dos_rom,
		VA => (13 downto 0 => '0'), VID_PAGE => '0', VID_DO => open,
		VID_RD => '0',
		DS80 => ds80, CPM => '0', SCO => '0', SCR => '0', WOROM => '0',
		ROM_BANK => ROM14, EXT_ROM_BANK => "00",
		COUNT_BLOCK => '0', CONTENDED => open,
		DIVMMC_EN => divmmc_en, AUTOMAP => automap, REG_E3 => x"00",
		TURBO_MODE => turbo
	);

	sdram_clk <= not clk_mem after 1 ns;

	U_CHIP: sdram_chip
	generic map (ROWS => 64, REFRESH_US => 500.0)
	port map (
		clk => sdram_clk, cke => '1', cs_n => '0',
		ras_n => sd_ras_n, cas_n => sd_cas_n, we_n => sd_we_n,
		ba => sd_ba, a => sd_a, dqm => sd_dqm, dq => dq_bus,
		violations => viol, refreshes => n_ref
	);

	-- fetch log (the opcode the CPU latches at the end of T2), for the cases
	-- the generic TRACE selects: TRACE = kind*10000 + turbo
	dbg: process (clk_bus)
		variable last_m1 : std_logic := '1';
	begin
		if rising_edge(clk_bus) and dbg_on = '1' and ena_cpu = '1' then
			if m1_n = '0' and mreq_n = '0' and rd_n = '0' then
				report "fetch " & hx4(to_integer(unsigned(a_bus))) & " -> " & hx2(di_bus)
					& " automap=" & std_logic'image(automap) & " dos_rom=" & std_logic'image(dos_rom);
			end if;
		end if;
	end process;

main: process
	-- chip byte addresses (memory.vhd port1_a): ROM = "100" & EXT & rom_page & A,
	-- DivMMC ROM "1010000" & A(13:0), DivMMC RAM "11" & REG_E3(5:0) & A(12:0)
	constant ROM48 : natural := 16#10C000#;   -- rom_page "11"
	constant ROMDOS : natural := 16#104000#;  -- rom_page "01"
	constant DIVROM : natural := 16#140000#;
	constant DIVRAM : natural := 16#180000#;  -- bank 0
	constant MARK : natural := 16#14000#;     -- #4000 in RAM page 5
	constant TMAX : time := 150 us;

	variable bad : boolean := false;

	procedure rise (count : in natural) is
	begin
		for i in 1 to count loop
			wait until rising_edge(clk_bus);
		end loop;
	end procedure;

	procedure put (base : in natural; at : in natural; b : in std_logic_vector(7 downto 0)) is
	begin
		sdram_chip_mem(2 * (base + at)) := b;
	end procedure;

	-- the tail every path shares: LD (#4000),A ; HALT
	procedure tail (base : in natural; at : in natural) is
	begin
		put(base, at,     x"32");
		put(base, at + 1, x"00");
		put(base, at + 2, x"40");
		put(base, at + 3, x"76");
	end procedure;

	procedure fill is
	begin
		for i in 0 to 16383 loop
			sdram_chip_mem(2 * (ROM48 + i))  := x"76";
			sdram_chip_mem(2 * (ROMDOS + i)) := x"76";
			sdram_chip_mem(2 * (DIVROM + i)) := x"76";
		end loop;
		for i in 0 to 8191 loop
			sdram_chip_mem(2 * (DIVRAM + i)) := x"76";
		end loop;
		sdram_chip_mem(2 * (MARK)) := x"AA";
	end procedure;

	-- kind 0: 48 ROM #0000: XOR A; JP tgt. 48 ROM[tgt] = INC A, TR-DOS ROM[tgt]
	-- = DEC A; both continue with the tail
	procedure prog0 (tgt : in natural) is
	begin
		put(ROM48, 0, x"AF");
		put(ROM48, 1, x"C3");
		put(ROM48, 2, std_logic_vector(to_unsigned(tgt mod 256, 8)));
		put(ROM48, 3, std_logic_vector(to_unsigned(tgt / 256, 8)));
		put(ROM48, tgt, x"3C");
		put(ROMDOS, tgt, x"3D");
		tail(ROM48, tgt + 1);
		tail(ROMDOS, tgt + 1);
	end procedure;

	-- DivMMC start: the reset fetch at #0000 (main ROM, NOP) maps the DivMMC
	-- ROM for the next fetch: #0001 JP #1FF8; the fetch at #1FF8 clears the map,
	-- #1FF9 is main ROM again: XOR A; JP tgt
	procedure prolog1 (tgt : in natural) is
	begin
		put(ROM48, 0, x"00");
		put(DIVROM, 1, x"C3");
		put(DIVROM, 2, x"F8");
		put(DIVROM, 3, x"1F");
		put(DIVROM, 16#1FF8#, x"00");
		put(ROM48, 16#1FF9#, x"AF");
		put(ROM48, 16#1FFA#, x"C3");
		put(ROM48, 16#1FFB#, std_logic_vector(to_unsigned(tgt mod 256, 8)));
		put(ROM48, 16#1FFC#, std_logic_vector(to_unsigned(tgt / 256, 8)));
	end procedure;

	-- kind 1: tgt in #3Dxx: main ROM[tgt] = INC A, DivMMC RAM[tgt - #2000] = DEC A
	procedure prog1 (tgt : in natural) is
	begin
		prolog1(tgt);
		put(ROM48, tgt, x"3C");
		put(DIVRAM, tgt - 16#2000#, x"3D");
		tail(ROM48, tgt + 1);
		tail(DIVRAM, tgt + 1 - 16#2000#);
	end procedure;

	-- kind 2: tgt = #0008 ..: main ROM[tgt] = INC A, then DivMMC ROM[tgt] = DEC A
	-- and the tail only in the DivMMC ROM (the fetch after the entry is mapped)
	procedure prog2 (tgt : in natural) is
	begin
		prolog1(tgt);
		put(ROM48, tgt, x"3C");
		put(DIVROM, tgt, x"3D");
		tail(DIVROM, tgt + 1);
	end procedure;

	procedure run_case (kind : in natural; tgt : in natural; tv : in std_logic_vector(1 downto 0);
	                    expect : in std_logic_vector(7 downto 0)) is
		variable t0      : time;
		variable halted  : boolean := false;
		variable got     : std_logic_vector(7 downto 0);
		variable what    : string(1 to 6);
	begin
		cpu_reset_n <= '0';
		turbo <= tv;
		if kind = 0 then divmmc_en <= '0'; else divmmc_en <= '1'; end if;
		rise(8);
		fill;
		case kind is
			when 0 => prog0(tgt);
			when 1 => prog1(tgt);
			when others => prog2(tgt);
		end case;
		rise(6);
		t0 := now;
		if kind = TRACE_KIND and tgt = TRACE_TGT and tv = "11" then dbg_on <= '1'; else dbg_on <= '0'; end if;
		cpu_reset_n <= '1';
		watch: loop
			wait until rising_edge(clk_bus);
			if halt_n = '0' then halted := true; exit watch; end if;
			if now - t0 > TMAX then exit watch; end if;
		end loop watch;
		rise(8);
		got := sdram_chip_mem(2 * (MARK));
		if (not halted) or got /= expect then
			bad := true;
			report "tb_rom_entry: FAIL kind " & integer'image(kind) & " #" & hx4(tgt)
				& " turbo " & integer'image(to_integer(unsigned(tv)))
				& ": marker " & hx2(got) & ", expected " & hx2(expect)
				& " halted=" & boolean'image(halted);
		else
			report "tb_rom_entry: ok   kind " & integer'image(kind) & " #" & hx4(tgt)
				& " turbo " & integer'image(to_integer(unsigned(tv)));
		end if;
	end procedure;

	type nat_arr is array (natural range <>) of natural;
	constant T0 : nat_arr := (16#3D00#, 16#3D13#, 16#3D30#, 16#3D80#);
	constant T2 : nat_arr := (16#0008#, 16#0038#, 16#0066#);
begin
	fill;
	wait until areset = '0';
	wait until ready = '1';
	rise(8);
	rise(200);
	for tv in 0 to 3 loop
		for k in T0'range loop
			run_case(0, T0(k), std_logic_vector(to_unsigned(tv, 2)), x"FF");
		end loop;
		for k in T0'range loop
			run_case(1, T0(k), std_logic_vector(to_unsigned(tv, 2)), x"FF");
		end loop;
		for k in T2'range loop
			run_case(2, T2(k), std_logic_vector(to_unsigned(tv, 2)), x"01");
		end loop;
	end loop;
	if viol /= 0 then
		bad := true;
		report "tb_rom_entry: FAIL chip violations = " & integer'image(viol);
	end if;
	if bad then
		report "tb_rom_entry: FAIL (above)";
	else
		report "tb_rom_entry: PASS";
	end if;
	wait;
end process;

end sim;
