-------------------------------------------------------------------------------
-- sram_bridge: the Karabas main memory behind the SDRAM client interface.
--
-- On the board the Profi's main memory is an asynchronous 2 MiB SRAM: the CPU gets
-- its byte in the same bus cycle it asked for it, with no wait state. Here the same
-- service is delivered out of SDRAM by rtl/mem/sdram.sv (ZX-Spectrum_MISTer
-- @ 756fd4b), whose client interface is: raise `rd` or `we` (a rising edge starts an
-- access, `addr`/`din` held until `ready` returns high), `ready` high when idle.
-- That costs several clk_sdr clocks per access, so a bus cycle cannot wait for it -
-- hence the service contract of this unit:
--
--   * writes (one clk_bus clock `wr_stb`) are queued in order and always land;
--   * a read of `addr` is issued while `rd_req` is high, whenever `dout` does not
--     already hold the byte at `addr` or a write has invalidated it; `dout` then
--     holds it for as long as `addr` stays there, so a held bus cycle is served from
--     the register and a back-to-back read of the same byte costs nothing;
--   * the byte arrives 9 to 11 clk_bus clocks after `rd_req` rises (measured in
--     sim/tb_sram_bridge.vhd, whose model keeps `ready` low for 9 clk_sdr clocks per
--     access; sdram.sv itself takes 3 to 6, for a 7 to 9 clk_bus round trip plus
--     about 2 on a refresh collision). The budget is the 2 T-states after `rd_req`
--     rises, before the T80 latches DI at the end of T2: 16 / 8 / 4 / 2 clk_bus
--     clocks at turbo 00 / 01 / 10 / 11, so turbo 00 is in time without waiting and
--     the faster settings are kept in time by `cpu_wait` alone: hence `cpu_wait`,
--     combinational in clk_bus, high while a CPU read of a byte `dout` does not
--     hold is outstanding or the write queue has no room left for another burst.
--     Through memory.vhd's MEM_WAIT it reaches clock.vhd's WAIT_CPU, which zeroes
--     ENA_CPU and so freezes the CPU (T80s CEN) until the byte is there; profi.vhd
--     applies it only while turbo is on. The generated profi.vhd feeds the wait to
--     the T80 WAIT_n pin as well (the cpu_wait_n term, needed at turbo 8x: one
--     T-state is one clk_bus there, and only WAIT_n stops the clock that samples
--     DI).
--
-- Clock domains: clk_bus (28.125 / 24.107 MHz) for the CPU side, clk_sdr (112.5 MHz)
-- for the SDRAM side. Everything crossing is a cdc_fifo (gray pointers, two-flop
-- pointer synchronisers): the write queue, the read requests and the read responses.
-- No bus is sampled in the other domain without one, and a queued cell is only read
-- once its pointer has been visible for two clocks of the reading domain.
--
-- Ordering and staleness:
--   * the SDRAM side serves a queued write before a pending read, so a read of a
--     byte written just before it sees the new value;
--   * a response is only taken for `dout` if no write has been queued since the read
--     was issued (the write counter), otherwise it may have raced the write;
--   * the request of a read that is in flight cannot be cancelled, so when the CPU
--     changes `addr` mid-cycle the stale answer is dropped and a new read is issued:
--     the response carries the address it was read for.
--   * nothing is issued until 16384 clk_sdr clocks after reset, because sdram.sv is
--     refreshing for about 12100 of them and answers nothing in the meantime although
--     its `ready` is high;
--   * a response is dropped when a write to the same byte is queued in its clock: that
--     write lands after the byte was read, so the response is already stale.
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity sram_bridge is
port (
	clk_bus  : in  std_logic;
	clk_sdr  : in  std_logic;
	reset    : in  std_logic;                        -- ARESET, active high

	rd_req   : in  std_logic;                        -- level: a CPU read wants addr
	wr_stb   : in  std_logic;                        -- one clk_bus clock: write din to addr
	addr     : in  std_logic_vector(20 downto 0);    -- byte address in the 2 MiB SRAM map
	din      : in  std_logic_vector(7 downto 0);
	dout     : out std_logic_vector(7 downto 0);     -- clk_bus domain, data of the last completed read
	cpu_wait : out std_logic;                         -- clk_bus domain, combinational: hold the CPU
	-- to sdram (clk_sdr domain)
	sd_addr  : out std_logic_vector(24 downto 0);
	sd_din   : out std_logic_vector(7 downto 0);
	sd_rd    : out std_logic;
	sd_we    : out std_logic;
	sd_dout  : in  std_logic_vector(7 downto 0);
	sd_ready : in  std_logic
);
end sram_bridge;

