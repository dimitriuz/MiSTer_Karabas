-------------------------------------------------------------------------------
-- tb_sdram_chip: sim/models/sdram_chip.vhd, the chip-side model with the
-- timing checker the Stage 2 SDRAM controller testbenches (Tasks 3/4) will
-- put on the SDRAM pins. The model decodes the sdram.sv commands on the
-- rising SDRAM_CLK pin, keeps the per-bank timing state and counts every
-- rule break; this testbench drives the pins with scripted command
-- sequences: one legal sequence that must stay clean, and one deliberately
-- broken sequence per rule that must increment `violations` by exactly one.
--
-- Run with: tools/sim.sh sim/run_tb_sdram_chip.sh
--
-- The DUTs and their buses:
--   dut_pwr, dut_win share bus 2 and carry the two rules that want their own
--   small generics: the power-up window (POWERUP_US => 1.0) and the sliding
--   refresh window (ROWS => 4, REFRESH_US => 1.0); both are short enough to
--   run at the start of the simulation while bus 1 idles.
--   dut_main carries everything else with the shipped generics (power-up
--   100 us, CL 2, TRCD 2, TRP 2, TRAS 5, TRC 8, TRFC 8, TWR 2), so its
--   phases run after the 100 us of NOPs the power-up demands.
--
-- Commands are held across one rising SDRAM_CLK edge per cycle, as the
-- controller will hold them. The sequences below count command cycles ("c");
-- the padding NOPs between phases make each phase's first command legal for
-- every rule, and each broken sequence is built so that no other rule can
-- fire in it (noted at the phase).
--
--   power_up      PRECHARGE ALL at ~9 ns: inside dut_pwr's 1 us window and
--                 its only command there -> one violation; dut_win (window
--                 off, same pin values) proves it is the power-up rule and
--                 not the precharge
--   refresh_win   dut_win: 5 refreshes 10 cycles apart (TRFC met; the window
--                 check, which starts with the ROWS-th, is met at the 5th
--                 too), then a 1.4 us pause and a 6th: fewer than 4
--                 refreshes in the last 1 us -> exactly one violation
--   legal         dut_main: PRECHARGE ALL, 2 x REFRESH, LOAD MODE CL2 BL1;
--                 then dq is high-Z one cycle after a READ and just before
--                 CL cycles, the word exactly in the CL-th interval and
--                 'Z' again after it; masked writes write each byte half of
--                 the word and keep the other (array checked); auto-
--                 precharge WRITE and READ on the burst-end path;
--                 `violations` stays 0 over all of it
--   act_open      ACTIVE, ACTIVE 8 later (TRC exactly met, bank never
--                 closed) -> only "ACTIVE to an open bank"
--   rd_closed     READ while every bank is closed -> only "closed bank"
--   rd_trcd       ACTIVE, READ 1 later (< TRCD), bank open -> only TRCD
--   pre_tras      ACTIVE, PRECHARGE 4 later (< TRAS = 5) -> only TRAS
--   act_trp       ACTIVE at 0, PRECHARGE at +8 (>= TRAS), ACTIVE at +9:
--                 1 < TRP broken, 9 >= TRC met -> only TRP
--   act_trc       ACTIVE at 0, PRECHARGE at +5 (= TRAS, met), ACTIVE at +7:
--                 2 >= TRP met, 7 < 8 = TRC broken -> only TRC (the brief's
--                 example sequence)
--   ref_open      ACTIVE, REFRESH while the bank is open -> only rule 6a
--                 (the refresh itself is window-legal: 8192 would be needed)
--   ref_trfc      REFRESH, ACTIVE 5 later (< TRFC = 8) with closed banks
--                 -> only rule 6b
--   dq_content    a legal read while the tb holds dq at 0x0000 through the
--                 CL-th interval: the resolved bus reads 'X' while the model
--                 drives 0xFE01 -> one violation (the model's check can fire
--                 once per edge at most and the window is one interval)
-- The model's array (sdram_chip_mem) is the back door for the data checks;
-- the `refreshes` counters close the book on the AUTO REFRESHes seen.
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use work.sdram_chip_pkg.all;

