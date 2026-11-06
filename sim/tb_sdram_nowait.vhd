-------------------------------------------------------------------------------
-- tb_sdram_nowait: rtl/mem/sdram_nowait.vhd, the Stage 2 no-wait controller
-------------------------------------------------------------------------------
-- Run with: tools/sim.sh sim/run_tb_sdram_nowait.sh
--
-- The clock tree is the real one: pll_model + rtl/replaced/clock.vhd supply
-- clk_mem (CLK_SDR), clk_bus (CLK_BUS), BUS_PHASE, ENA_CPU (the T-state
-- enable) and RESET_MEM; TURBO and DS80 are driven as sim/tb_clock.vhd does.
-- SDRAM_CLK = not clk_mem delayed 1 ns (the top's altddio behaviour), and the
-- chip model sim/models/sdram_chip.vhd carries the timing checker: every case
-- must end with `violations = 0`. The chip runs with ROWS => 64 and
-- REFRESH_US => 500.0 (64 refreshes per 500 us = the 8192/64 ms rate with a
-- tighter sliding window), so the refresh-window rule is checked without a
-- 64 ms run; POWERUP_US and the rest keep their defaults, and the controller
-- init must respect the 100 us power-up.
--
-- The bus driver is a behavioural model of the T80s bus with T2Write = 1 and
-- IOWait = 1 (no T80 instance): it advances T-states only on edges where
-- ENA_CPU = 1, TS/MC/A/RD_n/WR_n/IORQ_n change at the edges T80s.vhd changes
-- them (RD_n/WR_n/IORQ_n low for the one clk_bus period between E1 and E2),
-- and DI is latched at the edge ending T2 - the first advancing edge with the
-- current TS = 2, exactly like T80s' `TState = 2 and Wait_n = '1'`. A DI
-- latch in a fetch/read cycle must equal the reference model; a write cycle
-- must latch the byte it writes (the controller's write forwarding) or the
-- old byte when the ROM mask stopped the write; an internal cycle latches
-- whatever cpu_dout holds (the last capture, the selector x"00" path of
-- profi.vhd); an I/O cycle latches the driver's I/O device value (the IORQ
-- arm of that mux). A WAIT_CPU request held inside T2 goes through clock.vhd
-- (ENA_CPU = 0 holds T2, the refresh windows keep running).
--
-- The alignment ruling is checked explicitly: at every clk_mem edge where the
-- controller samples (registered BUS_PHASE "01"), a clk_bus rising edge must
-- sit on the clk_mem edge exactly two before it.
--
-- When the script queue is empty the driver runs idle opcode fetches at the
-- top word of memory, so the M1 refresh window is always alive between and
-- inside cases; that word is never written by any case.
--
-- Cases, each printing one line (`tb_sdram_nowait: <case> ...: ok`), all at
-- turbo 00/01/10/11 x DS80 0/1 unless noted:
--   1 fetch_read_write  MIX_N random instructions over the whole 2 MiB:
--                       M1 + 0..4 following M-cycles, MC numbers the
--                       position (M2..M5); 8 % of the writes target ROM
--                       (wr_en = '0'); every DI latch except internal
--                       cycles is compared against the reference model,
--                       and memory reads / writes are counted per
--                       M-position (each of M2..M5 at least 100 times)
--   2 rmw_same_address  read X, write X+1 (same word, other lane), fetch X
--   3 back_to_back_writes to the same address and to different rows, read back
--   4 io_and_internal   I/O and internal M-cycles inside instructions
--                       after an M1 (MC = their M2..M5 position); I/O
--                       reads latch the device byte (the profi.vhd mux
--                       model), internal cycles have no DI check, reads
--                       after them must still be right; the memory must
--                       be unchanged by them (array check)
--   5 wait_in_t2 (turbo 11) memory read whose T2 is held 20 us by WAIT_CPU;
--                       the byte latched after the wait is right and at least
--                       two refreshes happened during it (the debt stays
--                       below 9 - the controller asserts it)
--   6 portb_under_8x (turbo 11) 300 port B writes one every 2 us while the
--                       mix runs, then CPU reads of every byte (every 40th
--                       read replaced by a fetch: the M1 window rule keeps
--                       the refresh debt alive even for pure read bursts);
--                       no overrun
--   7 portb_in_reset    4096 port B writes with cpu_reset_n = '0', one per 4
--                       clk_bus, then CPU reads of all of them, paced by a
--                       fetch every 40th like case 6
--   8 ds80_switch (turbo 11) the mix with DS80 toggled every 50 us
--
-- The verdict line `tb_sdram_nowait: PASS` / `tb_sdram_nowait: FAIL <reason>`
-- is always the last line; the sim-only assertions of the controller stop
-- GHDL with severity failure, which the run script reports as a FAIL too.
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.sdram_chip_pkg.all;

entity tb_sdram_nowait is
end tb_sdram_nowait;

architecture sim of tb_sdram_nowait is

	-- rtl/replaced/clock.vhd (the port list of sim/tb_clock.vhd); its pll
	-- component binds to sim/models/pll_model.vhd by default binding
	component clock is
	port (
		CLK			: in std_logic;
		DS80			: in std_logic;
		CLK_BUS		: buffer std_logic;
		CLK_8			: buffer std_logic;
		CLK_GS		: buffer std_logic;
		CLK_SDR		: buffer std_logic;
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

	constant T_REF   : time := 20 ns;         -- the MiSTer 50 MHz input clock
	constant MIX_N   : natural := 2000;       -- cycles of case 1
	constant PB_N    : natural := 300;        -- port B writes of case 6
	constant PB_BASE : natural := 4096;       -- their base address
	constant R7_N    : natural := 4096;       -- port B writes of case 7
	constant R7_BASE : natural := 8192;
	constant IDLE_WORD : natural := 2 * 1024 * 1024 - 2;  -- never written
	constant MIX_TOP : natural := 2 * 1024 * 1024 - 2;    -- mix addresses <
	constant QN      : natural := 4096;       -- script queue entries
	constant T2WAIT  : time := 20 us;         -- case 5's T2 hold

	type kind_t is (K_M1, K_M1X, K_RD, K_WR, K_IOR, K_IOW, K_INT);
	type cyc_t is record
		k    : kind_t;
		a    : natural;
		we   : std_logic;
		d    : std_logic_vector(7 downto 0);
		stay : time;               -- WAIT_CPU time asserted at E1 (0: none)
		mc   : std_logic_vector(2 downto 0);  -- the T80 M-cycle number
	end record;
	constant CYC_NOP : cyc_t :=
		(K_INT, 0, '1', (others => '0'), 0 ns, "000");

	-- the script queue (main pushes, the driver pops at each cycle end)
	type cyc_q_t is array (0 to QN - 1) of cyc_t;
	shared variable q      : cyc_q_t := (others => CYC_NOP);
	shared variable qi, qh : natural := 0;

	-- the reference memory model; every write path is mirrored into it
	shared variable ref : chip_byte_array := (others => (others => 'U'));
	-- memory accesses per M-position (the MC number of the cycle)
	type poscnt_t is array (2 to 5) of natural;
	shared variable cnt_rd : poscnt_t := (others => 0);
	shared variable cnt_wr : poscnt_t := (others => 0);

	-- results
	shared variable bad     : boolean := false;
	shared variable nbad    : natural := 0;
	shared variable n_latch : natural := 0;    -- DI latches
	shared variable be      : natural := 0;    -- clk_bus rising edges
	shared variable ds80_run : boolean := false;
	shared variable ds80_want : std_logic := '0';
	shared variable mon_on   : boolean := false;

	shared variable seed : unsigned(31 downto 0) :=
		to_unsigned(107303923, 32);

	-- the 50 MHz MiSTer clock
	signal clk50 : std_logic := '0';

	-- clock.vhd
	signal ds80      : std_logic := '0';
	signal turbo     : std_logic_vector(1 downto 0) := "11";
	signal wait_cpu  : std_logic := '0';
	signal clk_bus   : std_logic;
	signal clk_mem   : std_logic;
	signal bus_phase : std_logic_vector(1 downto 0);
	signal reset_mem : std_logic;
	signal ena_cpu   : std_logic;
	signal areset    : std_logic;

	-- controller boundary (the T80s-shaped bus, driver -> controller)
	signal cpu_reset_n : std_logic := '0';
	signal ts_o  : std_logic_vector(2 downto 0) := "000";
	signal mc_o  : std_logic_vector(2 downto 0) := "000";
	signal rd_n_o, wr_n_o, iorq_n_o, mreq_n_o : std_logic := '1';
	signal cpu_addr  : std_logic_vector(20 downto 0) := (others => '0');
	signal cpu_wr_en : std_logic := '1';
	signal cpu_din   : std_logic_vector(7 downto 0) := (others => '0');
	signal cpu_dout  : std_logic_vector(7 downto 0);
	signal b_req   : std_logic := '0';
	signal b_we    : std_logic := '0';
	signal b_addr  : std_logic_vector(20 downto 0) := (others => '0');
	signal b_din   : std_logic_vector(7 downto 0) := (others => '0');
	signal b_dout  : std_logic_vector(7 downto 0);
	signal b_done  : std_logic;
	signal b_over  : std_logic;
	signal ready   : std_logic;

	-- SDRAM pins
	signal sd_ba  : std_logic_vector(1 downto 0);
	signal sd_a   : std_logic_vector(12 downto 0);
	signal sd_dqm : std_logic_vector(1 downto 0);
	signal sd_ras_n, sd_cas_n, sd_we_n : std_logic;
	signal dq_bus : std_logic_vector(15 downto 0);
	signal sdram_clk : std_logic;

	signal viol  : natural;
	signal n_ref : natural;

	-- the alignment ruling: every clk_bus rising edge is stamped here
	signal t_bus_rise : time := 0 ns;


	function slv21 (v : natural) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned(v, 21));
	end function;

	function io_val (v : natural) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned((v * 131 + 7) mod 256, 8));
	end function;

	function hx4 (v : std_logic_vector(3 downto 0)) return string is
	begin
		case v is
			when "0000" => return "0"; when "0001" => return "1";
			when "0010" => return "2"; when "0011" => return "3";
			when "0100" => return "4"; when "0101" => return "5";
			when "0110" => return "6"; when "0111" => return "7";
			when "1000" => return "8"; when "1001" => return "9";
			when "1010" => return "a"; when "1011" => return "b";
			when "1100" => return "c"; when "1101" => return "d";
			when "1110" => return "e"; when "1111" => return "f";
			when others => return "?";
		end case;
	end function;

	function img8 (v : std_logic_vector(7 downto 0)) return string is
	begin
		return hx4(v(7 downto 4)) & hx4(v(3 downto 0));
	end function;

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
	CLK_BUS => clk_bus, CLK_8 => open, CLK_GS => open, CLK_SDR => clk_mem,
	CLK_12 => open, CLK_RGB => open, CLK_VGA => open, CLK_ADC => open,
	ENA_DIV2 => open, ENA_DIV4 => open, ENA_DIV8 => open, ENA_DIV16 => open,
	ENA_DIV2N => open, ENA_DIV4N => open, ENA_DIV8N => open,
	ENA_DIV16N => open,
	ENA_CPU => ena_cpu, ENA_CPU_N => open, ENA_RGB => open,
	CE_14 => open, CE_8 => open,
	TURBO => turbo, WAIT_CPU => wait_cpu, ARESET => areset,
	CLK_VID => open, BUS_PHASE => bus_phase, RESET_MEM => reset_mem
);

