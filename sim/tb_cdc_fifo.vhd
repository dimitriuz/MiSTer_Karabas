-------------------------------------------------------------------------------
-- tb_cdc_fifo: rtl/mem/cdc_fifo.vhd at the video instance's geometry
-- (DW = 12, AW = 3, the generic map of rtl/video/video_cdc.sv).
-------------------------------------------------------------------------------
-- Run with: tools/sim.sh sim/run_tb_cdc_fifo.sh
--
-- The two clocks are unrelated: 35.5 ns and 13.47 ns periods, whose edges
-- never coincide (the periods are 35500 and 13470 ps and the first edges are
-- 11015 ps apart, not a multiple of gcd(35500, 13470) = 10 ps). Case 1 runs
-- the write side slow and the read side fast; case 4 swaps them. The strobes
-- come from two fixed-seed 16-bit LFSRs, one per side, stepped on the falling
-- edge of that side's clock, so a run is repeatable.
--
-- Reset follows the contract at the head of cdc_fifo.vhd: both resets
-- together, held for 300 ns (at least 8 clocks of the 35.5 ns domain and 22
-- of the 13.47 ns domain), released together on a falling edge of the slower
-- clock.
--
-- Cases, each printing its own line:
--   random_wr_slow  2048 words with wr 35.5 ns / rd 13.47 ns. Every accepted
--                   write carries the written counter (the LFSR strobe is
--                   suppressed while `full`); the reader compares q with the
--                   expected next counter at every rd = '1' edge with
--                   empty = '0', and the run ends with 2048 read. `afull`
--                   must be high at every write edge where the writer sees
--                   six or more cells used (the TB models the read pointer's
--                   two-flop synchroniser).
--   fill            reader stopped: empty = '1' after reset, exactly 8 writes
--                   accepted (full = '0' before each and after the first 7,
--                   '1' after the 8th), afull = '1' from 6 stored on,
--                   empty = '0' once the first word has crossed, q = word 0.
--   drain           the 8 words read back in order: empty = '0' and q = the
--                   expected word at every rd = '1' edge, empty = '1' after
--                   the 8th read, and q = the next word while empty = '0'.
--   random_wr_fast  the same random run with the clocks swapped (wr 13.47 ns,
--                   rd 35.5 ns), so the writer is the fast side.
--
-- The verdict is `tb_cdc_fifo: PASS` or `tb_cdc_fifo: FAIL <case> <reason>`.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_cdc_fifo is
end tb_cdc_fifo;

architecture sim of tb_cdc_fifo is

	constant DW    : natural := 12;    -- the video word
	constant AW    : natural := 3;     -- 8 cells, as video_cdc.sv instantiates
	constant DEPTH : natural := 2**AW;
	constant N_RANDOM : natural := 2048;  -- words of each random case

	-- half periods of the two unrelated clocks (35.5 ns and 13.47 ns)
	constant T_SLOW : time := 17750 ps;
	constant T_FAST : time := 6735 ps;

	signal wr_clk : std_logic := '0';
	signal rd_clk : std_logic := '0';
	signal wr_half : time := T_SLOW;
	signal rd_half : time := T_FAST;

	signal wr_rst : std_logic := '1';
	signal rd_rst : std_logic := '1';
	signal wr : std_logic := '0';
	signal rd : std_logic := '0';
	signal d  : std_logic_vector(DW - 1 downto 0) := (others => '0');
	signal q  : std_logic_vector(DW - 1 downto 0);
	signal full, afull, empty : std_logic;

	-- Galois LFSR, x^16 + x^14 + x^13 + x^11 + 1 (mask 0xB400): a fixed seed
	-- makes the strobe pattern of a run repeatable
	function lfsr_step (s : std_logic_vector(15 downto 0)) return std_logic_vector is
		variable v : std_logic_vector(15 downto 0);
	begin
		v := s(14 downto 0) & '0';
		if s(15) = '1' then
			v := v xor x"B400";
		end if;
		return v;
	end function;