entity tb_sdram_chip is
end tb_sdram_chip;

architecture sim of tb_sdram_chip is

	-- the SDRAM clock: 28.125 MHz, the T_CK_NS 8.888889 the model documents
	constant HALF_CK : time := 4444444 fs;

	signal clk : std_logic := '0';

	-- bus 1: dut_main, the default-generic DUT
	signal cs1, ras1, cas1, we1 : std_logic := '1';
	signal a1                   : std_logic_vector(12 downto 0) := (others => '0');
	signal dqm1                 : std_logic_vector(1 downto 0)  := "00";
	signal dq1                  : std_logic_vector(15 downto 0) := (others => 'Z');
	signal viol1, refr1         : natural := 0;

	-- bus 2: dut_pwr + dut_win
	signal cs2, ras2, cas2, we2 : std_logic := '1';
	signal a2                   : std_logic_vector(12 downto 0) := (others => '0');
	signal dq2                  : std_logic_vector(15 downto 0) := (others => 'Z');
	signal violp, refrp         : natural := 0;
	signal violw, refrw         : natural := 0;

	-- test words: distinct row/column triples per phase
	constant ROW_A : std_logic_vector(12 downto 0) := "0000000101010";
	constant COL_A : std_logic_vector(7 downto 0)  := "01011100";
	constant ROW_B : std_logic_vector(12 downto 0) := "0010101001100";
	constant COL_B : std_logic_vector(7 downto 0)  := "00101011";
	constant ROW_C : std_logic_vector(12 downto 0) := "0001100110011";
	constant COL_C : std_logic_vector(7 downto 0)  := "01110011";
	constant ROW_R : std_logic_vector(12 downto 0) := "0000011000011";
	constant COL_R : std_logic_vector(7 downto 0)  := "00010110";

	constant A_PRE_ALL  : std_logic_vector(12 downto 0) := (10 => '1', others => '0');
	constant A_MODE     : std_logic_vector(12 downto 0) := "0001000100000";
	constant A_COL_A    : std_logic_vector(12 downto 0) := "00000" & COL_A;
	constant A_COL_B_AP : std_logic_vector(12 downto 0) := "00" & '1' & "00" & COL_B;
	constant A_COL_C    : std_logic_vector(12 downto 0) := "00000" & COL_C;
	constant A_COL_R    : std_logic_vector(12 downto 0) := "00000" & COL_R;

	constant ADR_A0 : natural := sdram_chip_addr(ROW_A, COL_A, '0');
	constant ADR_A1 : natural := sdram_chip_addr(ROW_A, COL_A, '1');
	constant ADR_B0 : natural := sdram_chip_addr(ROW_B, COL_B, '0');
	constant ADR_B1 : natural := sdram_chip_addr(ROW_B, COL_B, '1');
	constant ADR_C0 : natural := sdram_chip_addr(ROW_C, COL_C, '0');
	constant ADR_C1 : natural := sdram_chip_addr(ROW_C, COL_C, '1');

	-- one check; every FAIL names itself, the verdict line comes at the end
	shared variable bad : boolean := false;

	-- the idle bus, spelled as a constant (VHDL-93 will not take an 'others'
	-- aggregate in an equality)
	constant DQ_Z : std_logic_vector(15 downto 0) := (others => 'Z');