U2: sdram_nowait port map (
	clk_mem => clk_mem, reset => reset_mem, bus_phase => bus_phase,
	ready => ready,
	cpu_reset_n => cpu_reset_n, cpu_ena => ena_cpu,
	cpu_ts => ts_o, cpu_mc => mc_o,
	cpu_mreq_n => mreq_n_o, cpu_rd_n => rd_n_o, cpu_wr_n => wr_n_o,
	cpu_iorq_n => iorq_n_o,
	cpu_addr => cpu_addr, cpu_wr_en => cpu_wr_en, cpu_din => cpu_din,
	cpu_dout => cpu_dout,
	b_req => b_req, b_we => b_we, b_addr => b_addr, b_din => b_din,
	b_dout => b_dout, b_done => b_done, b_overrun => b_over,
	sd_ba => sd_ba, sd_a => sd_a, sd_dqm => sd_dqm,
	sd_ras_n => sd_ras_n, sd_cas_n => sd_cas_n, sd_we_n => sd_we_n,
	sd_dq => dq_bus
);

sdram_clk <= not clk_mem after 1 ns;

U3: sdram_chip
	generic map (ROWS => 64, REFRESH_US => 500.0)  -- the 8192/64 ms rate with
	port map (                                     -- a tight window
	clk => sdram_clk, cke => '1', cs_n => '0',
	ras_n => sd_ras_n, cas_n => sd_cas_n, we_n => sd_we_n,
	ba => sd_ba, a => sd_a, dqm => sd_dqm, dq => dq_bus,
	violations => viol, refreshes => n_ref
);

