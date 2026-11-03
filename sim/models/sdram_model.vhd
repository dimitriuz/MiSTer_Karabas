-------------------------------------------------------------------------------
-- sdram_model: sim-only model of the client side of rtl/mem/sdram.sv
-- (ZX-Spectrum_MISTer @ 756fd4b, tools/upstream-pins.txt). Entity `sdram`, the
-- client ports of that file, no SDRAM pins: the bridge under test only ever talks to
-- the client interface, and the SDRAM pins of the real module belong to the MiSTer
-- top.
--
-- Behaviour copied from sdram.sv:
--   * a rising edge of `we` or `rd` starts an access; `ready` (high when idle) is then
--     low for the whole access and returns high with `dout` valid;
--   * a read of the 16-bit word already in the read register (`ready` high, the last
--     access not a write, addr(24:1) unchanged) is served from that register and does
--     NOT start an access: the latched address follows and `ready` never drops;
--   * a read loads both bytes of its 16-bit word into that register and `dout` selects
--     the byte by the latched addr(0); a write masks one byte of the array;
--   * save_we starts as 1, so the first read is never served from the register.
--
-- Four deliberate differences from sdram.sv, all in the model's favour:
--   * every access takes exactly 9 clocks of `ready` low (sdram.sv takes 3 for a write
--     and 6 for a read at 100 MHz), so the bridge is timed against the slower controller;
--   * an access is never interrupted and a request raised while `ready` is low is a
--     protocol error, reported as one;
--   * after `init` falls it spends 12100 clocks in sdram.sv's STATE_STARTUP, holding
--     `ready` high and answering nothing; a request in that window is a protocol error,
--     reported as one;
--   * the memory array lives in sdram_model_pkg as a shared variable: GHDL cannot select
--     a signal inside an instantiated unit by name, and the testbench has to see whether
--     a write really landed. It is 2 MiB - the map the bridge puts at SDRAM byte 0 - and
--     it is not touched by `init`, so it keeps the content across a reset as the real
--     SDRAM does.
--
-- The array boots with sdram_model_byte(index), so the testbench knows the content
-- without a back door.
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package sdram_model_pkg is

	constant SDRAM_MODEL_BYTES : natural := 2 * 1024 * 1024;

	subtype model_byte_t is std_logic_vector(7 downto 0);
	type model_byte_array is array (0 to SDRAM_MODEL_BYTES - 1) of model_byte_t;

	-- the byte the array boots with at the byte address `idx`
	function sdram_model_byte (idx : natural) return model_byte_t;

	-- the boot content of the whole array
	function sdram_model_boot return model_byte_array;

	-- The model's memory: the model writes it, the testbench reads it back. It is left
	-- uninitialised here and filled at time 0 by the `boot` process: an initialiser would
	-- call a function during elaboration, which GHDL reports as an out-of-order call
	-- (-Welaboration), and the array is 2 MiB so a constant cannot spell it out either.
	shared variable sdram_model_mem : model_byte_array;

end package;

package body sdram_model_pkg is

	function sdram_model_byte (idx : natural) return model_byte_t is
	begin
		-- 251 is prime, so consecutive addresses get different bytes; the loader burst
		-- of the testbench writes a value derived from this one (see tb_sram_bridge)
		return std_logic_vector(to_unsigned(idx mod 251, 8)) xor x"A5";
	end function;

	function sdram_model_boot return model_byte_array is
		variable m : model_byte_array;
	begin
		for i in m'range loop
			m(i) := sdram_model_byte(i);
		end loop;
		return m;
	end function;

end package body;

library IEEE;
use IEEE.std_logic_1164.all;

entity sdram is
port (
	init   : in  std_logic;                                        -- reset, initialise
	clk    : in  std_logic;                                        -- ~112.5 MHz
	addr   : in  std_logic_vector(24 downto 0);                    -- byte address
	dout   : out std_logic_vector(7 downto 0);                     -- data to the cpu
	din    : in  std_logic_vector(7 downto 0);                     -- data from the cpu
	we     : in  std_logic;                                        -- write request
	rd     : in  std_logic;                                        -- read request
	ready  : out std_logic                                         -- dout valid, idle
);
end sdram;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.sdram_model_pkg.all;