begin

	main: process
		variable v0 : natural;

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
				when "ZZZZ" => return "z"; when "XXXX" => return "x";
				when "UUUU" => return "u";
				when others => return "?";
			end case;
		end function;

		function hstr (v : std_logic_vector(15 downto 0)) return string is
		begin
			return hx4(v(15 downto 12)) & hx4(v(11 downto 8))
				& hx4(v(7 downto 4)) & hx4(v(3 downto 0));
		end function;

		function hb01 (v : std_logic_vector(7 downto 0)) return string is
		begin
			return hx4(v(7 downto 4)) & hx4(v(3 downto 0));
		end function;

		procedure check (cond : boolean; what : string) is
		begin
			if not cond then
				bad := true;
				report "tb_sdram_chip: FAIL " & what severity error;
			end if;
		end procedure;

		-- one command on bus 1 plus `after_n` NOP cycles: the call latches the
		-- command on the rising edge of its cycle and returns at the falling
		-- edge that opened it, so consecutive calls are consecutive cycles
		procedure b1_cmd (
			ras_v, cas_v, we_v : std_logic;
			a_v     : std_logic_vector(12 downto 0) := (others => '0');
			dq_v    : std_logic_vector(15 downto 0) := (others => 'Z');
			dqm_v   : std_logic_vector(1 downto 0)  := "00";
			dq_en   : boolean := false;
			after_n : natural := 0
		) is
		begin
			wait until falling_edge(clk);
			cs1  <= '0';
			ras1 <= ras_v; cas1 <= cas_v; we1 <= we_v;
			a1   <= a_v;
			dqm1 <= dqm_v;
			if dq_en then
				dq1 <= dq_v;
			else
				dq1 <= (others => 'Z');
			end if;
			for i in 1 to after_n loop
				wait until falling_edge(clk);
				ras1 <= '1'; cas1 <= '1'; we1 <= '1';
				a1   <= (others => '0');
				dqm1 <= "00";
				dq1  <= (others => 'Z');
			end loop;
		end procedure;

		-- from the position a READ call with after_n => 1 leaves (the falling
		-- edge that opens the first NOP cycle after the command cycle k): a
		-- read of dq1 after n rising edges holds what drove cycle k + n - 1 -
		-- the command cycle at n = 1, the CL-th (read data) cycle at n = 3
		procedure b1_edges (n : natural) is
		begin
			for i in 1 to n loop
				wait until rising_edge(clk);
			end loop;
		end procedure;

		-- hold dq1 low across the CL-th interval of the READ issued last and
		-- until the rising edge that ends it: one contended interval, which is
		-- what the model's once-per-edge check can count once
		procedure b1_contend is
		begin
			wait until falling_edge(clk);         -- cycle k + 2 starts
			dq1 <= x"0000";
			wait until falling_edge(clk);         -- cycle k + 3: the model checks
			                                      -- its CL interval on the rising
			wait until falling_edge(clk);
			dq1 <= (others => 'Z');
		end procedure;

		-- wait n full cycles of NOP (bus 1 stays where it is)
		procedure b1_wait (n : natural) is
		begin
			for i in 1 to n loop
				wait until falling_edge(clk);
			end loop;
		end procedure;

		-- bus 2: one command plus n NOP slots
		procedure b2_cmd (
			ras_v, cas_v, we_v : std_logic;
			a_v     : std_logic_vector(12 downto 0) := (others => '0');
			after_n : natural := 0
		) is
		begin
			wait until falling_edge(clk);
			cs2  <= '0';
			ras2 <= ras_v; cas2 <= cas_v; we2 <= we_v;
			a2   <= a_v;
			for i in 1 to after_n loop
				wait until falling_edge(clk);
				ras2 <= '1'; cas2 <= '1'; we2 <= '1';
				a2   <= (others => '0');
			end loop;
		end procedure;

	begin

	----------------------------------------------------------------------------
	-- bus 2, power_up: PRECHARGE ALL (sdram.sv: 010) at ~9 ns, inside dut_pwr's
	-- 1 us window and its only command there.
	----------------------------------------------------------------------------
		b2_cmd('0', '1', '0', A_PRE_ALL, 3);
		check(violp = 1, "power_up: one violation on dut_pwr, got "
			& natural'image(violp));
		check(violw = 0, "power_up: dut_win (window off) stayed clean, got "
			& natural'image(violw));

	----------------------------------------------------------------------------
	-- bus 2, refresh_win: 5 refreshes (001) 10 cycles apart - TRFC is 8 and
	-- the window check starts at the 5th (ROWS = 4), where 4 x 10 cycles are
	-- far inside 1 us - then 1.4 us of NOPs and a 6th, whose 4-th predecessor
	-- is already 1.7 us old. No further refreshes: exactly one violation.
	----------------------------------------------------------------------------
		wait for 1350 ns;                             -- dut_pwr's window done
		for i in 0 to 4 loop
			b2_cmd('0', '0', '1', (others => '0'), 9);   -- REFRESH + 9 NOP slots
		end loop;
		check(violw = 0, "refresh_win: the legal window stayed clean, got "
			& natural'image(violw));
		check(refrw = 5, "refresh_win: five refreshes counted, got "
			& natural'image(refrw));
		wait for 1400 ns;
		b2_cmd('0', '0', '1', (others => '0'), 3);       -- the 6th, too late
		b2_cmd('1', '1', '1', (others => '0'), 3);
		check(violw = 1, "refresh_win: exactly one late-window violation, got "
			& natural'image(violw));
		check(refrw = 6, "refresh_win: six refreshes counted, got "
			& natural'image(refrw));
		check(violp = 1, "refresh_win: dut_pwr saw them legally, got "
			& natural'image(violp));
		check(refrp = 6, "refresh_win: dut_pwr counted them too, got "
			& natural'image(refrp));

	----------------------------------------------------------------------------
	-- legal: dut_main past the 100 us power-up first.
	----------------------------------------------------------------------------
		wait for 100 us;                                -- bus 2 idle NOPs
		v0 := viol1;
		b1_cmd('0', '1', '0', A_PRE_ALL, after_n => 3);     -- PRECHARGE ALL
		b1_cmd('0', '0', '1', after_n => 9);                -- REFRESH
		b1_cmd('0', '0', '1', after_n => 9);                -- REFRESH
		b1_cmd('0', '0', '0', A_MODE, after_n => 3);        -- LOAD MODE CL2 BL1
		check(refr1 = 2, "legal: two init refreshes, got " & natural'image(refr1));

		-- preload one word and read it back: dq must be high-Z in the command
		-- cycle and in the cycle before CL cycles after it, must hold the word
		-- exactly in the CL-th interval and be 'Z' again after it
		sdram_chip_mem(ADR_A0) := x"3C";
		sdram_chip_mem(ADR_A1) := x"5A";
		b1_cmd('0', '1', '1', ROW_A, after_n => 2);         -- ACTIVE
		b1_cmd('1', '0', '1', A_COL_A, after_n => 1);       -- READ (+1 NOP: the
		b1_edges(1);                                        -- command must not re-latch while sampling
		check(dq1 = DQ_Z, "legal: dq high-Z in the READ command cycle, got "
			& hstr(dq1));
		b1_edges(1);
		check(dq1 = DQ_Z, "legal: dq high-Z one cycle before CL, got "
			& hstr(dq1));
		b1_edges(1);
		check(dq1 = x"5A3C", "legal: the word exactly at CL, got " & hstr(dq1));
		b1_edges(1);
		check(dq1 = DQ_Z, "legal: dq released after the word, got " & hstr(dq1));

		-- masked write of the low byte (dqm 10: high masked): the high byte
		-- must survive untouched
		b1_cmd('0', '1', '0', after_n => 3);             -- PRECHARGE
		b1_cmd('0', '1', '1', ROW_A, after_n => 2);      -- ACTIVE
		b1_cmd('1', '0', '0', A_COL_A, x"5AA5", "10", true, 3); -- WRITE low
		check(sdram_chip_mem(ADR_A0) = x"A5",
			"legal: masked write wrote the low byte, mem=" & hb01(sdram_chip_mem(ADR_A0)));
		check(sdram_chip_mem(ADR_A1) = x"5A",
			"legal: masked write kept the high byte, mem=" & hb01(sdram_chip_mem(ADR_A1)));

		-- and the same with the high byte
		b1_cmd('0', '1', '0', after_n => 3);             -- PRECHARGE
		b1_cmd('0', '1', '1', ROW_A, after_n => 2);      -- ACTIVE
		b1_cmd('1', '0', '0', A_COL_A, x"0F0F", "01", true, 3); -- WRITE high
		check(sdram_chip_mem(ADR_A1) = x"0F",
			"legal: masked write wrote the high byte, mem=" & hb01(sdram_chip_mem(ADR_A1)));
		check(sdram_chip_mem(ADR_A0) = x"A5",
			"legal: masked write kept the low byte, mem=" & hb01(sdram_chip_mem(ADR_A0)));

		-- the word as the two masked writes left it
		b1_cmd('0', '1', '0', after_n => 3);             -- PRECHARGE
		b1_cmd('0', '1', '1', ROW_A, after_n => 2);      -- ACTIVE
		b1_cmd('1', '0', '1', A_COL_A, after_n => 1);    -- READ
		b1_edges(3);
		check(dq1 = x"0FA5", "legal: the word after the masked writes, got "
			& hstr(dq1));

		-- auto precharge: the write closes the bank after TWR, the read after
		-- the burst, and the ACTIVE after each waits TRP (and TRC)
		b1_cmd('0', '1', '0', after_n => 3);             -- PRECHARGE
		b1_cmd('0', '1', '1', ROW_B, after_n => 2);      -- ACTIVE
		b1_cmd('1', '0', '0', A_COL_B_AP, x"BEAD", "00", true, 9); -- WRITE + AP
		check(sdram_chip_mem(ADR_B0) = x"AD",
			"legal: auto-precharge write wrote the low byte, mem=" & hb01(sdram_chip_mem(ADR_B0)));
		check(sdram_chip_mem(ADR_B1) = x"BE",
			"legal: auto-precharge write wrote the high byte, mem=" & hb01(sdram_chip_mem(ADR_B1)));
		b1_cmd('0', '1', '1', ROW_B, after_n => 2);      -- ACTIVE (TWR + TRP + TRC met)
		b1_cmd('1', '0', '1', A_COL_B_AP, after_n => 1); -- READ + AP
		b1_edges(3);
		check(dq1 = x"BEAD", "legal: the auto-precharge read, got " & hstr(dq1));
		b1_wait(12);                                     -- burst-end precharge done

		check(viol1 = v0, "legal: the whole legal sequence stayed at "
			& natural'image(v0) & " violations, got " & natural'image(viol1));

	----------------------------------------------------------------------------
	-- act_open: ACTIVE, ACTIVE at +8. TRC is met exactly and the bank was
	-- never closed, so only "ACTIVE to an open bank" can fire; the model
	-- ignores the second ACTIVE, so the PRECHARGE at +16 is TRAS-clean for
	-- the first one and the next phase starts closed.
	----------------------------------------------------------------------------
		v0 := viol1;
		b1_cmd('0', '1', '1', ROW_R, after_n => 7);      -- ACTIVE
		b1_cmd('0', '1', '1', ROW_R, after_n => 7);      -- ACTIVE to open bank +8
		b1_cmd('0', '1', '0', A_PRE_ALL, after_n => 13); -- PRECHARGE ALL +16
		check(viol1 = v0 + 1, "act_open: exactly one violation, window "
			& natural'image(v0) & ".." & natural'image(viol1));

	----------------------------------------------------------------------------
	-- rd_closed: READ with every bank closed. Nothing else can see it: the
	-- model skips the TRCD check of a bank it never opened.
	----------------------------------------------------------------------------
		v0 := viol1;
		b1_cmd('1', '0', '1', A_COL_R, after_n => 3);    -- READ, closed bank
		check(viol1 = v0 + 1, "rd_closed: exactly one violation, window "
			& natural'image(v0) & ".." & natural'image(viol1));

	----------------------------------------------------------------------------
	-- rd_trcd: ACTIVE, READ at +1 (< TRCD = 2) with the bank open - only the
	-- TRCD rule; the model ignores the read, the PRECHARGE at +10 is clean.
	----------------------------------------------------------------------------
		v0 := viol1;
		b1_cmd('0', '1', '1', ROW_R);                    -- ACTIVE
		b1_cmd('1', '0', '1', A_COL_R, after_n => 8);    -- READ +1 < TRCD
		b1_cmd('0', '1', '0', after_n => 7);             -- PRECHARGE +10 (TRAS met)
		check(viol1 = v0 + 1, "rd_trcd: exactly one violation, window "
			& natural'image(v0) & ".." & natural'image(viol1));

	----------------------------------------------------------------------------
	-- pre_tras: ACTIVE, PRECHARGE at +4 (< TRAS = 5); the bank opened
	-- legally, so only TRAS can fire.
	----------------------------------------------------------------------------
		v0 := viol1;
		b1_cmd('0', '1', '1', ROW_R, after_n => 3);      -- ACTIVE
		b1_cmd('0', '1', '0', after_n => 9);             -- PRECHARGE +4 < TRAS
		check(viol1 = v0 + 1, "pre_tras: exactly one violation, window "
			& natural'image(v0) & ".." & natural'image(viol1));
		b1_wait(12);                                     -- TRP/TRC margin

	----------------------------------------------------------------------------
	-- act_trp: ACTIVE at 0, PRECHARGE at +8 (>= TRAS, legal), ACTIVE at +9:
	-- 1 < TRP = 2 breaks TRP only - TRC counts from the ACTIVE at 0 and is
	-- met at +9.
	----------------------------------------------------------------------------
		v0 := viol1;
		b1_cmd('0', '1', '1', ROW_R, after_n => 7);      -- ACTIVE
		b1_cmd('0', '1', '0');                           -- PRECHARGE +8
		b1_cmd('0', '1', '1', ROW_R, after_n => 12);     -- ACTIVE +9 < TRP
		b1_cmd('0', '1', '0', after_n => 7);             -- PRECHARGE (TRAS met)
		check(viol1 = v0 + 1, "act_trp: exactly one violation, window "
			& natural'image(v0) & ".." & natural'image(viol1));

	----------------------------------------------------------------------------
	-- act_trc, the brief's example: ACTIVE at 0, PRECHARGE at +5 (TRAS met),
	-- ACTIVE at +7: TRP = 2 met, TRC = 8 broken - and only TRC.
	----------------------------------------------------------------------------
		v0 := viol1;
		b1_cmd('0', '1', '1', ROW_R, after_n => 4);      -- ACTIVE
		b1_cmd('0', '1', '0', after_n => 1);             -- PRECHARGE +5
		b1_cmd('0', '1', '1', ROW_R, after_n => 12);     -- ACTIVE +7 < TRC
		b1_cmd('0', '1', '0', after_n => 7);             -- PRECHARGE (TRAS met)
		check(viol1 = v0 + 1, "act_trc: exactly one violation, window "
			& natural'image(v0) & ".." & natural'image(viol1));

	----------------------------------------------------------------------------
	-- ref_open: ACTIVE, REFRESH at +3 while the bank is open. Only rule 6a:
	-- the window check needs 8192 refreshes and TRFC is about the NEXT
	-- command, which waits a full TRFC in the padding.
	----------------------------------------------------------------------------
		v0 := viol1;
		b1_cmd('0', '1', '1', ROW_R, after_n => 2);      -- ACTIVE
		b1_cmd('0', '0', '1', after_n => 8);             -- REFRESH +3, bank open
		b1_cmd('0', '1', '0', after_n => 7);             -- PRECHARGE +12 (TRFC, TRAS)
		check(viol1 = v0 + 1, "ref_open: exactly one violation, window "
			& natural'image(v0) & ".." & natural'image(viol1));

	----------------------------------------------------------------------------
	-- ref_trfc: REFRESH, ACTIVE at +5 (< TRFC = 8) with every bank closed -
	-- only rule 6b.
	----------------------------------------------------------------------------
		v0 := viol1;
		b1_cmd('0', '0', '1', after_n => 4);             -- REFRESH
		b1_cmd('0', '1', '1', ROW_R, after_n => 12);     -- ACTIVE +5 < TRFC
		b1_cmd('0', '1', '0', after_n => 7);             -- PRECHARGE (TRAS met)
		check(viol1 = v0 + 1, "ref_trfc: exactly one violation, window "
			& natural'image(v0) & ".." & natural'image(viol1));

	----------------------------------------------------------------------------
	-- dq_content: a legal read whose CL-th interval the tb holds at 0x0000:
	-- while the model drives 0xFE01 the resolved bus reads 'X' -> the "dq
	-- driven while the model drives" rule, exactly once (one contended
	-- interval, the check fires at most once per edge).
	----------------------------------------------------------------------------
		v0 := viol1;
		sdram_chip_mem(ADR_C0) := x"01";
		sdram_chip_mem(ADR_C1) := x"FE";
		b1_cmd('0', '1', '1', ROW_C, after_n => 2);      -- ACTIVE
		b1_cmd('1', '0', '1', A_COL_C, after_n => 1);    -- READ
		b1_contend;                                      -- hold 0x0000 through it
		b1_cmd('0', '1', '0', after_n => 7);             -- PRECHARGE +5 (TRAS met)
		check(viol1 = v0 + 1, "dq_content: exactly one violation, window "
			& natural'image(v0) & ".." & natural'image(viol1));

	----------------------------------------------------------------------------
	-- the books: nine counted breaks on dut_main (one per rule that runs
	-- there) and four AUTO REFRESHes (init 2 + ref_open + ref_trfc).
	----------------------------------------------------------------------------
		check(viol1 = 9, "total: nine rule breaks on dut_main, got "
			& natural'image(viol1));
		check(refr1 = 4, "total: four refreshes on dut_main, got "
			& natural'image(refr1));
		check(violp = 1 and violw = 1, "total: the generic DUTs hold one each, got "
			& natural'image(violp) & "/" & natural'image(violw));

		if bad then
			report "tb_sdram_chip: FAIL one or more checks failed" severity failure;
		else
			report "tb_sdram_chip: PASS";
		end if;
		wait;

	end process;

	clk <= not clk after HALF_CK;

	dut_main : entity work.sdram_chip
		port map (
			clk => clk, cke => '1', cs_n => cs1,
			ras_n => ras1, cas_n => cas1, we_n => we1,
			ba => "00", a => a1, dqm => dqm1, dq => dq1,
			violations => viol1, refreshes => refr1);

	dut_pwr : entity work.sdram_chip
		generic map (POWERUP_US => 1.0)
		port map (
			clk => clk, cke => '1', cs_n => cs2,
			ras_n => ras2, cas_n => cas2, we_n => we2,
			ba => "00", a => a2, dqm => "00", dq => dq2,
			violations => violp, refreshes => refrp);

	dut_win : entity work.sdram_chip
		generic map (POWERUP_US => 0.0, REFRESH_US => 1.0, ROWS => 4)
		port map (
			clk => clk, cke => '1', cs_n => cs2,
			ras_n => ras2, cas_n => cas2, we_n => we2,
			ba => "00", a => a2, dqm => "00", dq => dq2,
			violations => violw, refreshes => refrw);

end architecture;
