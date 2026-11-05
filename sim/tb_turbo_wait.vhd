-------------------------------------------------------------------------------
-- tb_turbo_wait: the CPU held by the SDRAM bridge's wait path (system check)
-------------------------------------------------------------------------------
-- Run with: tools/sim.sh sim/run_tb_turbo_wait.sh
--           tools/sim.sh sim/run_tb_turbo_wait.sh -gWAIT_EN=false    (RED run)
--
-- The board run (docs/dev/stage1-results.md, finding 3) saw every turbo setting
-- hang: the bridge answers a read about 7 to 9 clk_bus clocks after rd_req rises
-- (the sdram model runs at the 6 clk_sdr read access of the real sdram.sv, see
-- its header), while the T80 latches its DI register 8 clocks after rd_req rises
-- and a turbo 2x T-state is only 4 clocks, so the CPU latched bytes that had not
-- arrived. This TB runs the units of the fix together the way
-- profi.vhd wires them - clock + pll model, the upstream T80s, cdc_fifo +
-- sram_bridge + the sdram client model - and drives a self-checking Z80 program
-- through them at every turbo setting.
--
-- Wiring (profi.vhd, memory.vhd): T80s CLK => clk_bus, CEN => ENA_CPU,
-- WAIT_n => the gated cpu_wait (profi's second half: the DI_Reg latch is
-- `TState = 2 and Wait_n = '1'`, and at turbo "11" one T-state is one clk_bus,
-- so only WAIT_n can stop the edge that samples DI), INT_n/NMI_n/BUSRQ_n => '1';
-- the bridge is read by
-- rd_req = not MREQ_n and not RD_n and written by
-- wr_stb = not MREQ_n and not WR_n and ENA_CPU (memory.vhd's port1_wr) at
-- addr = "00000" & A; DI = the bridge's dout; WAIT_CPU = cpu_wait while turbo
-- is on (the profi.vhd rewrite) and '0' at turbo "00" - and with
-- -gWAIT_EN=false cut entirely, which is the state of the board run: turbo
-- "01" and above must then fail (wrong data or no HALT) while "00" passes
-- (its reads are 2 T-states, longer than the bridge round trip).
--
-- Before the CPU reset is released the program is loaded into the bridge with
-- wr_stb, one byte every few clocks and never a strobe while the queue is
-- almost full (cpu_wait). Every CPU write cycle - the strobes of one cycle are
-- split by WR_n rising - is compared against the expected sequence: 256 writes
-- to 0x4000+i with data (256 - i) mod 256, then 0x5000 <- 0x80 (the sum of
-- 0..255), 0x7FFF <- 0x41 and 0x7FFE <- 0x00 (PUSH HL, HL = 0x4100). Then
-- HALT_n must fall and the sequence be complete within the per-turbo budget
-- (generous; turbo "00" alone needs about 4.2 ms of Z80 time):
--
--   turbo "00": 6 ms   "01": 4 ms   "10": 3 ms   "11": 3 ms
--
-- One line per turbo with the simulated time to HALT, then the verdict
-- `tb_turbo_wait: PASS` or `tb_turbo_wait: FAIL <reason>`.
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.sdram_model_pkg.all;

entity tb_turbo_wait is
generic (
	WAIT_EN : boolean := true    -- false: no wait path at all (RED run)
);
end tb_turbo_wait;

architecture sim of tb_turbo_wait is

	-- rtl/replaced/clock.vhd (the upstream port list, as in sim/tb_clock.vhd);
	-- its pll component binds to sim/models/pll_model.vhd by default binding.
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

	-- the program (load at 0x0000), see the expected sequence above
	constant PROG_N : natural := 28;
	type prog_t is array (0 to PROG_N - 1) of std_logic_vector(7 downto 0);
	constant PROG : prog_t := (
		x"31", x"00", x"80",     -- LD SP,0x8000
		x"21", x"00", x"40",     -- LD HL,0x4000
		x"06", x"00",            -- LD B,0
		x"78",                   -- loop: LD A,B
		x"77",                   --       LD (HL),A
		x"23",                   --       INC HL
		x"10", x"FB",            --       DJNZ loop
		x"21", x"00", x"40",     -- LD HL,0x4000
		x"06", x"00",            -- LD B,0
		x"AF",                   -- XOR A
		x"86",                   -- loop2: ADD A,(HL)
		x"23",                   --        INC HL
		x"10", x"FC",            --        DJNZ loop2
		x"32", x"00", x"50",     -- LD (0x5000),A
		x"E5",                   -- PUSH HL
		x"76"                    -- HALT
	);

	constant EXP_N : natural := 259;    -- 256 + 1 (the sum) + 2 (PUSH)

	function e_a (i : natural) return std_logic_vector is
	begin
		if i < 256 then
			return std_logic_vector(to_unsigned(16#4000# + i, 16));
		elsif i = 256 then
			return x"5000";
		elsif i = 257 then
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
		elsif i = 257 then
			return x"41";
		else
			return x"00";
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
	-- --std=93c: the report lines below use these two small converters.
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
	signal turbo    : std_logic_vector(1 downto 0) := "00";
	signal areset   : std_logic;
	signal clk_bus, clk_8, clk_gs, clk_sdr, clk_12, clk_rgb, clk_vga, clk_adc : std_logic;
	signal ena_div2, ena_div4, ena_div8, ena_div16 : std_logic;
	signal ena_div2n, ena_div4n, ena_div8n, ena_div16n : std_logic;
	signal ena_cpu, ena_cpu_n, ena_rgb, ce_14, ce_8 : std_logic;

	-- profi.vhd's wiring of the wait: WAIT_CPU sees cpu_wait only in the turbo
	-- modes (rewrite 3); WAIT_EN = false cuts the path entirely (RED run)
	signal cpu_wait    : std_logic;
	signal wait_cpu_ac : std_logic;
	signal wait_n_ac   : std_logic := '1';

	-- the CPU bus
	signal cpu_reset_n : std_logic := '0';
	signal m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n : std_logic;
	signal a_bus  : std_logic_vector(15 downto 0);
	signal di_bus : std_logic_vector(7 downto 0) := (others => '0');
	signal do_bus : std_logic_vector(7 downto 0);

	-- the bridge port: the CPU's during the run, the testbench's while loading
	signal tb_reset    : std_logic := '1';
	signal load_phase  : std_logic := '1';
	signal ld_addr     : std_logic_vector(20 downto 0) := (others => '0');
	signal ld_din      : std_logic_vector(7 downto 0) := (others => '0');
	signal ld_stb      : std_logic := '0';
	signal br_addr     : std_logic_vector(20 downto 0);
	signal br_din      : std_logic_vector(7 downto 0);
	signal br_rd       : std_logic;
	signal br_wr       : std_logic;
	signal bridge_rst  : std_logic;

	-- to the sdram client model
	signal sd_addr  : std_logic_vector(24 downto 0);
	signal sd_din   : std_logic_vector(7 downto 0);
	signal sd_rd    : std_logic;
	signal sd_we    : std_logic;
	signal sd_dout  : std_logic_vector(7 downto 0) := (others => '0');
	signal sd_ready : std_logic := '0';

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
		CLK => clk50, DS80 => '0',
		CLK_BUS => clk_bus, CLK_8 => clk_8, CLK_GS => clk_gs, CLK_SDR => clk_sdr,
		CLK_12 => clk_12, CLK_RGB => clk_rgb, CLK_VGA => clk_vga, CLK_ADC => clk_adc,
		ENA_DIV2 => ena_div2, ENA_DIV4 => ena_div4, ENA_DIV8 => ena_div8,
		ENA_DIV16 => ena_div16, ENA_DIV2N => ena_div2n, ENA_DIV4N => ena_div4n,
		ENA_DIV8N => ena_div8n, ENA_DIV16N => ena_div16n,
		ENA_CPU => ena_cpu, ENA_CPU_N => ena_cpu_n, ENA_RGB => ena_rgb,
		CE_14 => ce_14, CE_8 => ce_8,
		TURBO => turbo, WAIT_CPU => wait_cpu_ac, ARESET => areset
	);

	-- profi.vhd's other half (rewrite 4): the same condition drives the CPU's
	-- WAIT_n pin. The DI_Reg latch is `TState = 2 and Wait_n = '1'`, so at turbo
	-- "11", where a T-state is a single clk_bus and the ENA_CPU freeze cannot
	-- arrive before the edge that samples DI, WAIT_n is what holds the CPU.
	wait_cpu_ac <= cpu_wait when (WAIT_EN and turbo /= "00") else '0';
	wait_n_ac   <= '0' when (WAIT_EN and turbo /= "00" and cpu_wait = '1') else '1';

	U_CPU: entity work.T80s
	port map (
		RESET_n => cpu_reset_n,
		CLK     => clk_bus,
		CEN     => ena_cpu,
		WAIT_n  => wait_n_ac,
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
		DO      => do_bus
	);

	bridge_rst <= areset or tb_reset;

	br_addr <= ld_addr when load_phase = '1' else "00000" & a_bus;
	br_din  <= ld_din  when load_phase = '1' else do_bus;
	br_rd   <= '0'     when load_phase = '1' else (not mreq_n and not rd_n);
	br_wr   <= ld_stb  when load_phase = '1'
	           else (not mreq_n and not wr_n and ena_cpu);

	U_BRIDGE: entity work.sram_bridge
	port map (
		clk_bus  => clk_bus,
		clk_sdr  => clk_sdr,
		reset    => bridge_rst,
		rd_req   => br_rd,
		wr_stb   => br_wr,
		addr     => br_addr,
		din      => br_din,
		dout     => di_bus,
		cpu_wait => cpu_wait,
		sd_addr  => sd_addr,
		sd_din   => sd_din,
		sd_rd    => sd_rd,
		sd_we    => sd_we,
		sd_dout  => sd_dout,
		sd_ready => sd_ready
	);

	U_MODEL: entity work.sdram
	generic map (
		GAP_CLKS => 6       -- the read access of the real sdram.sv; the model's
		                    -- default 9 clock gap would arrive after the T80's
		                    -- DI latch even at turbo "00" (see model header)
	)
	port map (
		init   => areset,
		clk    => clk_sdr,
		addr   => sd_addr,
		dout   => sd_dout,
		din    => sd_din,
		we     => sd_we,
		rd     => sd_rd,
		ready  => sd_ready
	);

	-- every CPU write cycle counted once: several strobes (one per ENA_CPU clock
	-- while WR_n is low) are one write cycle, split when WR_n rises. The value
	-- of the last strobe is the value of the cycle (address and data hold for
	-- the whole write T-states).
	mon: process (clk_bus)
		variable cur_a   : std_logic_vector(15 downto 0);
		variable cur_d   : std_logic_vector(7 downto 0);
		variable have    : boolean := false;
		variable prev_wr : std_logic := '1';
	begin
		if rising_edge(clk_bus) then
			if load_phase = '0' and mreq_n = '0' and wr_n = '0' and ena_cpu = '1' then
				cur_a := a_bus;
				cur_d := do_bus;
				have  := true;
			end if;
			if have and prev_wr = '0' and wr_n = '1' then
				have := false;
				if mon_idx < EXP_N then
					if cur_a /= e_a(mon_idx) or cur_d /= e_d(mon_idx) then
						report "tb_turbo_wait: write " & integer'image(mon_idx)
							& " expected " & hx4(e_a(mon_idx)) & "," & hx2(e_d(mon_idx))
							& " got " & hx4(cur_a) & "," & hx2(cur_d);
						mon_bad := true;
					end if;
					mon_idx := mon_idx + 1;
				else
					report "tb_turbo_wait: extra write "
						& hx4(cur_a) & "," & hx2(cur_d);
					mon_bad := true;
				end if;
			end if;
			prev_wr := wr_n;
		end if;
	end process;

main: process

	variable bad      : boolean := false;
	variable halted   : boolean;
	variable halt_at  : time;
	variable seq_done : boolean;

	procedure rise (count : in natural) is
	begin
		for i in 1 to count loop
			wait until rising_edge(clk_bus);
		end loop;
	end procedure;

	-- the bridge keeps every request back for 16384 clk_sdr clocks after its
	-- reset (sdram.sv refreshing), so nothing can be measured before that
	procedure wait_startup is
	begin
		wait for 160 us;
	end procedure;

	-- one byte per few clocks, and never a strobe while the queue is almost
	-- full (cpu_wait is the queue's afull here: rd_req stays low)
	procedure load_program is
	begin
		for i in 0 to PROG_N - 1 loop
			poll: loop
				wait until rising_edge(clk_bus);
				exit poll when cpu_wait = '0';
			end loop poll;
			ld_addr <= std_logic_vector(to_unsigned(i, 21));
			ld_din  <= PROG(i);
			ld_stb  <= '1';
			wait until rising_edge(clk_bus);
			ld_stb  <= '0';
			wait until rising_edge(clk_bus);
		end loop;
	end procedure;

	procedure run_phase (name : in string;
	                     tv   : in  std_logic_vector(1 downto 0);
	                     tmax : in  time) is
		variable t0 : time;
	begin
		-- fresh reset of the bridge and the CPU for this turbo setting
		cpu_reset_n <= '0';
		load_phase  <= '1';
		tb_reset    <= '1';
		turbo       <= tv;
		rise(8);
		mon_idx := 0;
		mon_bad := false;
		tb_reset <= '0';
		wait_startup;
		load_program;
		rise(128);                      -- the queue drains: the program is in
		load_phase  <= '0';             -- the bridge port belongs to the CPU now
		rise(4);
		t0 := now;
		cpu_reset_n <= '1';
		watch: loop
			wait until rising_edge(clk_bus);
			exit watch when halt_n = '0';
			if now - t0 > tmax then
				exit watch;
			end if;
		end loop watch;
		halted := halt_n = '0';
		halt_at := now - t0;
		rise(4);                        -- the monitor has committed by now
		seq_done := mon_idx = EXP_N and not mon_bad;
		if halted and seq_done then
			report "tb_turbo_wait: turbo " & name & " halt at "
				& itos(halt_at / 1 ns) & " ns, " & itos(EXP_N) & " writes ok";
		else
			bad := true;
			report "tb_turbo_wait: turbo " & name & " FAIL halt=" & bstr(halted)
				& " after " & itos(halt_at / 1 ns) & " ns writes=" & itos(mon_idx)
				& "/" & itos(EXP_N) & " seq_bad=" & bstr(mon_bad);
		end if;
	end procedure;

begin

	-- the PLL model locks 1 us after the start; ARESET falls with it
	wait until areset = '0';

	-- turbo "00" needs no wait path (the 3.5 MHz reference run), then the three
	-- turbo modes, each with its own reset and load
	run_phase("00", "00", 6 ms);
	run_phase("01", "01", 4 ms);
	run_phase("10", "10", 3 ms);
	run_phase("11", "11", 3 ms);

	if bad then
		report "tb_turbo_wait: FAIL one or more turbo runs failed" severity failure;
	else
		report "tb_turbo_wait: PASS";
	end if;
	wait;

end process;

end sim;
