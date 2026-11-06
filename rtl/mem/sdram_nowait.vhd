-------------------------------------------------------------------------------
-- sdram_nowait: the Stage 2 no-wait SDRAM controller
-------------------------------------------------------------------------------
-- CPU turbo 11 (28 MHz, one T-state per clk_bus = 4 x clk_mem) with no memory
-- wait state: every CPU M-cycle that can carry data runs its SDRAM burst fully
-- inside the M-cycle, so no wait depends on memory timing (spec §5.2). The
-- command encoding, the address map, the init sequence and the MODE word
-- follow rtl/mem/sdram.sv; the chip-side behaviour is what
-- sim/models/sdram_chip.vhd models.
--
-- Timing facts this rests on (build/upstream/src/rtl/t80se/T80s.vhd, T2Write=1):
--   * At a CEN edge the T80 changes TS/MC/A for the next T-state.
--   * RD_n (reads) and WR_n (writes) go low at the edge that ends T1 (E1) and
--     are re-raised by the edge that ends T2 (E2) - one clk_bus period low.
--   * The T80 latches DI (and the opcode) at E2, when Wait_n = 1.
--   * In M1, T3/T4 are the refresh phase (MREQ_n low, no CPU data access).
--   * At turbo 11 a T-state is one clk_bus period = 4 clk_mem, so from the
--     edge that starts T1 (E0) to the latch edge (E2) there are exactly 8
--     clk_mem.
--
-- Samples. The controller reads the clk_bus-domain inputs only on the clk_mem
-- edge whose registered bus_phase is "01". clkdiv4's counter becomes "00" on
-- the clk_mem edge where clk_bus rises, so logic clocked by clk_mem sees "00"
-- one and "01" two clk_mem after a clk_bus rising edge: the sample edge is 2
-- clk_mem after each clk_bus edge, which gives every clk_bus->clk_mem path
-- 2 clk_mem periods (the sdc multicycle is Task 4). Call the sample after a
-- clk_bus edge by that edge's name; at turbo 11, with the M-cycle start edge
-- E0 at clk_mem t = 0:
--   the sample after E0 is t = 2; after E1 t = 6; E2 is t = 8; after E2 t = 10.
-- All times below are clk_mem cycles from the start sample S0.
--
-- CPU M-cycle schedule (the only path for CPU data; MC = "001"/"010" cycles
-- only - I/O and internal cycles, MC = "000", never touch the memory, the
-- I/O device answers them and cpu_dout simply holds). Times for turbo 11;
-- at lower turbos a T-state lasts several clk_bus, so E1/E2 and the resolve
-- sample land later (the start-anchored READ/capture do not move):
--   S0     start: sample with cpu_ts = "001" and the previous sample's ts
--          /= "001" (cpu_reset_n = '1'): issue ACTIVE(row), latch addr/wr_en,
--          schedule READ (A10 = 0) at S0 + 2. The bank is idle and TRC has
--          elapsed at every start (sim assertion, it is the schedule's
--          invariant).
--   S0 + 5 capture edge of the READ issued at S0 + 2: SDRAM_CLK is clk_mem
--          inverted (the top's altddio), so a command issued at edge e is read
--          by the chip at e + 1/2 and the CL2 read data drives the bus during
--          [S0 + 4.5, S0 + 5.5): the capture is the clk_mem edge S0 + 5, one
--          clk_mem before the latch edge E2 (S0 + 5 is absolute t = 7 at
--          turbo 11, E2 is t = 8). This is sdram.sv's data_ready_delay rule
--          (capture = command + CL + 1 chip cycles) on the inverted clock,
--          and the chip model confirms the edge (tb_sdram_nowait checks the
--          byte). A write cycle rearms the capture for the edge after its
--          resolve (below), because at turbos below 11 that resolve is later
--          than S0 + 5 and din is only latched there.
--   resolve sample, the first one seeing RD_n/WR_n/IORQ_n low (those are low
--          exactly during [E1, E2), which holds exactly one sample at turbo
--          11, S0 + 4):
--     wr_n = 0 and mreq_n = 0 (write): WRITE with auto precharge (A10 = 1) at
--       max(sample + 2, S0 + 6), the floor keeping it out of the read data's
--       drive interval - with the byte lane un-masked on dqm and A12/A11, the
--       byte driven on both lanes, and only if the latched cpu_wr_en = '1'
--       (else PRECHARGE at sample + 1). The rearmed capture loads the written
--       byte instead of the bus (write forwarding), so the byte latched at E2
--       of a write cycle is the written byte (the capture rearms for
--       resolve + 1 = E1 + 3, always before the latch edge E2).
--     rd_n = 0 or iorq_n = 0 (read / I/O cycle): PRECHARGE at sample + 1
--       (= S0 + 5 at turbo 11).
--     ts >= "011" with none of the above (no memory access), or the CPU
--       dropping into reset mid-cycle: PRECHARGE at that sample + 1.
--   idle again at max(ACTIVE + TRC, PRECHARGE + TRP, WRITE + 2 + TRP) =
--          S0 + 8 for reads, S0 + 10 for writes, S0 + 11 for the no-access
--          path - all before the next possible start sample S0 + 12.
--
-- Free windows, only with the bank idle (every timer expired) and no cycle in
-- flight, at a sample W, any of:
--   (a) cpu_mc = "001" and cpu_ts = "011" (M1's refresh phase); the next start
--       sample is then exactly W + 8 (M1 is >= 4 T-states),
--   (b) cpu_ena = '0': that ENA_CPU value gates the next clk_bus edge, so no
--       M-cycle can start before W + 8 (the start sample needs a live edge
--       two clk_mem before it and the first possibly-live edge is W + 6),
--   (c) cpu_reset_n = '0' (the test protocol then waits >= 4 clk_bus after the
--       release before the first T1 edge; the same bound).
-- In a window, issue AUTO REFRESH if owed > 0, else a pending port B access:
-- ACTIVE at W, READ/WRITE with auto precharge at W + 2 (port B reads also use
-- A10 = 1), read data captured at W + 5, b_done toggles at W + 6. A REFRESH
-- needs TRFC = 8 before the next command, so both classes finish exactly by
-- W + 8, when a CPU start is allowed again (t_next = 0 at W + 8).
--
-- owed increments every REFRESH_CLKS = 700 clk_mem (6.2 us at 112.5 MHz,
-- 7.26 us at 96.43 MHz - inside the chip's 64 rows / 64 ms window) once init
-- is done, and saturates at 15; a sim assertion fails if it reaches 9. Port B
-- pending is set on a rising b_req at a sample and cleared when the access is
-- issued; a second rising edge while still pending is a sim assertion plus a
-- sticky b_overrun.
--
-- Address map (sdram.sv's, kept for continuity): word address addr(20:1),
-- byte lane addr(0) with lane 0 = DQ(7:0); BA = "00"; row = addr(13:1);
-- column = addr(20:14) in sd_a(6 downto 0), sd_a(8 downto 7) = "00",
-- sd_a(9) = '0', sd_a(10) = auto precharge (0 on the CPU READ - the explicit
-- PRECHARGE follows; 1 on every WRITE), and on READ/WRITE sd_a(12)/sd_a(11)
-- carry DQMH/DQML (some MiSTer SDRAM boards take the mask from A12/A11 - the
-- chip takes it from dqm; sdram.sv drives both). Reads use mask "00" and read
-- both lanes; a write drives its byte on both lanes and masks the other lane.
--
-- IO registers: sys/sys.tcl sets FAST_OUTPUT_REGISTER on SDRAM_* and
-- FAST_INPUT_REGISTER on SDRAM_DQ[*], so every sd_* output comes straight out
-- of a clk_mem register (dq_r carries 'Z' when the controller does not drive,
-- sdram.sv-style - no logic between register and pin), and the read data is
-- captured into two registers fed directly from sd_dq: cpu_dq_r at S0 + 5 and
-- b_dq_r at W + 5, one register per capture; cpu_dout/b_dout are the byte
-- select off those registers (sdram.sv's dout does the same).
--
-- Init: NOPs for INIT_CLKS = 11250 + 64 clk_mem (100 us + margin at the
-- 112.5 MHz rate, also covering 96.43 MHz and the power-up window of the
-- chip), then PRECHARGE ALL, 2 x AUTO REFRESH TRFC apart, LOAD MODE (CL2, BL1,
-- single write); ready rises when MODE is issued. CPU events are ignored and
-- port B waits until then.
--
-- Plain VHDL-93; sim-only assertions live in pragma translate_off blocks.
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity sdram_nowait is
port (
	clk_mem   : in  std_logic;                     -- 112.5 / 96.43 MHz
	reset     : in  std_logic;                     -- RESET_MEM (clk_mem, sync)
	bus_phase : in  std_logic_vector(1 downto 0);  -- clock.vhd BUS_PHASE
	ready     : out std_logic;                     -- init done (clk_mem)

	-- CPU port: clk_bus-domain signals, read only on the sample edge
	cpu_reset_n : in std_logic;                    -- the T80 RESET_n
	cpu_ena   : in  std_logic;                     -- ENA_CPU (this clk_bus period)
	cpu_ts    : in  std_logic_vector(2 downto 0);  -- T80 TState (TS_O)
	cpu_mc    : in  std_logic_vector(2 downto 0);  -- T80 MCycle (MC_O)
	cpu_mreq_n : in std_logic;
	cpu_rd_n   : in std_logic;
	cpu_wr_n   : in std_logic;
	cpu_iorq_n : in std_logic;
	cpu_addr  : in  std_logic_vector(20 downto 0); -- memory.vhd's paged byte address
	cpu_wr_en : in  std_logic;                     -- 1 = this address may be written (RAM)
	cpu_din   : in  std_logic_vector(7 downto 0);  -- T80 DO
	cpu_dout  : out std_logic_vector(7 downto 0);  -- read by the T80 at the latch edge

	-- port B (loader now, GS in stage 3): clk_bus domain, read on the sample edge
	b_req   : in  std_logic;                       -- level; one access per rising edge
	b_we    : in  std_logic;
	b_addr  : in  std_logic_vector(20 downto 0);
	b_din   : in  std_logic_vector(7 downto 0);
	b_dout  : out std_logic_vector(7 downto 0);
	b_done  : out std_logic;                       -- toggles when the access completed
	b_overrun : out std_logic;                     -- sticky: second request while pending

	-- SDRAM pins (SDRAM_CLK is made by the top's altddio from clk_mem)
	sd_ba  : out std_logic_vector(1 downto 0);
	sd_a   : out std_logic_vector(12 downto 0);
	sd_dqm : out std_logic_vector(1 downto 0);
	sd_ras_n, sd_cas_n, sd_we_n : out std_logic;
	sd_dq  : inout std_logic_vector(15 downto 0)
);
end sdram_nowait;

architecture rtl of sdram_nowait is

-- the HYB39V16160D command table, as sdram.sv sends it
constant CMD_NOP      : std_logic_vector(2 downto 0) := "111";
constant CMD_ACTIVE   : std_logic_vector(2 downto 0) := "011";
constant CMD_READ     : std_logic_vector(2 downto 0) := "101";
constant CMD_WRITE    : std_logic_vector(2 downto 0) := "100";
constant CMD_PRECHARGE: std_logic_vector(2 downto 0) := "010";
constant CMD_REFRESH  : std_logic_vector(2 downto 0) := "001";
constant CMD_MODE     : std_logic_vector(2 downto 0) := "000";

-- {3'b000, NO_WRITE_BURST, OP_MODE(00), CL2, ACCESS(0), BL1} (sdram.sv's MODE)
constant MODE_WORD : std_logic_vector(12 downto 0) := "0001000100000";

constant INIT_CLKS    : natural := 11250 + 64;  -- 100 us @ 112.5 MHz + margin
constant REFRESH_CLKS : natural := 700;         -- 6.2 us @ 112.5 MHz

-- busy budgets (clk_mem cycles from the setting sample until the next ACTIVE
-- of the bank is allowed again): the chip's TRC 8, TRP 2, TRFC 8, TWR 2, CL 2
constant BUSY_START : natural := 8;   -- ACTIVE + TRC
constant BUSY_WR    : natural := 6;   -- resolve + 6 = WRITE(S0+6) + 2 + TRP
constant BUSY_RD    : natural := 3;   -- resolve + 3: t_next is 0 again at the
                                      -- sample S0 + 8, where an M1 cycle has
                                      -- its refresh window (PRECHARGE at
                                      -- S0 + 5 closed the bank; the chip's
                                      -- rules accept the equal step)
constant BUSY_INT   : natural := 3;   -- resolve(S0+8) + 1 + TRP = S0 + 12
constant BUSY_FREE  : natural := 7;   -- t_next is 0 again at W + 8 exactly,
                                      -- where the next window or a CPU start
                                      -- may be (equal TRC/TRFC step is ok)

type cmd_t is record
	v      : std_logic;                    -- issue this command
	cmd    : std_logic_vector(2 downto 0);
	a      : std_logic_vector(12 downto 0);
	dqm    : std_logic_vector(1 downto 0);
	driven : std_logic;                    -- dq carries data (WRITE)
	dq     : std_logic_vector(15 downto 0);
end record;

constant CMD_NONE : cmd_t := (v => '0', driven => '0', cmd => CMD_NOP,
	a => (others => '0'), dqm => "00", dq => (others => 'Z'));

-- command/address outputs: register to pin, no logic in between
signal cmd_r : std_logic_vector(2 downto 0) := CMD_NOP;
signal a_r   : std_logic_vector(12 downto 0) := (others => '0');
signal ba_r  : std_logic_vector(1 downto 0)  := "00";
signal dqm_r : std_logic_vector(1 downto 0)  := "00";
signal dq_r  : std_logic_vector(15 downto 0) := (others => 'Z');

-- read data capture registers, fed directly from sd_dq
signal cpu_dq_r : std_logic_vector(15 downto 0) := (others => '0');
signal b_dq_r   : std_logic_vector(15 downto 0) := (others => '0');
signal lane_r   : std_logic := '0';
signal b_lane_r : std_logic := '0';

-- command staging: s1 fires next cycle, s2 fires two cycles ahead (the only
-- schedules are +1/-PRE and +2/READ-WRITE, and at most one source stages at a
-- sample edge, so a slot can never be overwritten while holding a command)
signal s1, s2 : cmd_t := CMD_NONE;

-- event shift chains, bit i = fires i cycles after the cycle that set it
-- (the bit read at [0] fires this cycle); width covers the longest delay, b_done at W + 6
signal cp_cpu : std_logic_vector(5 downto 0) := (others => '0');
signal cp_b   : std_logic_vector(5 downto 0) := (others => '0');
signal dn_b   : std_logic_vector(5 downto 0) := (others => '0');
signal ovr    : std_logic_vector(5 downto 0) := (others => '0');

signal ready_r     : std_logic := '0';
signal in_cycle    : std_logic := '0';
signal wr_en_r     : std_logic := '0';
signal din_r       : std_logic_vector(7 downto 0) := (others => '0');
signal prev_ts     : std_logic_vector(2 downto 0) := "001";
signal t_next      : unsigned(4 downto 0) := (others => '0');
signal owed        : unsigned(3 downto 0) := (others => '0');
signal rcnt        : unsigned(9 downto 0) := (others => '0');
signal init_cnt    : unsigned(13 downto 0) := (others => '0');
signal ist         : unsigned(2 downto 0) := (others => '0');  -- init phase
signal b_pending   : std_logic := '0';
signal b_req_q     : std_logic := '0';
signal b_done_r    : std_logic := '0';
signal b_overrun_r : std_logic := '0';

begin

main: process (clk_mem)
	variable hd        : boolean;        -- a command issues this cycle
	variable d         : cmd_t;
	variable n1, n2    : cmd_t;          -- schedules for +1 and +2
	variable p         : cmd_t;          -- the command to issue
	variable v_cpc     : std_logic_vector(5 downto 0);
	variable v_cpb     : std_logic_vector(5 downto 0);
	variable v_dnb     : std_logic_vector(5 downto 0);
	variable v_ovr     : std_logic_vector(5 downto 0);
	variable busy      : boolean;
	variable busy_v    : natural range 0 to 31;
	variable smp       : boolean;
	variable v_rise    : boolean;
	variable col       : std_logic_vector(12 downto 0);
	variable dqm_v     : std_logic_vector(1 downto 0);
begin
	if rising_edge(clk_mem) then
		if reset = '1' then
			cmd_r     <= CMD_NOP;
			a_r       <= (others => '0');
			ba_r      <= "00";
			dqm_r     <= "00";
			dq_r      <= (others => 'Z');
			cpu_dq_r  <= (others => '0');
			b_dq_r    <= (others => '0');
			lane_r    <= '0';
			b_lane_r  <= '0';
			s1        <= CMD_NONE;
			s2        <= CMD_NONE;
			cp_cpu    <= (others => '0');
			cp_b      <= (others => '0');
			dn_b      <= (others => '0');
			ovr       <= (others => '0');
			ready_r   <= '0';
			in_cycle  <= '0';
			wr_en_r   <= '0';
			din_r     <= (others => '0');
			prev_ts   <= "001";
			t_next    <= (others => '0');
			owed      <= (others => '0');
			rcnt      <= (others => '0');
			init_cnt  <= (others => '0');
			ist       <= (others => '0');
			b_pending <= '0';
			b_req_q   <= '0';
			b_done_r  <= '0';
			b_overrun_r <= '0';
		else
			hd := false;
			d := CMD_NONE;
			n1 := CMD_NONE;
			n2 := CMD_NONE;
			busy := false;
			busy_v := 0;
			-- shift the event chains; bit 0 of the current value fires now
			v_cpc := '0' & cp_cpu(5 downto 1);
			v_cpb := '0' & cp_b(5 downto 1);
			v_dnb := '0' & dn_b(5 downto 1);
			v_ovr := '0' & ovr(5 downto 1);
			smp := bus_phase = "01";
			v_rise := false;

			-- captures (the sample edge of the schedule tables above)
			if cp_cpu(0) = '1' then
				if ovr(0) = '1' then
					cpu_dq_r <= din_r & din_r;   -- write forwarding
				else
					cpu_dq_r <= sd_dq;
				end if;
			end if;
			if cp_b(0) = '1' then
				b_dq_r <= sd_dq;
			end if;
			if dn_b(0) = '1' then
				b_done_r <= not b_done_r;
			end if;

			-- init: NOPs, PRECHARGE ALL, 2 x REFRESH TRFC apart, LOAD MODE
			case ist is
				when "000" =>
					if init_cnt = INIT_CLKS - 1 then
						d := (v => '1', driven => '0', cmd => CMD_PRECHARGE,
							a => (10 => '1', others => '0'),
							dqm => "00", dq => (others => 'Z'));
						hd := true;
						init_cnt <= (others => '0');
						ist <= "001";
					else
						init_cnt <= init_cnt + 1;
					end if;
				when "001" | "010" =>
					if init_cnt = 7 then
						d := (v => '1', driven => '0', cmd => CMD_REFRESH,
							a => (others => '0'),
							dqm => "00", dq => (others => 'Z'));
						hd := true;
						init_cnt <= (others => '0');
						ist <= ist + 1;
					else
						init_cnt <= init_cnt + 1;
					end if;
				when "011" =>
					if init_cnt = 7 then
						d := (v => '1', driven => '0', cmd => CMD_MODE,
							a => MODE_WORD, dqm => "00", dq => (others => 'Z'));
						hd := true;
						ready_r <= '1';
						ist <= "100";
					else
						init_cnt <= init_cnt + 1;
					end if;
				when others =>
					null;
			end case;

			-- port B pending, set on a rising b_req at a sample
			if smp then
				v_rise := b_req = '1' and b_req_q = '0';
				b_req_q <= b_req;
				if v_rise then
					if b_pending = '1' then
						-- pragma translate_off
						assert false
							report "sdram_nowait: port B overrun (request while pending)"
							severity failure;
						-- pragma translate_on
						b_overrun_r <= '1';
					else
						b_pending <= '1';
					end if;
				end if;
			end if;

			if smp and ready_r = '1' then
				if cpu_reset_n = '1' and cpu_ts = "001"
				   and prev_ts /= "001" and in_cycle = '0'
				   and (cpu_mc = "001" or cpu_mc = "010") then
					-- start of a CPU M-cycle (MC = 001/010: I/O and internal
					-- cycles, MC = "000", never touch the memory - the I/O
					-- device answers them and cpu_dout simply holds)
					-- pragma translate_off
					assert t_next = 0
						report "sdram_nowait: start sample with the bank busy"
						severity failure;
					-- pragma translate_on
					lane_r <= cpu_addr(0);
					wr_en_r <= cpu_wr_en;
					d := (v => '1', driven => '0', cmd => CMD_ACTIVE,
						a => cpu_addr(13 downto 1), dqm => "00",
						dq => (others => 'Z'));
					hd := true;
					col := (others => '0');
					col(6 downto 0) := cpu_addr(20 downto 14);
					n2 := (v => '1', driven => '0', cmd => CMD_READ,
						a => col, dqm => "00", dq => (others => 'Z'));
					v_cpc(4) := '1';            -- capture at S0 + 5
					busy := true;
					busy_v := BUSY_START;
					in_cycle <= '1';

				elsif in_cycle = '1' then
					-- resolve: exactly one branch fires at S0 + 4 / S0 + 8
					if cpu_wr_n = '0' and cpu_mreq_n = '0' then
						din_r <= cpu_din;
						if wr_en_r = '1' then
							col := (others => '0');
							col(6 downto 0) := cpu_addr(20 downto 14);
							col(12) := not cpu_addr(0);    -- DQMH
							col(11) := cpu_addr(0);        -- DQML
							col(10) := '1';                -- auto precharge
							if cpu_addr(0) = '1' then
								dqm_v := "01";   -- DQML masks lane 0
							else
								dqm_v := "10";   -- DQMH masks lane 1
							end if;
							n2 := (v => '1', driven => '1', cmd => CMD_WRITE,
								a => col, dqm => dqm_v,
								dq => cpu_din & cpu_din);
							v_ovr(0) := '1';               -- forward below
							v_cpc(0) := '1';               -- capture edge
						else
							n1 := (v => '1', driven => '0', cmd => CMD_PRECHARGE,
								a => (others => '0'), dqm => "00",
								dq => (others => 'Z'));
						end if;
						busy := true;
						busy_v := BUSY_WR;
						in_cycle <= '0';
					elsif cpu_rd_n = '0' or cpu_iorq_n = '0' then
						n1 := (v => '1', driven => '0', cmd => CMD_PRECHARGE,
							a => (others => '0'), dqm => "00",
							dq => (others => 'Z'));
						busy := true;
						busy_v := BUSY_RD;
						in_cycle <= '0';
					elsif cpu_ts >= "011" or cpu_reset_n = '0' then
						-- no data access left, or the cycle died in reset:
						-- PRECHARGE at sample + 1 (the first sample of the
						-- cycle is S0 + 4, so this respects TRAS = 5)
						n1 := (v => '1', driven => '0', cmd => CMD_PRECHARGE,
							a => (others => '0'), dqm => "00",
							dq => (others => 'Z'));
						busy := true;
						busy_v := BUSY_INT;
						in_cycle <= '0';
					end if;

				elsif in_cycle = '0' and t_next = 0 then
					-- free windows: (a) the M1 refresh phase, (b) the T80
					-- cannot advance, (c) the CPU is in reset
					if cpu_reset_n = '0' or cpu_ena = '0'
					   or (cpu_mc = "001" and cpu_ts = "011") then
						if owed /= 0 then
							d := (v => '1', driven => '0', cmd => CMD_REFRESH,
								a => (others => '0'), dqm => "00",
								dq => (others => 'Z'));
							hd := true;
							owed <= owed - 1;
							busy := true;
							busy_v := BUSY_FREE;
						elsif b_pending = '1' or v_rise then
							b_lane_r <= b_addr(0);
							d := (v => '1', driven => '0', cmd => CMD_ACTIVE,
								a => b_addr(13 downto 1), dqm => "00",
								dq => (others => 'Z'));
							hd := true;
							col := (others => '0');
							col(6 downto 0) := b_addr(20 downto 14);
							col(10) := '1';                -- auto precharge
							if b_we = '1' then
								col(12) := not b_addr(0);  -- DQMH
								col(11) := b_addr(0);      -- DQML
								if b_addr(0) = '1' then
									dqm_v := "01";
								else
									dqm_v := "10";
								end if;
								n2 := (v => '1', driven => '1', cmd => CMD_WRITE,
									a => col, dqm => dqm_v,
									dq => b_din & b_din);
							else
								n2 := (v => '1', driven => '0', cmd => CMD_READ,
									a => col, dqm => "00",
									dq => (others => 'Z'));
							end if;
							v_cpb(4) := '1';               -- capture at W + 5
							v_dnb(5) := '1';               -- b_done at W + 6
							b_pending <= '0';
							busy := true;
							busy_v := BUSY_FREE;
						end if;
					end if;
				end if;
				prev_ts <= cpu_ts;
			end if;

			-- busy timer: while busy_v counts down, t_next holds the
			-- remaining clocks before the next ACTIVE may be issued
			if busy then
				t_next <= to_unsigned(busy_v, 5);
			elsif t_next /= 0 then
				t_next <= t_next - 1;
			end if;

			-- refresh debt, from init done on
			if ready_r = '1' then
				if rcnt = REFRESH_CLKS - 1 then
					rcnt <= (others => '0');
					if owed /= 15 then
						-- pragma translate_off
						assert owed < 8
							report "sdram_nowait: refresh debt reached 9"
							severity failure;
						-- pragma translate_on
						owed <= owed + 1;
					end if;
				else
					rcnt <= rcnt + 1;
				end if;
			end if;

			-- issue: direct beats the stage firing this cycle; the stage for
			-- the next cycle is the new +1 schedule or the +2 one, and s2
			-- takes the new +2 schedule
			p := CMD_NONE;
			if s1.v = '1' then
				p := s1;
			end if;
			if hd then
				p := d;
			end if;
			cmd_r <= p.cmd;
			a_r   <= p.a;
			dqm_r <= p.dqm;
			ba_r  <= "00";
			if p.driven = '1' then
				dq_r <= p.dq;
			else
				dq_r <= (others => 'Z');
			end if;
			if n1.v = '1' then
				s1 <= n1;
			else
				s1 <= s2;
			end if;
			s2 <= n2;
			cp_cpu <= v_cpc;
			cp_b   <= v_cpb;
			dn_b   <= v_dnb;
			ovr    <= v_ovr;
		end if;
	end if;
end process;

ready     <= ready_r;
b_done    <= b_done_r;
b_overrun <= b_overrun_r;
sd_ba     <= ba_r;
sd_a      <= a_r;
sd_dqm    <= dqm_r;
sd_ras_n  <= cmd_r(2);
sd_cas_n  <= cmd_r(1);
sd_we_n   <= cmd_r(0);
sd_dq     <= dq_r;
cpu_dout  <= cpu_dq_r(15 downto 8) when lane_r = '1' else cpu_dq_r(7 downto 0);
b_dout    <= b_dq_r(15 downto 8) when b_lane_r = '1' else b_dq_r(7 downto 0);

end rtl;