-- the single driver of ds80: it holds ds80_want, and flips every 50 us
-- while case 8 runs (two drivers would resolve ds80 to 'X' and kill the
-- clock mux - this process owns the signal alone)
dsflip: process
begin
	loop
		if ds80_run then
			wait for 50 us;
			ds80 <= not ds80;
		else
			wait for 200 ns;
			ds80 <= ds80_want;
		end if;
	end loop;
end process;

-- stamps every clk_bus rising edge
busst: process (clk_bus)
begin
	if rising_edge(clk_bus) then
		t_bus_rise <= now;
	end if;
end process;

-- the ruling of the sample edge: at every clk_mem edge whose registered
-- BUS_PHASE is "01" (read pre-edge, exactly as the controller reads it) a
-- clk_bus rising edge must sit on the clk_mem edge two before this one
mon: process (clk_mem)
	variable phase_bad : boolean := false;
	variable tm1, tm2  : time := 0 ns;
begin
	if rising_edge(clk_mem) then
		if mon_on and bus_phase = "01" and not phase_bad then
			if t_bus_rise /= tm2 then
				phase_bad := true;
				bad := true;
				nbad := nbad + 1;
				report "tb_sdram_nowait: FAIL sample alignment at t"
					& integer'image(now / 1 ns) & " ns: the clk_bus rise is not"
					& " two clk_mem back" severity error;
			end if;
		end if;
		tm2 := tm1;
		tm1 := now;
	end if;