architecture RTL of sram_bridge is

	constant ADDR_W : natural := 21;     -- the byte address of the 2 MiB main map
	constant QW     : natural := ADDR_W + 8;

	component cdc_fifo
	generic (
		DW : natural := 8;
		AW : natural := 2
	);
	port (
		wr_clk : in  std_logic;
		wr_rst : in  std_logic := '0';
		wr     : in  std_logic := '0';
		d      : in  std_logic_vector(DW - 1 downto 0) := (others => '0');
		full   : out std_logic;
		afull  : out std_logic;
		rd_clk : in  std_logic;
		rd_rst : in  std_logic := '0';
		rd     : in  std_logic := '0';
		q      : out std_logic_vector(DW - 1 downto 0);
		empty  : out std_logic
	);
	end component;

	type state_t is (s_idle, s_busy);

	-- the write queue: 8 places, drained in about 3 clk_bus clocks per write; the
	-- CPU can strobe every clock in turbo, its `cpu_wait` (from `afull`) keeps it
	-- two places away from full
	signal wq_d, wq_q     : std_logic_vector(QW - 1 downto 0);
	signal wq_wr, wq_pop  : std_logic := '0';
	signal wq_full, wq_afull, wq_empty : std_logic;

	-- the read requests, one in flight at a time, and their responses
	signal rq_d, rq_q     : std_logic_vector(ADDR_W - 1 downto 0);
	signal rq_wr, rq_pop  : std_logic := '0';
	signal rq_full, rq_empty : std_logic;
	signal cq_d, cq_q     : std_logic_vector(QW - 1 downto 0);
	signal cq_wr, cq_pop  : std_logic := '0';
	signal cq_full, cq_empty : std_logic;

	-- clk_bus domain
	signal dout_r         : std_logic_vector(7 downto 0) := (others => '0');
	signal valid_addr     : std_logic_vector(ADDR_W - 1 downto 0) := (others => '0');
	signal have_valid     : std_logic := '0';
	signal out_rd         : std_logic := '0';
	signal wseq           : unsigned(7 downto 0) := (others => '0');
	signal rd_wseq        : unsigned(7 downto 0) := (others => '0');
	signal stale, rd_push : std_logic;

	-- clk_sdr domain
	signal st             : state_t := s_idle;
	signal t              : unsigned(3 downto 0) := (others => '0');
	signal acc_we         : std_logic := '0';
	signal acc_addr       : std_logic_vector(ADDR_W - 1 downto 0) := (others => '0');
	signal sd_din_r       : std_logic_vector(7 downto 0) := (others => '0');

	-- sdram.sv: after `init` it spends some 12100 clk_sdr clocks refreshing
	-- (STATE_STARTUP) and `ready` tells nothing about it - it is high while the refresh
	-- runs - so a request in that window ends with the client believing garbage. The
	-- bridge counts the window itself and keeps everything queued meanwhile.
	constant SD_STARTUP_C : natural := 16384;
	signal sd_start       : natural := SD_STARTUP_C;

