-------------------------------------------------------------------------------
-- sdram_chip: sim model of the 16-bit SDRAM chip on the MiSTer SDRAM pins
-- (the HYB39V16160D class of chips the board carries), for the Stage 2
-- controller of Task 3 to drive. tb_sdram_chip puts scripted command
-- sequences on the pins; a timing mistake of a controller shows up as a
-- counted violation, so nothing here ever stops the run: the rules report
-- with severity error (GHDL's default --assert-level=failure lets those
-- through) and count into `violations`.
--
-- Address map (the one the Stage 2 controller uses, after rtl/mem/sdram.sv):
--   byte_addr(20 downto 0) = column(6 downto 0) & row(12 downto 0) & lane
--   row    = A(12 downto 0) latched on ACTIVE of that bank
--   column = A(6 downto 0)  latched on READ/WRITE;  A(9 downto 7) ignored
--   lane   0 = DQ(7 downto 0)  (the even byte),  lane 1 = DQ(15 downto 8)
--   BA is not part of the address (the controller only uses bank 0, but all
--   four banks are decoded and timed);  on READ/WRITE A(12)/A(11) carry a
--   copy of the byte mask - ignored, only `dqm` masks;  A(10) on READ/WRITE
--   is auto precharge, on PRECHARGE it means "all banks".
-- The array is sdram_chip_pkg.sdram_chip_mem: 2 MiB bytes, a shared variable
-- (GHDL cannot select inside an instantiated unit by name), so the testbench
-- preloads and inspects it. It boots 'U' - the testbench fills what it reads.
--
-- Command encoding: the HYB39V16160D table (RAS#,CAS#,WE#) that upstream
-- rtl/mem/sdram.sv sends on these very pins: NOP 111, ACTIVE 011, READ 101,
-- WRITE 100, PRECHARGE 010, AUTO REFRESH 001, LOAD MODE 000. cs_n high and
-- cke low are NOPs. Burst length is 1 (LOAD MODE with anything else is a
-- warning); CAS latency comes from the mode register A(6 downto 4) and must
-- be 2 - the value generic CL only says what the model assumes until the
-- mode register is loaded.
--
-- Data timing, as the chips behave against the inverted SDRAM_CLK the
-- altddio produces and as rtl/mem/sdram.sv drives them:
--   WRITE captures dq on the command edge (write latency 0 - sdram.sv puts
--   the byte on the bus in the command's own cycle), masked byte-wise by dqm;
--   READ drives dq from the CL-th rising clk edge after the command until
--   the next edge, then 'Z'.
--   `dq` is an inout: while the model drives, a resolved dq that differs
--   from what the model drives ('X' - both sides drove different bits) is
--   the FPGA driving the bus too. VHDL cannot see the other driver apart,
--   so that is what the check counts, once per clock edge at most.
--
-- Auto precharge (A10 on READ/WRITE) closes the bank after the burst: READ
-- CL + 1 cycles, WRITE TWR cycles after the command; the next ACTIVE of that
-- bank then additionally waits TRP.
--
-- The counted rules (report severity error, name the rule and the time,
-- count into `violations`):
--   1 ACTIVE to an open bank (the command is then ignored);
--   2 READ/WRITE to a closed bank, or before TRCD from ACTIVE (ignored);
--   3 PRECHARGE before TRAS from ACTIVE (it still closes the bank);
--   4 ACTIVE before TRP after PRECHARGE (auto precharge counts as a
--     precharge that starts after the burst, after TWR for writes);
--   5 ACTIVE before TRC from the previous ACTIVE of the bank;
--   6 REFRESH with any bank open, and any non-NOP command before TRFC
--     after a REFRESH;
--   7 any non-NOP command during the POWERUP_US (100 us default) power-up;
--   8 dq driven while the model drives;
--   9 fewer than ROWS refreshes in a sliding window of REFRESH_US: checked
--     at every refresh once ROWS refreshes have happened - the first refresh
--     that has a ROWS-th predecessor - and the time since the ROWS-th
--     previous refresh must be <= REFRESH_US.
-- A violating command is otherwise executed like a legal one, except where
-- noted at the rule: an invalid read/write touches neither the array nor the
-- bus, an ACTIVE to an open bank is ignored.
--
-- Timing limits are counted in rising clk edges (the clock the model is
-- given is exact, so cycles and time say the same thing); only the power-up
-- window and the refresh window are measured as real time against the
-- POWERUP_US/REFRESH_US generics. T_CK_NS documents the clock the limits are
-- written for; the model itself never multiplies with it.
--
-- Plain VHDL-93: analysed with --std=93c -fsynopsys like every other sim unit.
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package sdram_chip_pkg is

	constant SDRAM_CHIP_BYTES : natural := 2 * 1024 * 1024;

	subtype chip_byte_t is std_logic_vector(7 downto 0);
	type chip_byte_array is array (0 to SDRAM_CHIP_BYTES - 1) of chip_byte_t;

	-- the byte address of (row, column, lane) under the map documented in the
	-- model header: {column(6 downto 0), row(12 downto 0), lane}
	function sdram_chip_addr (
		row  : std_logic_vector(12 downto 0);
		col  : std_logic_vector(6 downto 0);
		lane : std_logic) return natural;

	-- The model's memory: the model writes it, the testbench preloads and
	-- reads it. Left uninitialised on purpose - an initialiser would call a
	-- function during elaboration (GHDL's -Welaboration complaint, see
	-- sdram_model.vhd) and 2 MiB cannot be spelled out either; 'U' bytes make
	-- a read of a cell nobody wrote fail loudly instead of passing by luck.
	shared variable sdram_chip_mem : chip_byte_array;

end package;

package body sdram_chip_pkg is

	function sdram_chip_addr (
		row  : std_logic_vector(12 downto 0);
		col  : std_logic_vector(6 downto 0);
		lane : std_logic) return natural is
	begin
		return to_integer(unsigned(col & row & lane));
	end function;

end package body;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.sdram_chip_pkg.all;

entity sdram_chip is
generic (
	T_CK_NS    : real := 8.888889;   -- the SDRAM clock this chip is driven with
	CL         : integer := 2;       -- assumed CAS latency until LOAD MODE
	TRCD       : integer := 2;       -- ACTIVE to READ/WRITE
	TRP        : integer := 2;       -- PRECHARGE to ACTIVE
	TRAS       : integer := 5;       -- ACTIVE to PRECHARGE
	TRC        : integer := 8;       -- ACTIVE to ACTIVE
	TRFC       : integer := 8;       -- REFRESH to the next command
	TWR        : integer := 2;       -- write recovery for auto precharge
	REFRESH_US : real := 64000.0;    -- the refresh window
	ROWS       : integer := 8192;    -- refreshes that must fit into it
	POWERUP_US : real := 100.0       -- the power-up NOP window
);
port (
	clk        : in  std_logic;                      -- the SDRAM_CLK pin
	cke        : in  std_logic;
	cs_n       : in  std_logic;
	ras_n      : in  std_logic;
	cas_n      : in  std_logic;
	we_n       : in  std_logic;
	ba         : in  std_logic_vector(1 downto 0);
	a          : in  std_logic_vector(12 downto 0);
	dqm        : in  std_logic_vector(1 downto 0);
	dq         : inout std_logic_vector(15 downto 0);
	violations : out natural;                        -- counted rule breaks
	refreshes  : out natural                         -- AUTO REFRESH seen
);
end sdram_chip;

architecture chip of sdram_chip is

	subtype bank_t is integer range 0 to 3;
	type bank_bool_t is array (bank_t) of boolean;
	type bank_row_t  is array (bank_t) of std_logic_vector(12 downto 0);
	type bank_int_t  is array (bank_t) of integer;

	-- read data in flight: queued at stage CL - 1 of a shift register, driven
	-- one cycle later per stage, so stage 0 drives the interval the next
	-- rising edge ends
	constant SCHED_N : natural := 8;               -- covers every CL the chip has
	type sched_v_t is array (0 to SCHED_N - 1) of boolean;
	type sched_d_t is array (0 to SCHED_N - 1) of std_logic_vector(15 downto 0);

	type time_vec_t is array (natural range <>) of time;

	-- VHDL-2008's maximum() for --std=93c
	function maxi (x, y : integer) return integer is
	begin
		if x > y then
			return x;
		else
			return y;
		end if;
	end function;

	constant CMD_NOP       : std_logic_vector(2 downto 0) := "111";
	constant CMD_ACTIVE    : std_logic_vector(2 downto 0) := "011";
	constant CMD_READ      : std_logic_vector(2 downto 0) := "101";
	constant CMD_WRITE     : std_logic_vector(2 downto 0) := "100";
	constant CMD_PRECHARGE : std_logic_vector(2 downto 0) := "010";
	constant CMD_REFRESH   : std_logic_vector(2 downto 0) := "001";
	constant CMD_MODE      : std_logic_vector(2 downto 0) := "000";

begin

	main: process (clk)
		variable open_b   : bank_bool_t := (others => false);
		variable ever_b   : bank_bool_t := (others => false);
		variable row_b    : bank_row_t  := (others => (others => '0'));
		variable t_act    : bank_int_t  := (others => 0);   -- last ACTIVE
		variable t_rw_ok  : bank_int_t  := (others => 0);   -- ACTIVE + TRCD
		variable t_pre_ok : bank_int_t  := (others => 0);   -- ACTIVE + TRAS
		variable t_act_ok : bank_int_t  := (others => 0);   -- TRP/TWR gate for ACTIVE
		variable ap_close : bank_int_t  := (others => -1);  -- auto precharge cycle
		variable t_ref_ok : integer := 0;                   -- REFRESH + TRFC
		variable mode_cl  : integer := CL;
		variable driving  : boolean := false;               -- model drove last interval
		variable drv      : std_logic_vector(15 downto 0) := (others => 'Z');
		variable sch_v    : sched_v_t := (others => false);
		variable sch_d    : sched_d_t := (others => (others => '0'));
		variable ref_hist : time_vec_t(0 to ROWS - 1) := (others => 0 ns);
		variable n_ref    : natural := 0;
		variable cyc      : natural := 0;
		variable vio      : natural := 0;
		variable refr     : natural := 0;
		variable cmd      : std_logic_vector(2 downto 0);
		variable b        : bank_t;
		variable idx      : natural;
	begin
		if rising_edge(clk) then
			cyc := cyc + 1;

			-- rule 8: the interval just ended - what the resolved bus held
			-- while the model drove it must be what the model drove
			if driving and dq /= drv then
				vio := vio + 1;
				report "sdram_chip: dq driven while the model drives (cycle "
					& integer'image(cyc) & ", t" & integer'image(now / 1 ns) & " ns)"
					severity error;
			end if;

			-- read data pipeline: stage 0 drives the interval this edge starts
			if sch_v(0) then
				drv := sch_d(0);
				driving := true;
				dq <= drv;
			else
				drv := (others => 'Z');
				driving := false;
				dq <= (others => 'Z');
			end if;
			for i in 0 to SCHED_N - 2 loop
				sch_v(i) := sch_v(i + 1);
				sch_d(i) := sch_d(i + 1);
			end loop;
			sch_v(SCHED_N - 1) := false;

			-- auto precharges whose burst/recovery have run close their bank
			for bn in bank_t loop
				if ap_close(bn) >= 0 and cyc >= ap_close(bn) then
					open_b(bn) := false;
					ap_close(bn) := -1;
				end if;
			end loop;

			if cke = '1' and cs_n = '0' then
				cmd := ras_n & cas_n & we_n;
				if cmd /= CMD_NOP then
					-- rule 7: only NOPs before the power-up window closes
					if now < POWERUP_US * 1 us then
						vio := vio + 1;
						report "sdram_chip: command during the power-up window (cycle "
							& integer'image(cyc) & ", t" & integer'image(now / 1 ns) & " ns)"
							severity error;
					end if;
					-- rule 6b: after a REFRESH nothing but NOPs before TRFC
					if cyc < t_ref_ok then
						vio := vio + 1;
						report "sdram_chip: command before TRFC after REFRESH (cycle "
							& integer'image(cyc) & ", t" & integer'image(now / 1 ns) & " ns)"
							severity error;
					end if;

					case cmd is
						when CMD_ACTIVE =>
							b := to_integer(unsigned(ba));
							if open_b(b) then
								-- rule 1; a second ACTIVE cannot re-open a row,
								-- so it is ignored as the command it is
								vio := vio + 1;
								report "sdram_chip: ACTIVE to open bank "
									& integer'image(b) & " (cycle "
									& integer'image(cyc) & ", t" & integer'image(now / 1 ns) & " ns)"
									severity error;
							else
								if cyc < t_act_ok(b) then
									-- rule 4
									vio := vio + 1;
									report "sdram_chip: ACTIVE before TRP after PRECHARGE (bank "
										& integer'image(b) & ", cycle "
										& integer'image(cyc) & ", t" & integer'image(now / 1 ns) & " ns)"
										severity error;
								end if;
								if ever_b(b) and cyc - t_act(b) < TRC then
									-- rule 5
									vio := vio + 1;
									report "sdram_chip: ACTIVE before TRC from the previous ACTIVE (bank "
										& integer'image(b) & ", cycle "
										& integer'image(cyc) & ", t" & integer'image(now / 1 ns) & " ns)"
										severity error;
								end if;
								open_b(b) := true;
								ever_b(b) := true;
								row_b(b) := a;
								t_act(b) := cyc;
								t_rw_ok(b) := cyc + TRCD;
								t_pre_ok(b) := cyc + TRAS;
								ap_close(b) := -1;
							end if;

						when CMD_READ | CMD_WRITE =>
							b := to_integer(unsigned(ba));
							if not open_b(b) then
								-- rule 2a
								vio := vio + 1;
								report "sdram_chip: READ/WRITE to closed bank "
									& integer'image(b) & " (cycle "
									& integer'image(cyc) & ", t" & integer'image(now / 1 ns) & " ns)"
									severity error;
							elsif cyc < t_rw_ok(b) then
								-- rule 2b
								vio := vio + 1;
								report "sdram_chip: READ/WRITE before TRCD from ACTIVE (bank "
									& integer'image(b) & ", cycle "
									& integer'image(cyc) & ", t" & integer'image(now / 1 ns) & " ns)"
									severity error;
							else
								idx := sdram_chip_addr(row_b(b), a(6 downto 0), '0');
								if cmd = CMD_READ then
									sch_d(mode_cl - 1) :=
										sdram_chip_mem(idx + 1) & sdram_chip_mem(idx);
									sch_v(mode_cl - 1) := true;
									if a(10) = '1' then
										-- the burst ends CL + 1 after the command
										ap_close(b) := maxi(ap_close(b), cyc + mode_cl + 1);
										t_act_ok(b) := maxi(t_act_ok(b),
											cyc + mode_cl + 1 + TRP);
									end if;
								else
									if dqm(0) = '0' then
										sdram_chip_mem(idx) := dq(7 downto 0);
									end if;
									if dqm(1) = '0' then
										sdram_chip_mem(idx + 1) := dq(15 downto 8);
									end if;
									if a(10) = '1' then
										-- the write needs TWR before it precharges
										ap_close(b) := maxi(ap_close(b), cyc + TWR);
										t_act_ok(b) := maxi(t_act_ok(b),
											cyc + TWR + TRP);
									end if;
								end if;
							end if;

						when CMD_PRECHARGE =>
							for bn in bank_t loop
								if a(10) = '1' or bn = to_integer(unsigned(ba)) then
									if open_b(bn) then
										if cyc < t_pre_ok(bn) then
											-- rule 3; the bank closes anyway
											vio := vio + 1;
											report "sdram_chip: PRECHARGE before TRAS from ACTIVE (bank "
												& integer'image(bn) & ", cycle "
												& integer'image(cyc) & ", t" & integer'image(now / 1 ns) & " ns)"
												severity error;
										end if;
										open_b(bn) := false;
										ap_close(bn) := -1;
										t_act_ok(bn) := maxi(t_act_ok(bn), cyc + TRP);
									end if;
								end if;
							end loop;

						when CMD_REFRESH =>
							for bn in bank_t loop
								if open_b(bn) then
									-- rule 6a
									vio := vio + 1;
									report "sdram_chip: REFRESH with bank "
										& integer'image(bn) & " open (cycle "
										& integer'image(cyc) & ", t" & integer'image(now / 1 ns) & " ns)"
										severity error;
								end if;
							end loop;
							t_ref_ok := cyc + TRFC;
							-- rule 9: the check starts with the first refresh
							-- that has a ROWS-th predecessor
							if n_ref >= ROWS
							   and now - ref_hist(n_ref mod ROWS) > REFRESH_US * 1 us then
								vio := vio + 1;
								report "sdram_chip: fewer than " & integer'image(ROWS)
									& " refreshes in the " & real'image(REFRESH_US)
									& " us window (cycle " & integer'image(cyc)
									& ", t" & integer'image(now / 1 ns) & " ns)"
									severity error;
							end if;
							ref_hist(n_ref mod ROWS) := now;
							n_ref := n_ref + 1;
							refr := refr + 1;

						when CMD_MODE =>
							if to_integer(unsigned(a(6 downto 4))) = 2 then
								mode_cl := 2;
							else
								-- this machine only ever runs CL 2
								report "sdram_chip: LOAD MODE with CAS latency "
									& integer'image(to_integer(unsigned(a(6 downto 4))))
									& " instead of 2 (cycle " & integer'image(cyc)
									& ", t" & integer'image(now / 1 ns) & " ns)"
									severity warning;
								mode_cl := maxi(
									to_integer(unsigned(a(6 downto 4))), 1);
							end if;
							if a(2 downto 0) /= "000" then
								report "sdram_chip: LOAD MODE asks for a burst longer than 1 (cycle "
									& integer'image(cyc) & ", t" & integer'image(now / 1 ns)
									& " ns); the model implements burst length 1"
									severity warning;
							end if;

						when others =>
							null;   -- the reserved encodings are NOPs for the model
					end case;
				end if;
			end if;

			violations <= vio;
			refreshes <= refr;
		end if;
	end process;

end architecture;