end process;

-- the T80s-shaped bus driver: a behavioural model, no T80 instance
bus_drv: process (clk_bus)
	variable kind       : kind_t := K_M1;
	variable cmc        : std_logic_vector(2 downto 0) := "001";
	variable ts         : natural range 0 to 7 := 0;
	variable hold       : natural range 0 to 2 := 0;
	variable cadr       : natural range 0 to 2 * 1024 * 1024 - 1 := 0;
	variable cwe        : std_logic := '1';
	variable cdin       : std_logic_vector(7 downto 0) := (others => '0');
	variable cstay      : time := 0 ns;
	variable hold_until : time := 0 ns;
	variable gap        : natural range 0 to 15 := 0;
	variable di         : std_logic_vector(7 downto 0);
	variable expd       : std_logic_vector(7 downto 0);

	procedure pop is
		variable e : cyc_t;
	begin
		e := q(qi mod QN);
		qi := qi + 1;
		kind := e.k;
		cmc := e.mc;
		cadr := e.a;
		cwe  := e.we;
		cdin := e.d;
		cstay := e.stay;
	end procedure;

	procedure start_cyc is
	begin
		ts := 1;
		ts_o <= "001";
		mc_o <= cmc;
		cpu_addr <= slv21(cadr);
		cpu_wr_en <= cwe;
		cpu_din <= cdin;
		rd_n_o <= '1'; wr_n_o <= '1'; iorq_n_o <= '1'; mreq_n_o <= '1';
		if kind = K_M1X then
			hold := 2;                    -- two extra live edges held in T2
		elsif kind = K_IOR or kind = K_IOW then
			hold := 1;                    -- the IOWait = 1 auto wait
		else
			hold := 0;
		end if;
	end procedure;

	-- the edge that ends the last T-state: the next scripted cycle, else an
	-- idle opcode fetch (keeps the M1 refresh window alive)
	procedure end_cyc is
	begin
		if kind = K_WR and cwe = '1' then
			ref(cadr) := cdin;            -- the reference commits the write
		end if;
		if qh > qi then
			pop;
			start_cyc;
		else
			kind := K_M1;
			cmc := "001";
			cadr := IDLE_WORD;
			cwe := '1';
			cdin := (others => '0');
			cstay := 0 ns;
			start_cyc;
		end if;
	end procedure;

