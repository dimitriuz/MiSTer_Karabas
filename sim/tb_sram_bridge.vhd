-------------------------------------------------------------------------------
-- tb_sram_bridge: rtl/mem/sram_bridge.vhd, the main memory of the Profi moved
-- from the board's asynchronous 2 MiB SRAM into SDRAM.
-------------------------------------------------------------------------------
-- Run with: tools/sim.sh sim/run_tb_sram_bridge.sh
--
-- The device under test turns the sdram client interface of rtl/mem/sdram.sv
-- (ZX-Spectrum_MISTer @ 756fd4b) into the SRAM-like interface the Karabas CPU saw
-- on the board: `rd_req` (a level: a CPU read wants `addr`), `wr_stb` (one clk_bus
-- clock), `addr`/`din`, `dout`. Behind it sits the sim-only model of that client
-- interface, sim/models/sdram_model.vhd: ready low for 9 clk_sdr clocks per access,
-- a read of the 16-bit word already in its register served from that register.
--
-- clk_sdr is 112.5 MHz. Every case runs at clk_bus 28.125 MHz and again at
-- 24.107 MHz; the case names carry the clock suffix and `both_clocks` summarises the
-- two runs. Writes are queued, so the model's array (sdram_model_mem) is only read
-- after the inputs have been idle long enough for the queue to drain: the model writes
-- the array only while an access is in flight.
--
-- Cases:
--   read_after_reset  the model boots with a known byte per address; rd_req held for
--                     16 clk_bus clocks (the 3.5 MHz CPU's MREQ) returns it, valid
--                     no later than 12 clocks after rd_req rises and stable from
--                     then on
--   write_then_read   wr_stb at A with 0x5A, rd_req at A on the next clk_bus clock ->
--                     dout = 0x5A within 16 clocks and the model holds 0x5A; then the
--                     same byte with the write and the read of it requested on one
--                     clock
--   write_order       four writes to one byte on four consecutive clocks: the queue
--                     keeps them in order, the last value stands
--   write_over_read   dout holds the byte at A; A is written; the next read of A has to
--                     return the written byte and not the one dout cached for it
--   addr_change       rd_req stays high while addr changes twice: dout follows both
--   loader_burst      4096 writes, one every 128 clk_bus clocks (the ROM loader's
--                     pace) at consecutive addresses -> the model holds the bytes
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.sdram_model_pkg.all;

entity tb_sram_bridge is
end tb_sram_bridge;

architecture sim of tb_sram_bridge is

	-- half periods: clk_sdr 8888 ps (112.5 MHz), clk_bus 17777 ps (28.125 MHz) and
	-- 20740 ps (24.107 MHz). Everything here is measured in clk_bus clocks, not ns.
	constant HALF_SDR    : time := 4444 ps;
	constant HALF_BUS_28 : time := 17777 ps;
	constant HALF_BUS_24 : time := 20740 ps;

	-- test byte addresses in the 2 MiB main map
	constant RA0         : natural := 16#0ABC#;   -- read_after_reset
	constant SA          : natural := 16#0BEE#;   -- the setup read of write_then_read
	constant WA          : natural := 16#1234#;   -- write_then_read
	constant WA2         : natural := 16#1236#;   -- ... and its same-clock variant
	constant WA3         : natural := 16#1238#;   -- ... and the stale-dout write
	constant WA4         : natural := 16#123A#;   -- write_during_response
	constant SU          : natural := 16#7E00#;   -- startup
	constant ORD         : natural := 16#2345#;   -- write_order
	constant CA0         : natural := 16#3456#;   -- addr_change
	constant CA1         : natural := 16#4001#;
	constant CA2         : natural := 16#5ABC#;
	constant LOADER_BASE : natural := 16#20000#;  -- loader_burst, clear of the rest
	constant LOADER_N    : natural := 4096;

	signal clk_bus : std_logic := '0';
	signal clk_sdr : std_logic := '0';
	signal reset   : std_logic := '1';

	signal rd_req : std_logic := '0';
	signal wr_stb : std_logic := '0';
	signal addr   : std_logic_vector(20 downto 0) := (others => '0');
	signal din    : std_logic_vector(7 downto 0) := (others => '0');
	signal dout   : std_logic_vector(7 downto 0);

	signal sd_addr  : std_logic_vector(24 downto 0);
	signal sd_din   : std_logic_vector(7 downto 0);
	signal sd_rd    : std_logic;
	signal sd_we    : std_logic;
	signal sd_dout  : std_logic_vector(7 downto 0) := (others => '0');
	signal sd_ready : std_logic := '0';

	signal half_bus : time := HALF_BUS_28;

	function a21 (n : natural) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned(n, 21));
	end function;