begin

	U_FIFO: entity work.cdc_fifo
		generic map (DW => DW, AW => AW)
		port map (
			wr_clk => wr_clk, wr_rst => wr_rst, wr => wr, d => d,
			full => full, afull => afull,
			rd_clk => rd_clk, rd_rst => rd_rst, rd => rd, q => q, empty => empty
		);

	wr_clock: process
	begin
		wr_clk <= '0';
		loop
			wait for wr_half;
			wr_clk <= '1';
			wait for wr_half;
			wr_clk <= '0';
		end loop;
	end process;

	rd_clock: process
	begin
		rd_clk <= '0';
		loop
			wait for rd_half;
			rd_clk <= '1';
			wait for rd_half;
			rd_clk <= '0';
		end loop;
	end process;

main: process

	variable bad      : boolean := false;  -- any case of the run
	variable bad_case : boolean := false;  -- the case being run
	variable n_written : natural;          -- accepted writes
	variable n_read    : natural;          -- pops, and the expected next word
	variable rq1, rq2  : natural;          -- TB model of the two-flop rbg sync
	variable used_model : natural;         -- wb - rbg_s2 as the writer sees it
	variable lw, lr    : std_logic_vector(15 downto 0);

	procedure fail (name : in string; reason : in string) is
	begin
		bad := true;
		bad_case := true;
		report "tb_cdc_fifo: FAIL " & name & " " & reason severity error;
	end procedure;

	procedure pass (name : in string) is
	begin
		report "tb_cdc_fifo: case " & name & " ok";
	end procedure;

	-- both resets together, well over three clocks of either domain, released
	-- together on a falling edge of the slower one
	procedure do_reset is
	begin
		wr <= '0';
		rd <= '0';
		d <= (others => '0');
		wr_rst <= '1';
		rd_rst <= '1';
		wait for 300 ns;
		if wr_half >= rd_half then
			wait until falling_edge(wr_clk);
		else
			wait until falling_edge(rd_clk);
		end if;
		wr_rst <= '0';
		rd_rst <= '0';
		wait for 1 ns;
	end procedure;

	-- case 1 and 4: LFSR strobes on both sides until `n` words are written
	-- and read. The process handles whichever clock changed; at a (possible)
	-- simultaneous edge the write side is handled first, as the DUT's
	-- synchroniser samples the read pointer before that edge's pop.
	procedure random_case (name : in string; n : in natural) is
	begin
		n_written := 0;
		n_read := 0;
		rq1 := 0;
		rq2 := 0;
		used_model := 0;
		lw := x"ACE1";
		lr := x"1234";
		bad_case := false;
		wr <= '0';
		rd <= '0';
		loop
			wait on wr_clk, rd_clk;

			if wr_clk'event then
				if rising_edge(wr_clk) then
					-- afull has been stable since the previous write edge:
					-- check it against the writer's view of that moment
					if used_model >= DEPTH - 2 and afull /= '1' then
						fail(name, "afull low with " & integer'image(used_model) & " used");
					end if;
					-- the DUT updates wb and rbg_s2 on this edge
					rq2 := rq1;
					rq1 := n_read;
					if wr = '1' then
						if full = '1' then
							fail(name, "write while full");
						end if;
						n_written := n_written + 1;
					end if;
					used_model := n_written - rq2;
				else
					lw := lfsr_step(lw);
					if lw(15) = '1' and full = '0' and n_written < n then
						wr <= '1';
						d <= std_logic_vector(to_unsigned(n_written, DW));
					else
						wr <= '0';
					end if;
				end if;
			end if;

			if rd_clk'event then
				if rising_edge(rd_clk) then
					if rd = '1' then
						if empty /= '0' then
							fail(name, "pop while empty at read " & integer'image(n_read));
						elsif n_read >= n then
							fail(name, "read past the last word");
						else
							if unsigned(q) /= to_unsigned(n_read, DW) then
								fail(name, "word " & integer'image(n_read) & " is " &
									integer'image(to_integer(unsigned(q))));
							end if;
							n_read := n_read + 1;
						end if;
					end if;
				else
					lr := lfsr_step(lr);
					if lr(15) = '1' and empty = '0' and n_read < n then
						rd <= '1';
					else
						rd <= '0';
					end if;
				end if;
			end if;

			exit when n_written >= n and n_read >= n;
		end loop;

		wr <= '0';
		rd <= '0';
		-- the afull of the last write settles on the next write edge
		wait until rising_edge(wr_clk);
		if used_model >= DEPTH - 2 and afull /= '1' then
			fail(name, "afull low at the end with " & integer'image(used_model) & " used");
		end if;
		wait for 1 ns;
		if n_written /= n then
			fail(name, "wrote " & integer'image(n_written) & " of " & integer'image(n));
		end if;
		if n_read /= n then
			fail(name, "read " & integer'image(n_read) & " of " & integer'image(n));
		end if;
		if empty /= '1' then
			fail(name, "not empty after the last read");
		end if;
		if not bad_case then
			pass(name);
		end if;
	end procedure;

begin

	-- random_wr_slow: write side 35.5 ns, read side 13.47 ns -------------------
	do_reset;
	wait for 200 ns;
	random_case("random_wr_slow", N_RANDOM);

	-- fill: reader stopped ------------------------------------------------------
	do_reset;
	wait for 200 ns;
	bad_case := false;
	wait for 1 ns;
	if empty /= '1' then
		fail("fill", "not empty after reset");
	end if;
	if full /= '0' then
		fail("fill", "full after reset");
	end if;
	for i in 0 to DEPTH - 1 loop
		wait until rising_edge(wr_clk);
		if full /= '0' then
			fail("fill", "full before write " & integer'image(i));
		end if;
		wr <= '1';
		d <= std_logic_vector(to_unsigned(i, DW));
		wait until rising_edge(wr_clk);
		wr <= '0';
		wait for 1 ns;
		if i < DEPTH - 1 and full /= '0' then
			fail("fill", "full after " & integer'image(i + 1) & " writes");
		end if;
		-- afull is conservative: it must be high from six stored on, but it
		-- is not required to be low below that
		if i + 1 >= DEPTH - 2 and afull /= '1' then
			fail("fill", "afull low at " & integer'image(i + 1) & " stored");
		end if;
		if i = 0 then
			-- let the first word cross the two-flop read synchroniser
			for k in 1 to 8 loop
				wait until rising_edge(rd_clk);
			end loop;
			wait for 1 ns;
		end if;
		if empty /= '0' then
			fail("fill", "empty while storing word " & integer'image(i));
		end if;
	end loop;
	wait for 1 ns;
	if full /= '1' then
		fail("fill", "full did not rise after 8 writes");
	end if;
	if unsigned(q) /= to_unsigned(0, DW) then
		fail("fill", "q is not the first word");
	end if;
	if not bad_case then
		pass("fill");
	end if;

	-- drain: read the 8 words back ---------------------------------------------
	bad_case := false;
	wait until rising_edge(rd_clk);  -- align to an edge with rd = '0'
	for i in 0 to DEPTH - 1 loop
		rd <= '1';
		wait until rising_edge(rd_clk);
		if empty /= '0' then
			fail("drain", "empty at read " & integer'image(i));
		end if;
		if unsigned(q) /= to_unsigned(i, DW) then
			fail("drain", "word " & integer'image(i) & " is " &
				integer'image(to_integer(unsigned(q))));
		end if;
		rd <= '0';
		wait until rising_edge(rd_clk);
		wait for 1 ns;
		if i < DEPTH - 1 then
			if empty /= '0' then
				fail("drain", "empty after read " & integer'image(i));
			end if;
			if unsigned(q) /= to_unsigned(i + 1, DW) then
				fail("drain", "q after read " & integer'image(i) & " is " &
					integer'image(to_integer(unsigned(q))));
			end if;
		else
			if empty /= '1' then
				fail("drain", "empty did not rise after the 8th read");
			end if;
		end if;
	end loop;
	if not bad_case then
		pass("drain");
	end if;

	-- random_wr_fast: the swapped clock ratio, write side 13.47 ns -------------
	wr_half <= T_FAST;
	rd_half <= T_SLOW;
	do_reset;
	wait for 200 ns;
	random_case("random_wr_fast", N_RANDOM);

	-- the verdict ---------------------------------------------------------------
	if bad then
		report "tb_cdc_fifo: FAIL one or more cases failed" severity failure;
	else
		report "tb_cdc_fifo: PASS";
	end if;
	wait;

end process;

end sim;