begin
	if rising_edge(clk_bus) then
		be := be + 1;
		if wait_cpu = '1' and now >= hold_until then
			wait_cpu <= '0';
		end if;
		if cpu_reset_n = '0' then
			ts := 0;
			gap := 0;
			ts_o <= "000";
			mc_o <= "000";
			rd_n_o <= '1'; wr_n_o <= '1'; iorq_n_o <= '1'; mreq_n_o <= '1';
			cpu_addr <= (others => '0');
			cpu_wr_en <= '1';
			cpu_din <= (others => '0');
		elsif ena_cpu = '1' then
			if gap < 4 then
				gap := gap + 1;   -- post-reset settling (the window (c) rule)
			elsif ts = 0 then
				if qh > qi then
					pop;
					start_cyc;
				end if;
			else
				case ts is
					when 1 =>
						ts := 2;
						ts_o <= "010";
						case kind is
							when K_M1 | K_M1X | K_RD =>
								rd_n_o <= '0'; mreq_n_o <= '0';
							when K_WR =>
								wr_n_o <= '0'; mreq_n_o <= '0';
							when K_IOR =>
								rd_n_o <= '0'; iorq_n_o <= '0';
							when K_IOW =>
								wr_n_o <= '0'; iorq_n_o <= '0';
							when K_INT =>
								null;
						end case;
						if cstay > 0 ns then
							wait_cpu <= '1';
							hold_until := now + cstay;
							cstay := 0 ns;
						end if;
					when 2 =>
						-- the DI latch edge (T80s: TState = 2, Wait_n = '1')
						if kind = K_IOR or kind = K_IOW then
							di := io_val(cadr);   -- profi.vhd's I/O mux
						else
							di := cpu_dout;
						end if;
						case kind is
							when K_IOR | K_IOW =>
								expd := io_val(cadr);
							when K_WR =>
								if cwe = '1' then
									expd := cdin;   -- the write forwarding
								else
									expd := ref(cadr);
								end if;
							when K_INT =>
								null;     -- no DI check: the T80 ignores it
							when others =>          -- M1, M1X, RD
								expd := ref(cadr);
						end case;
						if kind /= K_INT then
							n_latch := n_latch + 1;
							if kind = K_RD then
								cnt_rd(to_integer(unsigned(cmc))) :=
									cnt_rd(to_integer(unsigned(cmc))) + 1;
							elsif kind = K_WR then
								cnt_wr(to_integer(unsigned(cmc))) :=
									cnt_wr(to_integer(unsigned(cmc))) + 1;
							end if;
							if di /= expd then
								bad := true;
								nbad := nbad + 1;
								report "tb_sdram_nowait: FAIL DI latch at t"
									& integer'image(now / 1 ns) & " ns: kind "
									& integer'image(kind_t'pos(kind))
									& " mc "
									& integer'image(to_integer(unsigned(cmc)))
									& " addr " & integer'image(cadr)
									& " got " & img8(di) & " want " & img8(expd)
									severity error;
							end if;
						end if;
						if kind = K_IOR or kind = K_IOW then
							-- T80s: RD/WR/IORQ were a one-period pulse
							rd_n_o <= '1'; wr_n_o <= '1'; iorq_n_o <= '1';
						end if;
						if hold > 0 then
							hold := hold - 1;
						else
							ts := 3;
							ts_o <= "011";
							rd_n_o <= '1'; wr_n_o <= '1';
							iorq_n_o <= '1'; mreq_n_o <= '1';
						end if;
					when 3 =>
						if kind = K_RD or kind = K_WR or kind = K_INT then
							end_cyc;
						else
							ts := 4;
							ts_o <= "100";
							if kind = K_M1 or kind = K_M1X then
								mreq_n_o <= '0';  -- the M1 refresh phase
							end if;
						end if;
					when others =>
						end_cyc;
				end case;
			end if;
		end if;
	end if;
end process;