begin

	U_BRIDGE: entity work.sram_bridge
	port map (
		clk_bus  => clk_bus,
		clk_sdr  => clk_sdr,
		reset    => reset,
		rd_req   => rd_req,
		wr_stb   => wr_stb,
		addr     => addr,
		din      => din,
		dout     => dout,
		sd_addr  => sd_addr,
		sd_din   => sd_din,
		sd_rd    => sd_rd,
		sd_we    => sd_we,
		sd_dout  => sd_dout,
		sd_ready => sd_ready
	);

	U_MODEL: entity work.sdram
	port map (
		init   => reset,
		clk    => clk_sdr,
		addr   => sd_addr,
		dout   => sd_dout,
		din    => sd_din,
		we     => sd_we,
		rd     => sd_rd,
		ready  => sd_ready
	);

	-- the clocks; half_bus is only rewritten while no case is measuring
	bus_clk: process
	begin
		clk_bus <= '0';
		wait for half_bus;
		clk_bus <= '1';
		wait for half_bus;
	end process;

	sdr_clk: process
	begin
		clk_sdr <= '0';
		wait for HALF_SDR;
		clk_sdr <= '1';
		wait for HALF_SDR;
	end process;

main: process

	variable bad        : boolean := false;   -- any case of any run
	variable bad_run    : boolean := false;   -- any case of this run
	variable bad28      : boolean := false;
	variable bad24      : boolean := false;

	procedure fail (name : in string) is
	begin
		bad := true;
		bad_run := true;
		report "tb_sram_bridge: case " & name & " failed";
	end procedure;

	procedure pass (name : in string) is
	begin
		report "tb_sram_bridge: case " & name & " ok";
	end procedure;

	procedure rise (count : in natural) is
	begin
		for i in 1 to count loop
			wait until rising_edge(clk_bus);
		end loop;
	end procedure;

	-- the inputs idle and the model is quiescent (every queued access has landed), so
	-- that a peek of U_MODEL.mem cannot race
	procedure quiesce (cycles : in natural) is
	begin
		rd_req <= '0';
		wr_stb <= '0';
		rise(cycles);
	end procedure;

	-- the first clk_bus clock at which dout holds `exp`, counted from the clock at
	-- which the procedure is called; good = false if that never happens within `bound`
	procedure watch_byte (exp    : in  std_logic_vector(7 downto 0);
	                      bound  : in  natural;
	                      good   : out boolean;
	                      clocks : out natural) is
	begin
		good := false;
		clocks := 0;
		for i in 1 to bound loop
			wait until rising_edge(clk_bus);
			if dout = exp then
				good := true;
				clocks := i;
				exit;
			end if;
		end loop;
	end procedure;

	-- one write, sampled at the clock edge the procedure returns on
	procedure write_byte (a : in std_logic_vector(20 downto 0);
	                      d : in std_logic_vector(7 downto 0)) is
	begin
		wait until rising_edge(clk_bus);
		addr <= a;
		din <= d;
		wr_stb <= '1';
		wait until rising_edge(clk_bus);
		wr_stb <= '0';
	end procedure;

	-- the bridge holds every request back while the SDRAM controller starts up (sdram.sv
	-- refreshes for about 12100 clk_sdr clocks after init; the bridge counts 16384), so
	-- nothing any case measures can begin before that has passed
	procedure wait_startup is
	begin
		wait for 200 us;
	end procedure;

	-- every case, at the clk_bus frequency selected by half_bus. `flip` xor-ed into
	-- the loader burst's data keeps the two runs' content different, so a write lost
	-- in the second run cannot hide behind the first run's value.
	procedure run_cases (suffix : in string; flip : in std_logic_vector(7 downto 0)) is
		variable ok       : boolean;
		variable ok2      : boolean;
		variable clocks   : natural;
		variable first    : natural;
		variable drifted  : boolean;
		variable exp_byte : std_logic_vector(7 downto 0);
		variable wr_byte  : std_logic_vector(7 downto 0);
	begin
		-- startup ------------------------------------------------------------------
		-- sdram.sv spends some 12100 clk_sdr clocks refreshing after init and its
		-- `ready` may be high throughout, so a request in that window is answered with
		-- nothing. The bridge counts 16384 clk_sdr clocks of its own and keeps
		-- everything in its queues meanwhile, so the write and the read below are served
		-- once the window has passed. The 12-clock bound of the other cases is waived
		-- for this one on purpose: what is checked is that the byte arrives at all, and
		-- that the model never saw a request during its window - it asserts if it did,
		-- which ends the simulation.
		quiesce(8);
		reset <= '1';
		rise(8);
		reset <= '0';
		rise(4);
		wr_byte := x"5D";
		ok2 := dout /= wr_byte;               -- dout must not hold the answer already
		write_byte(a21(SU), wr_byte);         -- queued inside the window
		rd_req <= '1';                        -- ... and this read together with it
		addr <= a21(SU);
		watch_byte(wr_byte, 12000, ok, clocks);
		rd_req <= '0';
		if ok and ok2 then
			pass("startup" & suffix);
		else
			fail("startup" & suffix);
		end if;

		-- read_after_reset ---------------------------------------------------------
		reset <= '1';
		rise(8);
		reset <= '0';
		rise(4);
		wait_startup;                         -- the bridge's own startup count
		exp_byte := sdram_model_byte(RA0);
		ok := dout /= exp_byte;             -- a stale dout must not pass the case
		rd_req <= '1';
		addr <= a21(RA0);
		first := 0;
		drifted := false;
		for i in 1 to 16 loop               -- the 3.5 MHz CPU holds MREQ about that long
			wait until rising_edge(clk_bus);
			if dout = exp_byte then
				if first = 0 then
					first := i;
				end if;
			elsif first /= 0 then
				drifted := true;            -- dout went wrong while the read was held
			end if;
		end loop;
		if not ok or first = 0 or first > 12 or drifted then
			fail("read_after_reset" & suffix);
		else
			pass("read_after_reset" & suffix);
		end if;

		-- write_then_read ----------------------------------------------------------
		quiesce(16);
		rd_req <= '1';                      -- a byte other than 0x5A into dout first
		addr <= a21(SA);
		watch_byte(sdram_model_byte(SA), 32, ok, clocks);
		if not ok then
			fail("write_then_read" & suffix);  -- the setup read itself failed
		else
			-- the write is a bus cycle of its own; rd_req rises on the clock after it
			ok := dout /= x"5A";
			rd_req <= '0';
			write_byte(a21(WA), x"5A");
			rd_req <= '1';                  -- the next clk_bus clock after the write
			addr <= a21(WA);
			watch_byte(x"5A", 16, ok, clocks);
			ok2 := ok;
			-- a write requested on the very clock that a read of that byte is requested:
			-- rd_req is still high and addr moves to the written byte on that clock, so a
			-- write and a read of it are queued together. The SDRAM side serves the write
			-- first, so the read cannot return the byte from before it.
			ok := dout /= x"77";              -- 0x77 must not be in dout already
			ok2 := ok2 and ok;
			write_byte(a21(WA2), x"77");
			watch_byte(x"77", 16, ok, clocks);
			ok2 := ok2 and ok;
			rd_req <= '0';
			quiesce(64);
			ok := (sdram_model_mem(WA) = x"5A") and (sdram_model_mem(WA2) = x"77");
			if ok and ok2 then
				pass("write_then_read" & suffix);
			else
				fail("write_then_read" & suffix);
			end if;
		end if;

		-- write_over_read ------------------------------------------------------------
		-- dout holds the byte at A, A is written, and the read of A that follows has to
		-- report the write: without the invalidation the CPU reads back the byte that was
		-- there before it wrote this one
		quiesce(16);
		-- the array is not reset between the two runs, so both the byte in it and the
		-- byte written over it come from what is there when the case starts
		exp_byte := sdram_model_mem(WA3);
		wr_byte := not exp_byte;
		rd_req <= '1';
		addr <= a21(WA3);
		watch_byte(exp_byte, 32, ok, clocks);
		ok2 := ok;
		rd_req <= '0';
		write_byte(a21(WA3), wr_byte);
		rd_req <= '1';                      -- addr has not moved, only dout may be stale
		watch_byte(wr_byte, 16, ok, clocks);
		rd_req <= '0';
		if ok and ok2 then
			pass("write_over_read" & suffix);
		else
			fail("write_over_read" & suffix);
		end if;

		-- write_during_response ----------------------------------------------------
		-- the response for addr may be accepted in the very clock a write to addr is
		-- queued. Taking it there puts the byte the write replaced into dout, marks it
		-- valid, and nothing reads the array again: dout is wrong for as long as addr
		-- stays. The write's clock is swept across the arrival window so one iteration
		-- hits the coincidence; the bound is generous on purpose, because a response
		-- that has to be dropped costs a second read, and the point here is the value.
		ok2 := true;
		for off in 0 to 15 loop
			rd_req <= '0';
			quiesce(16);
			rd_req <= '1';
			addr <= a21(CA0);
			watch_byte(sdram_model_byte(CA0), 32, ok, clocks);
			if not ok then
				fail("write_during_response" & suffix);   -- the setup read itself
				return;
			end if;
			addr <= a21(WA4);                 -- stale: dout still holds CA0's byte
			wait until rising_edge(clk_bus);  -- the read for WA4 is issued at this clock
			for j in 1 to off loop
				wait until rising_edge(clk_bus);
			end loop;
			wr_byte := std_logic_vector(to_unsigned(16#A0# + off, 8));
			din <= wr_byte;
			wr_stb <= '1';                    -- one clock: with luck, the response's
			wait until rising_edge(clk_bus);
			wr_stb <= '0';
			watch_byte(wr_byte, 48, ok, clocks);
			if not ok then
				ok2 := false;
			end if;
		end loop;
		rd_req <= '0';
		if ok2 then
			pass("write_during_response" & suffix);
		else
			fail("write_during_response" & suffix);
		end if;

		-- write_order --------------------------------------------------------------
		quiesce(16);
		for i in 0 to 3 loop                -- one write every clk_bus clock
			addr <= a21(ORD);
			din <= std_logic_vector(to_unsigned(16#11# * (i + 1), 8)) xor flip;
			wr_stb <= '1';
			wait until rising_edge(clk_bus);
		end loop;
		wr_stb <= '0';
		quiesce(64);
		wr_byte := x"44" xor flip;          -- flip: different from run 1's last value
		if sdram_model_mem(ORD) = wr_byte then
			pass("write_order" & suffix);
		else
			fail("write_order" & suffix);
		end if;

		-- addr_change --------------------------------------------------------------
		quiesce(16);
		rd_req <= '1';
		addr <= a21(CA0);
		watch_byte(sdram_model_byte(CA0), 24, ok, clocks);
		if ok then
			addr <= a21(CA1);               -- rd_req stays high
			watch_byte(sdram_model_byte(CA1), 24, ok, clocks);
		end if;
		if ok then
			addr <= a21(CA2);
			watch_byte(sdram_model_byte(CA2), 24, ok, clocks);
		end if;
		rd_req <= '0';
		if ok then
			pass("addr_change" & suffix);
		else
			fail("addr_change" & suffix);
		end if;

		-- loader_burst -------------------------------------------------------------
		quiesce(16);
		for i in 0 to LOADER_N - 1 loop
			wr_byte := (not sdram_model_byte(LOADER_BASE + i)) xor flip;
			addr <= a21(LOADER_BASE + i);
			din <= wr_byte;
			wr_stb <= '1';
			wait until rising_edge(clk_bus);
			wr_stb <= '0';
			for k in 2 to 128 loop          -- one write every 128 clk_bus clocks
				wait until rising_edge(clk_bus);
			end loop;
		end loop;
		quiesce(256);
		ok := true;
		for i in 0 to LOADER_N - 1 loop
			wr_byte := (not sdram_model_byte(LOADER_BASE + i)) xor flip;
			if sdram_model_mem(LOADER_BASE + i) /= wr_byte then
				ok := false;
			end if;
		end loop;
		if ok then
			pass("loader_burst" & suffix);
		else
			fail("loader_burst" & suffix);
		end if;
	end procedure;

begin

	-- the test addresses must lie in the 2 MiB map the bridge puts at SDRAM byte 0
	assert RA0 < SDRAM_MODEL_BYTES and SA < SDRAM_MODEL_BYTES and WA < SDRAM_MODEL_BYTES
	       and WA2 < SDRAM_MODEL_BYTES
	       and WA3 < SDRAM_MODEL_BYTES
	       and WA4 < SDRAM_MODEL_BYTES
	       and SU < SDRAM_MODEL_BYTES
	       and ORD < SDRAM_MODEL_BYTES and CA0 < SDRAM_MODEL_BYTES
	       and CA1 < SDRAM_MODEL_BYTES and CA2 < SDRAM_MODEL_BYTES
	       and LOADER_BASE + LOADER_N <= SDRAM_MODEL_BYTES
		report "tb_sram_bridge: test address out of range" severity failure;
	-- and their bytes must differ, or dout could satisfy a case by accident
	assert sdram_model_byte(CA0) /= sdram_model_byte(CA1)
	       and sdram_model_byte(CA1) /= sdram_model_byte(CA2)
	       and sdram_model_byte(CA0) /= sdram_model_byte(CA2)
	       and sdram_model_byte(SA) /= x"5A"
	       and sdram_model_byte(RA0) /= x"00"
		report "tb_sram_bridge: test addresses collide" severity failure;

	-- clk_bus 28.125 MHz ---------------------------------------------------------------
	half_bus <= HALF_BUS_28;
	bad_run := false;
	run_cases("_28", x"00");
	bad28 := bad_run;

	-- clk_bus 24.107 MHz ---------------------------------------------------------------
	half_bus <= HALF_BUS_24;
	run_cases("_24", x"5A");
	bad24 := bad_run;

	if bad28 or bad24 then
		fail("both_clocks");
	else
		pass("both_clocks");
	end if;

	if bad then
		report "tb_sram_bridge: FAIL one or more cases failed" severity failure;
	else
		report "tb_sram_bridge: PASS";
	end if;
	wait;

end process;

end sim;