begin

	U_WQ: cdc_fifo
	generic map (DW => QW, AW => 3)
	port map (
		wr_clk => clk_bus, wr_rst => reset, wr => wq_wr, d => wq_d, full => wq_full,
		afull => wq_afull,
		rd_clk => clk_sdr, rd_rst => reset, rd => wq_pop, q => wq_q, empty => wq_empty
	);

	U_RQ: cdc_fifo
	generic map (DW => ADDR_W, AW => 2)
	port map (
		wr_clk => clk_bus, wr_rst => reset, wr => rq_wr, d => rq_d, full => rq_full,
		afull => open,
		rd_clk => clk_sdr, rd_rst => reset, rd => rq_pop, q => rq_q, empty => rq_empty
	);

	-- the responses come back the other way
	U_CQ: cdc_fifo
	generic map (DW => QW, AW => 2)
	port map (
		wr_clk => clk_sdr, wr_rst => reset, wr => cq_wr, d => cq_d, full => cq_full,
		afull => open,
		rd_clk => clk_bus, rd_rst => reset, rd => cq_pop, q => cq_q, empty => cq_empty
	);

	-- a queued write must never be lost. The fastest Z80 write cycle is 5 T-states,
	-- i.e. about 20 clk_bus clocks at the 7 MHz limit (the ROM loader writes once
	-- every 128) while a place frees in about 4 - eight of them are here for the
	-- burst of a write that meets an access already in flight. In turbo the CPU can
	-- write on every clock; `cpu_wait` (from `afull`, two places of headroom for
	-- the registered ENA_CPU) freezes it before this can fire.
	assert not (wr_stb = '1' and wq_full = '1')
		report "sram_bridge: the write queue is full" severity failure;
	assert not (cq_wr = '1' and cq_full = '1')
		report "sram_bridge: the response queue is full" severity failure;

	-- dout holds the byte at addr, or it does not
	stale <= '1' when have_valid = '0' or valid_addr /= addr else '0';
	rd_push <= '1' when rd_req = '1' and out_rd = '0' and stale = '1' and rq_full = '0'
	           else '0';

	-- hold the CPU while dout does not hold the byte a read wants (its answer is on
	-- its way) or the write queue has no room left for another burst. Combinational
	-- on purpose: clock.vhd registers WAIT_CPU into ENA_CPU, so the freeze already
	-- takes effect one clock late, and at turbo 8x the CPU samples DI two clocks
	-- after rd_req rises
	cpu_wait <= (rd_req and stale) or wq_afull;

	cpu: process (clk_bus)
	begin
		if rising_edge(clk_bus) then
			wq_wr <= '0';
			rq_wr <= '0';
			if reset = '1' then
				have_valid <= '0';
				out_rd     <= '0';
				wseq       <= (others => '0');
				dout_r     <= (others => '0');
			else
				-- a write to the byte dout holds invalidates it: the CPU reads its own
				-- write back out of the SDRAM
				if wr_stb = '1' and have_valid = '1' and addr = valid_addr then
					have_valid <= '0';
				end if;
				if wr_stb = '1' then
					wq_d  <= addr & din;
					wq_wr <= '1';
					wseq  <= wseq + 1;
				end if;

				-- the answer of the read in flight: good enough for dout when `addr` still
				-- wants that byte, no write was queued after the read went out, and no write
				-- is queued in this very clock. A write queued before the read went out is
				-- served before it by the SDRAM side (a write wins a pending read there), so
				-- it cannot make the answer stale. One queued now lands after the byte was
				-- read, so the answer on its way is already wrong - and taking it would undo
				-- the invalidation above: dout would hold the byte the write just replaced,
				-- be marked valid for `addr`, and nothing would read the array again.
				if out_rd = '1' and cq_empty = '0' then
					cq_pop <= '1';
					out_rd <= '0';
					if cq_q(QW - 1 downto 8) = addr and rd_wseq = wseq and wr_stb = '0' then
						dout_r     <= cq_q(7 downto 0);
						valid_addr <= cq_q(QW - 1 downto 8);
						have_valid <= '1';
					end if;
				else
					cq_pop <= '0';
				end if;

				if rd_push = '1' then
					rq_d   <= addr;
					rq_wr  <= '1';
					if wr_stb = '1' then
						rd_wseq <= wseq + 1;   -- this clock's write goes out first as well
					else
						rd_wseq <= wseq;
					end if;
					out_rd <= '1';
				end if;
			end if;
		end if;
	end process;

	sd_addr <= "0000" & acc_addr;     -- the main map sits at SDRAM byte 0
	sd_din  <= sd_din_r;
	dout    <= dout_r;

	sdram_side: process (clk_sdr)
	begin
		if rising_edge(clk_sdr) then
			wq_pop <= '0';
			rq_pop <= '0';
			cq_wr  <= '0';
			if reset = '1' then
				st     <= s_idle;
				t      <= (others => '0');
				sd_rd  <= '0';
				sd_we    <= '0';
				sd_start <= SD_STARTUP_C;
			elsif sd_start /= 0 then
				sd_start <= sd_start - 1;    -- the controller is still refreshing
			else
				case st is
				when s_idle =>
					-- a write always wins over a pending read
					if wq_empty = '0' then
						acc_addr <= wq_q(QW - 1 downto 8);
						sd_din_r <= wq_q(7 downto 0);
						acc_we   <= '1';
						sd_we    <= '1';
						t        <= (others => '0');
						st       <= s_busy;
						wq_pop   <= '1';
					elsif rq_empty = '0' then
						acc_addr <= rq_q;
						acc_we   <= '0';
						sd_rd    <= '1';
						t        <= (others => '0');
						st       <= s_busy;
						rq_pop   <= '1';
					end if;
				when s_busy =>
					if t /= "1111" then
						t <= t + 1;
					end if;
					-- `ready` high again ends the access: for a read, dout of the SDRAM
					-- controller is valid with it. Waiting for two clocks of `t` keeps the
					-- first cycle of the access out of the test: a read of the 16-bit word
					-- the controller already holds never drops `ready` at all, and answers
					-- from the second clock on.
					if sd_ready = '1' and t > 1 then
						sd_we <= '0';
						sd_rd <= '0';
						if acc_we = '0' then
							cq_d  <= acc_addr & sd_dout;
							cq_wr <= '1';
						end if;
						st <= s_idle;
					end if;
				end case;
			end if;
		end if;
	end process;

end RTL;