main: process

	-- one failed check; every FAIL names itself, the verdict line comes at
	-- the end
	procedure check (cond : boolean; msg : string) is
	begin
		if not cond then
			bad := true;
			nbad := nbad + 1;
			report "tb_sdram_nowait: FAIL " & msg severity error;
		end if;
	end procedure;

	procedure rnd_reset is
	begin
		seed := to_unsigned(107303923, 32);
	end procedure;

	-- deterministic LCG draw in [0, n): 64-bit state, the draw takes the
	-- high bits (the weak part of an LCG is its low bits)
	impure function rnd (n : natural) return natural is
		variable p : unsigned(63 downto 0);
		variable m : unsigned(30 downto 0);
	begin
		p := seed * to_unsigned(1664525, 32);  -- 32 x 32 -> 64 wide
		p := p + to_unsigned(1013904223, 64);
		seed := p(31 downto 0);
		m := p(62 downto 32) mod to_unsigned(n, 31);
		return to_integer(m);
	end function;

	procedure push (
		constant k    : kind_t;
		constant a    : natural;
		constant we   : std_logic := '1';
		constant d    : std_logic_vector(7 downto 0) := (others => '0');
		constant stay : time := 0 ns;
		constant mc   : std_logic_vector(2 downto 0) := "010"
	) is
	begin
		if k = K_M1 or k = K_M1X then
			q(qh mod QN) := (k, a, we, d, stay, "001");
		else
			q(qh mod QN) := (k, a, we, d, stay, mc);
		end if;
		qh := qh + 1;
		while qh - qi > 3000 loop
			wait for 100 ns;
		end loop;
	end procedure;

	procedure wait_idle (constant tag : string) is
	begin
		for i in 1 to 60000 loop
			if qi >= qh then
				return;
			end if;
			wait for 100 ns;
		end loop;
		check(false, tag & ": the driver never finished the script");
		qi := qh;
	end procedure;

	procedure wait_be (constant n : natural) is
		variable target : natural;
	begin
		target := be + n;
		for i in 1 to 4000 loop
			if be >= target then
				return;
			end if;
			wait for 5 ns;
		end loop;
		check(false, "clk_bus edges stalled");
	end procedure;

	procedure line_end (constant tag : string; constant bad0 : natural) is
	begin
		if nbad = bad0 then
			report "tb_sdram_nowait: " & tag & ": ok";
		else
			report "tb_sdram_nowait: FAIL " & tag & " (see the errors above)"
				severity error;
		end if;
	end procedure;

	impure function mix_addr (constant reserve : boolean) return natural is
		variable a : natural;
	begin
		a := rnd(MIX_TOP);
		if reserve and a >= PB_BASE and a < PB_BASE + PB_N + 16 then
			a := (a + PB_BASE + PB_N + 16) mod MIX_TOP;
		end if;
		return a;
	end function;

	-- one random instruction: an M1 (sometimes with two extra wait edges
	-- in T2) plus 0..4 further M-cycles; MC is the position number, as on
	-- the real T80 (the M-cycle counter is binary, not a kind code)
	procedure push_mix (constant reserve : boolean) is
		variable k   : kind_t;
		variable r   : natural;
		variable len : natural range 1 to 5;
		variable we  : std_logic;
	begin
		r := rnd(100);
		if    r < 25 then len := 1;
		elsif r < 50 then len := 2;
		elsif r < 70 then len := 3;
		elsif r < 85 then len := 4;
		else len := 5;
		end if;
		if rnd(100) < 8 then
			push(K_M1X, mix_addr(reserve));
		else
			push(K_M1, mix_addr(reserve));
		end if;
		for p in 2 to len loop
			r := rnd(100);
			if p = len and len >= 3 then
				-- the tail of a longer instruction favours memory
				if    r < 45 then k := K_RD;
				elsif r < 88 then k := K_WR;
				elsif r < 91 then k := K_IOR;
				elsif r < 94 then k := K_IOW;
				else k := K_INT;
				end if;
			else
				if    r < 30 then k := K_RD;
				elsif r < 60 then k := K_WR;
				elsif r < 72 then k := K_IOR;
				elsif r < 78 then k := K_IOW;
				else k := K_INT;
				end if;
			end if;
			we := '0';
			if rnd(100) < 88 then
				we := '1';
			end if;
			push(k, mix_addr(reserve), we,
				std_logic_vector(to_unsigned(rnd(256), 8)),
				0 ns, std_logic_vector(to_unsigned(p, 3)));
		end loop;
	end procedure;

	-- one port B access: b_req rising, completion on the b_done toggle
	procedure b_access (
		constant a  : natural;
		constant d  : std_logic_vector(7 downto 0);
		constant we : std_logic
	) is
		variable dt : std_logic;
	begin
		b_addr <= slv21(a);
		b_din  <= d;
		dt := b_done;
		b_we   <= we;
		b_req  <= '1';
		wait_be(1);
		wait on b_done for 300 us;
		check(b_done /= dt, "port B access of " & integer'image(a)
			& " never completed");
		b_req <= '0';
		b_we  <= '0';
		if we = '1' then
			ref(a) := d;   -- the reference model mirrors port B writes
		end if;
	end procedure;

	variable v      : std_logic_vector(7 downto 0);
	variable bad0   : natural;
	variable n0     : natural;
	variable mism   : natural;
	variable t_init : time := 0 ns;
	variable cr     : poscnt_t;
	variable cw     : poscnt_t;
begin

	-- the reference model and the chip boot with the same pattern (back
	-- door: the model only decodes what arrives on the pins)
	for i in 0 to SDRAM_CHIP_BYTES - 1 loop
		v := std_logic_vector(to_unsigned((i * 31 + i / 251) mod 256, 8));
		ref(i) := v;
		sdram_chip_mem(i) := v;
	end loop;

	wait until reset_mem = '0' for 1 ms;
	check(reset_mem = '0', "RESET_MEM never released");
	t_init := now;
	wait until ready = '1' for 400 us;
	if ready /= '1' then
		bad := true;
		nbad := nbad + 1;
		report "tb_sdram_nowait: FAIL init: the controller never became ready"
			severity error;
		report "tb_sdram_nowait: FAIL (init)" severity error;
		wait;
	end if;
	-- the power-up rule: init must keep every command out of the chip's
	-- 100 us (the chip would count a violation; this is the human half)
	report "tb_sdram_nowait: ready at " & integer'image(now / 1 ns)
		& " ns (RESET_MEM low since " & integer'image(t_init / 1 ns)
		& " ns)";
	check(now >= 100 us, "ready rose inside the 100 us power-up window");
	mon_on := true;
	cpu_reset_n <= '1';

