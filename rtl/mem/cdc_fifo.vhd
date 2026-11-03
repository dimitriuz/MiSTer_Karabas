-------------------------------------------------------------------------------
-- cdc_fifo: an asynchronous FIFO of 2**AW cells, gray-coded read/write pointers
-- and two-flop pointer synchronisers (the classic Cummings design). The write side
-- is `wr_clk`, the read side `rd_clk`; no cell is written and read in the same
-- clock, and the write side only touches a cell after the read side's pointer has
-- come around to it again. `rd = '1'` steps to the next cell, `wr = '1'` appends `d`.
--
-- `q` is the combinational output of the cell the read pointer points at: valid
-- whenever `empty = '0'`, it does not need a clock of its own.
--
-- Both `wr_rst` and `rd_rst` have to be asserted together (they are ARESET here), and
-- held for at least three clocks of the slower domain: the pointer synchronisers are
-- cleared by their own clock, so reset has to be seen twice by each side with a clock
-- of room at the release, and the far pointer has to be visible at zero before `full`
-- and `empty` mean anything. Release it earlier and a pointer can move against a
-- synchroniser that has not caught up, reading or writing a cell the other side does
-- not expect.
--
-- `wr = '1'` while `full = '1'` silently loses the datum; the caller must size the
-- queue for its traffic. sram_bridge guards its write queue with an assertion.
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity cdc_fifo is
generic (
	DW : natural := 8;                        -- cell width
	AW : natural := 2                         -- log2 of the depth (>= 2)
);
port (
	wr_clk : in  std_logic;
	wr_rst : in  std_logic := '0';
	wr     : in  std_logic := '0';
	d      : in  std_logic_vector(DW - 1 downto 0) := (others => '0');
	full   : out std_logic;

	rd_clk : in  std_logic;
	rd_rst : in  std_logic := '0';
	rd     : in  std_logic := '0';
	q      : out std_logic_vector(DW - 1 downto 0);
	empty  : out std_logic
);
end cdc_fifo;

architecture RTL of cdc_fifo is

	subtype cell_t is std_logic_vector(DW - 1 downto 0);
	type cell_array is array (0 to 2**AW - 1) of cell_t;

	signal cells : cell_array := (others => (others => '0'));

	-- pointers, binary and gray, one extra bit for the full/empty distinction
	signal wb, wbg  : unsigned(AW downto 0) := (others => '0');
	signal rb, rbg  : unsigned(AW downto 0) := (others => '0');
	signal wbg_s1, wbg_s2 : unsigned(AW downto 0) := (others => '0');
	signal rbg_s1, rbg_s2 : unsigned(AW downto 0) := (others => '0');

	function to_gray (b : unsigned) return unsigned is
		variable g : unsigned(b'range);
	begin
		for i in b'range loop
			if i = b'high then
				g(i) := b(i);
			else
				g(i) := b(i) xor b(i + 1);
			end if;
		end loop;
		return g;
	end function;

begin

	writes: process (wr_clk)
	begin
		if rising_edge(wr_clk) then
			if wr_rst = '1' then
				wb  <= (others => '0');
				wbg <= (others => '0');
			elsif wr = '1' then
				cells(to_integer(wb(AW - 1 downto 0))) <= d;
				wb  <= wb + 1;
				wbg <= to_gray(wb + 1);
			end if;
		end if;
	end process;

	reads: process (rd_clk)
	begin
		if rising_edge(rd_clk) then
			if rd_rst = '1' then
				rb  <= (others => '0');
				rbg <= (others => '0');
			elsif rd = '1' then
				rb  <= rb + 1;
				rbg <= to_gray(rb + 1);
			end if;
		end if;
	end process;

	sync_w: process (rd_clk)              -- the write pointer into the read domain
	begin
		if rising_edge(rd_clk) then
			if rd_rst = '1' then
				wbg_s1 <= (others => '0');
				wbg_s2 <= (others => '0');
			else
				wbg_s1 <= wbg;
				wbg_s2 <= wbg_s1;
			end if;
		end if;
	end process;

	sync_r: process (wr_clk)              -- the read pointer into the write domain
	begin
		if rising_edge(wr_clk) then
			if wr_rst = '1' then
				rbg_s1 <= (others => '0');
				rbg_s2 <= (others => '0');
			else
				rbg_s1 <= rbg;
				rbg_s2 <= rbg_s1;
			end if;
		end if;
	end process;

	empty <= '1' when rbg = wbg_s2 else '0';
	full  <= '1' when wbg = (not rbg_s2(AW downto AW - 1)) & rbg_s2(AW - 2 downto 0) else '0';

	q <= cells(to_integer(rb(AW - 1 downto 0)));

end RTL;