architecture model of sdram is

	constant GAP : unsigned(3 downto 0) := "1001";        -- 9 clocks of ready low

	-- sdram.sv STATE_STARTUP: the refresh sequence that has to run before anyone is
	-- served. `ready` says nothing about it, so the client has to count.
	constant STARTUP_C : natural := 12100;
	signal startup     : natural := STARTUP_C;

	signal data      : std_logic_vector(15 downto 0) := (others => '0');
	signal save_addr : std_logic_vector(24 downto 0) := (others => '0');
	signal save_we   : std_logic := '1';              -- sdram.sv: reg save_we = 1

	signal old_we, old_rd : std_logic := '0';
	signal new_data       : model_byte_t := (others => '0');
	signal busy           : std_logic := '0';
	signal acc_we         : std_logic := '0';
	signal acc_addr       : std_logic_vector(24 downto 0) := (others => '0');
	signal timer          : unsigned(3 downto 0) := (others => '0');
	signal rdy            : std_logic := '0';

	-- the byte the access addresses, and the other byte of its 16-bit word
	function byte_index (a : std_logic_vector(24 downto 0)) return natural is
		variable i : natural;
	begin
		i := to_integer(unsigned(a(20 downto 0)));
		if i > SDRAM_MODEL_BYTES - 1 then
			return SDRAM_MODEL_BYTES - 1;
		end if;
		return i;
	end function;

	function other_byte_index (a : std_logic_vector(24 downto 0)) return natural is
		variable i : natural;
	begin
		i := byte_index(a);
		if i mod 2 = 0 then
			i := i + 1;
		else
			i := i - 1;
		end if;
		if i > SDRAM_MODEL_BYTES - 1 then
			return SDRAM_MODEL_BYTES - 1;
		end if;
		return i;
	end function;

begin

	-- sdram.sv: assign dout = save_addr[0] ? data[15:8] : data[7:0]
	dout <= data(15 downto 8) when save_addr(0) = '1' else data(7 downto 0);

	ready <= rdy;

	main: process (clk)
	begin
		if rising_edge(clk) then
			if init = '1' then
				startup <= STARTUP_C;
				rdy     <= '0';
				busy    <= '0';
				old_we  <= '0';
				old_rd  <= '0';
				save_we <= '1';
			elsif startup /= 0 then
				-- sdram.sv STATE_STARTUP: `ready` is high while the refresh sequence
				-- runs, so a client that only watches `ready` can ask for something
				-- that will not be answered. Nothing is answered here, and the client
				-- that asks anyway ends the simulation.
				old_we  <= we;
				old_rd  <= rd;
				rdy     <= '1';
				assert not ((we = '1' and old_we = '0') or (rd = '1' and old_rd = '0'))
					report "sdram_model: request during the startup window"
					severity failure;
				startup <= startup - 1;
			else
				old_we <= we;
				old_rd <= rd;

				assert not (busy = '1' and ((we = '1' and old_we = '0') or
				                            (rd = '1' and old_rd = '0')))
					report "sdram_model: request raised while ready is low"
					severity failure;

				-- a write always starts an access
				if we = '1' and old_we = '0' then
					new_data <= din;
					save_we  <= '1';
					rdy      <= '0';
					busy     <= '1';
					acc_we   <= '1';
					acc_addr <= addr;
					timer    <= GAP;
				end if;

				if rd = '1' and old_rd = '0' then
					if rdy = '1' and save_we = '0' and
					   addr(24 downto 1) = save_addr(24 downto 1) then
						-- the same 16-bit word: served from the read register
						save_addr <= addr;
					else
						save_we  <= '0';
						rdy      <= '0';
						busy     <= '1';
						acc_we   <= '0';
						acc_addr <= addr;
						timer    <= GAP;
					end if;
				end if;

				if busy = '1' then
					if timer = 1 then
						if acc_we = '1' then
							sdram_model_mem(byte_index(acc_addr)) := new_data;
						else
							data(7 downto 0)  <= sdram_model_mem(byte_index(acc_addr));
							data(15 downto 8) <= sdram_model_mem(other_byte_index(acc_addr));
						end if;
						rdy   <= '1';
						busy  <= '0';
					else
						timer <= timer - 1;
					end if;
				end if;
			end if;
		end if;
	end process;

	-- the boot content of the array, applied at time 0 (see the package: no function
	-- call during elaboration)
	boot: process
	begin
		for i in sdram_model_mem'range loop
			sdram_model_mem(i) := sdram_model_byte(i);
		end loop;
		wait;
	end process;

end model;