cfgs:
	for dd in 0 to 1 loop
		for tt in 0 to 3 loop
			case tt is
				when 0 => turbo <= "00";
				when 1 => turbo <= "01";
				when 2 => turbo <= "10";
				when others => turbo <= "11";
			end case;
			ds80_want := '0';
			if dd = 1 then
				ds80_want := '1';
			end if;
			wait for 300 ns;
			rnd_reset;

			-- case 1: the long random instruction stream; the case line
			-- prints the memory accesses per M-position (M2..M5)
			bad0 := nbad;
			cr := cnt_rd;
			cw := cnt_wr;
			for i in 1 to MIX_N loop
				push_mix(false);
			end loop;
			wait_idle("case1");
			for p in 2 to 5 loop
				check(cnt_rd(p) - cr(p) >= 100,
					"case1: only " & integer'image(cnt_rd(p) - cr(p))
					& " memory reads at position M" & natural'image(p));
				check(cnt_wr(p) - cw(p) >= 100,
					"case1: only " & integer'image(cnt_wr(p) - cw(p))
					& " memory writes at position M" & natural'image(p));
			end loop;
			line_end("case1 fetch_read_write t" & natural'image(tt)
				& " d" & natural'image(dd)
				& " r" & natural'image(cnt_rd(2) - cr(2))
				& "," & natural'image(cnt_rd(3) - cr(3))
				& "," & natural'image(cnt_rd(4) - cr(4))
				& "," & natural'image(cnt_rd(5) - cr(5))
				& " w" & natural'image(cnt_wr(2) - cw(2))
				& "," & natural'image(cnt_wr(3) - cw(3))
				& "," & natural'image(cnt_wr(4) - cw(4))
				& "," & natural'image(cnt_wr(5) - cw(5)), bad0);

			-- case 2: read X, write X+1 (same word, other lane), fetch X
			bad0 := nbad;
			push(K_RD, 700002);
			push(K_WR, 700003, '1', x"9E");
			push(K_M1, 700002);
			wait_idle("case2");
			check(sdram_chip_mem(700002) = ref(700002),
				"case2: lane 0 survived the masked write");
			check(sdram_chip_mem(700003) = x"9E",
				"case2: lane 1 holds the written byte");
			line_end("case2 rmw_same_address t" & natural'image(tt)
				& " d" & natural'image(dd), bad0);

			-- case 3: back-to-back writes, same address, different rows
			bad0 := nbad;
			push(K_WR, 131072, '1', x"11");
			push(K_WR, 131072, '1', x"22");
			push(K_WR, 131072, '1', x"33");
			push(K_WR, 131072 + 2 * 8192, '1', x"44");
			push(K_RD, 131072);
			push(K_RD, 131072 + 2 * 8192);
			push(K_M1, 131072);
			push(K_RD, 131073);
			push(K_M1, 131073);
			wait_idle("case3");
			line_end("case3 back_to_back_writes t" & natural'image(tt)
				& " d" & natural'image(dd), bad0);

			-- case 4: I/O and internal M-cycles inside instructions (MC
			-- numbers their position after the M1 of the instruction)
			bad0 := nbad;
			push(K_M1, 900004);
			push(K_IOR, 16#3B#, '1', x"00", 0 ns, "010");
			push(K_M1, 900006);
			push(K_INT, 0, '1', x"00", 0 ns, "010");
			push(K_WR, 900040, '1', x"5A", 0 ns, "011");
			push(K_M1, 900010);
			push(K_IOW, 16#1F#, '1', x"77", 0 ns, "010");
			push(K_INT, 0, '1', x"00", 0 ns, "011");
			push(K_RD, 900040, '1', x"00", 0 ns, "100");
			push(K_M1, 900080);
			push(K_WR, 900120, '0', x"12", 0 ns, "010");  -- ROM: no write
			push(K_IOR, 16#7E#, '1', x"00", 0 ns, "011");
			push(K_INT, 0, '1', x"00", 0 ns, "100");
			push(K_RD, 900120, '1', x"00", 0 ns, "101");
			wait_idle("case4");
			check(sdram_chip_mem(900120) = ref(900120),
				"case4: the ROM write left the array alone");
			line_end("case4 io_and_internal t" & natural'image(tt)
				& " d" & natural'image(dd), bad0);

			if tt = 3 then
				-- case 5: a memory read with T2 held 20 us by WAIT_CPU
				bad0 := nbad;
				push(K_M1, 500000);
				wait_idle("case5-pre");
				n0 := n_ref;
				push(K_RD, 500200, '1', x"00", T2WAIT);
				push(K_M1, 500208);
				wait_idle("case5");
				check(n_ref >= n0 + 2,
					"case5: fewer than 2 refreshes during the 20 us wait");
				line_end("case5 wait_in_t2 d" & natural'image(dd), bad0);
			end if;

			-- case 7 before case 6: case 6 ends with CPU reads, and case 7
			-- resets the CPU (the order of the brief is kept below)

			if tt = 3 then
				-- case 6: port B writes under the running mix at turbo 11
				bad0 := nbad;
				rnd_reset;
				for i in 1 to 600 loop
					push_mix(true);
				end loop;
				for i in 0 to PB_N - 1 loop
					wait for 2 us;
					v := std_logic_vector(to_unsigned((i * 29 + 3) mod 256, 8));
					b_access(PB_BASE + i, v, '1');
				end loop;
				wait_idle("case6-mix");
				-- the M1 rule of the design: even a pure read burst lives on
				-- the fetch windows, so every 40th cycle is a fetch (480 clk
				-- stay under the 700 clk refresh clock)
				for i in 0 to PB_N - 1 loop
					if i mod 40 = 39 then
						push(K_M1, IDLE_WORD);
					end if;
					push(K_RD, PB_BASE + i);
				end loop;
				wait_idle("case6-read");
				line_end("case6 portb_under_8x d" & natural'image(dd), bad0);
			end if;

			-- case 7: port B while the CPU sits in reset, then CPU reads
			bad0 := nbad;
			cpu_reset_n <= '0';
			wait_be(2);
			for i in 0 to R7_N - 1 loop
				v := std_logic_vector(to_unsigned((i * 57 + 9) mod 256, 8));
				b_access(R7_BASE + i, v, '1');
				wait_be(2);
			end loop;
			cpu_reset_n <= '1';
			for i in 0 to R7_N - 1 loop
				if i mod 40 = 39 then
					push(K_M1, IDLE_WORD);
				end if;
				push(K_RD, R7_BASE + i);
			end loop;
			wait_idle("case7");
			line_end("case7 portb_in_reset t" & natural'image(tt)
				& " d" & natural'image(dd), bad0);

			if tt = 3 then
				-- case 8: the mix while DS80 flips every 50 us
				bad0 := nbad;
				rnd_reset;
				ds80_run := true;
				for i in 1 to 800 loop
					push_mix(false);
				end loop;
				wait_idle("case8");
				ds80_run := false;
				wait for 400 ns;          -- let dsflip restore ds80_want
				line_end("case8 ds80_switch", bad0);
			end if;
		end loop;
	end loop;

	wait_be(4);
	wait for 60 us;

	-- the global checks
	check(viol = 0, "the chip model counted " & natural'image(viol)
		& " timing violations");
	check(b_over = '0', "b_overrun was asserted");
	check(n_latch > 10000, "the driver latched only " & natural'image(n_latch)
		& " DI bytes - the mix did not run");
	check(n_ref > MIX_N, "only " & natural'image(n_ref)
		& " refreshes over the whole run");

	mism := 0;
	for i in 0 to SDRAM_CHIP_BYTES - 1 loop
		if sdram_chip_mem(i) /= ref(i) then
			if mism < 8 then
				report "tb_sdram_nowait: FAIL array mismatch at "
					& integer'image(i) & ": chip " & img8(sdram_chip_mem(i))
					& " want " & img8(ref(i)) severity error;
			end if;
			mism := mism + 1;
		end if;
	end loop;
	check(mism = 0, natural'image(mism) & " array bytes differ from the model");

	report "tb_sdram_nowait: " & natural'image(n_latch) & " DI latches, "
		& natural'image(n_ref) & " refreshes, " & integer'image(now / 1 us)
		& " us simulated";

	if bad then
		report "tb_sdram_nowait: FAIL (" & natural'image(nbad)
			& " problems, see above)" severity error;
	else
		report "tb_sdram_nowait: PASS";
	end if;
	wait;
end process;

end sim;
