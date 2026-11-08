-- Replaces upstream src/rtl/memory/memory.vhd @ 01dcd6c (tools/upstream-pins.txt); keep the page mapping, the DivMMC decode, the bus contention, both video RAMs and the loader routing identical.
-------------------------------------------------------------------------------
-- Memory controller
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.conv_integer;
use IEEE.numeric_std.all;

entity memory is
port (
	CLK_BUS		: in std_logic;
	CLK_SDR		: in std_logic;
	ARESET		: in std_logic;

	ENA_CPU 		: in std_logic;
	ENA_GS		: in std_logic;

	A           : in std_logic_vector(15 downto 0); -- address bus
	D 				: in std_logic_vector(7 downto 0);
	N_MREQ		: in std_logic;
	N_IORQ 		: in std_logic;
	N_WR 			: in std_logic;
	N_RD 			: in std_logic;
	N_M1 			: in std_logic;
	
	loader_act 	: in std_logic := '0';
	loader_ram_a: in std_logic_vector(31 downto 0);
	loader_ram_do: in std_logic_vector(7 downto 0);
	loader_ram_wr: in std_logic := '0';
	
	DO 			: out std_logic_vector(7 downto 0);
	N_OE 			: out std_logic;
	
	GS_A			: in std_logic_vector(20 downto 0);
	GS_D			: in std_logic_vector(7 downto 0);
	GS_DO			: out std_logic_vector(7 downto 0);
	GS_N_RD		: in std_logic;
	GS_N_WR		: in std_logic;
	GS_N_RFSH	: in std_logic;
	GS_WAIT_N		: out STD_LOGIC:='1';

	-- Stage 2 (the no-wait SDRAM controller rtl/mem/sdram_nowait.vhd): the
	-- clk_mem-domain clock signals and the CPU visibility the controller
	-- needs; MEM_WAIT is gone, no memory wait reaches the CPU. The defaults
	-- keep the entity elaborable without them (the core profile's
	-- profi.vhd rewrites map all six; MEM_READY may stay unmapped).
	BUS_PHASE	: in std_logic_vector(1 downto 0) := "00";
	RESET_MEM	: in std_logic := '1';
	CPU_TS		: in std_logic_vector(2 downto 0) := "000";
	CPU_MC		: in std_logic_vector(2 downto 0) := "000";
	CPU_RESET_N	: in std_logic := '1';
	MEM_READY	: out std_logic;
	GS_MREQ_N	: in STD_LOGIC;
	
	MA 			: out 	std_logic_vector(20 downto 0);
	MD 			: inout 	std_logic_vector(15 downto 0) := "ZZZZZZZZZZZZZZZZ";
	N_MRD 		: buffer std_logic_vector(1 downto 0);
	N_MWR 		: buffer std_logic_vector(1 downto 0);
	
	SDR_BA 		: out  	std_logic_vector (1 downto 0);
	SDR_A 		: out  	std_logic_vector (12 downto 0);
	SDR_DQM 		: out  	std_logic_vector (1 downto 0);
	SDR_WE_N 	: out  	std_logic := '1';
	SDR_CAS_N 	: out  	std_logic := '1';
	SDR_RAS_N 	: out  	std_logic := '1';
	SDR_DQ 		: inout  std_logic_vector (15 downto 0);
	
	RAM_BANK		: in std_logic_vector(2 downto 0);
	RAM_EXT 		: in std_logic_vector(2 downto 0);
	
	TRDOS 		: in std_logic;

	VA				: in std_logic_vector(13 downto 0);
	VID_PAGE 	: in std_logic := '0';
	VID_DO 		: out std_logic_vector(7 downto 0);
	VID_RD 		: in std_logic;
	
	DS80			: in std_logic := '0';
	CPM 			: in std_logic := '0';
	SCO			: in std_logic := '0';
	SCR 			: in std_logic := '0';
	WOROM 		: in std_logic := '0';
	
	ROM_BANK 	: in std_logic := '0';
	EXT_ROM_BANK : in std_logic_vector(1 downto 0) := "00";
	
	COUNT_BLOCK : in std_logic := '0'; -- paper = '0' and (not (chr_col_cnt(2) and hor_cnt(0)));
	CONTENDED   : out std_logic := '0';
	
	DIVMMC_EN	: in std_logic;
	AUTOMAP		: in std_logic;
	REG_E3		: in std_logic_vector(7 downto 0);
	
	TURBO_MODE	: in std_logic_vector(1 downto 0)
);
end memory;

architecture RTL of memory is

	signal is_rom : std_logic := '0';
	signal is_ram : std_logic := '0';
	
	signal rom_page : std_logic_vector(1 downto 0) := "00";
	signal ram_page : std_logic_vector(5 downto 0) := "000000";

	signal mux : std_logic_vector(1 downto 0);
	
	signal block_reg : std_logic := '0';
	signal page_cont : std_logic := '0';
	
	signal is_romDIVMMC : std_logic;
	signal is_ramDIVMMC : std_logic;

	-- address-only decodes for the controller's sample latch: it latches
	-- port1_a and cpu_wr_en at the M-cycle's start sample (T1), where
	-- T80s has not driven MREQ_n low yet (T80s toggles MREQ_n on the
	-- TState = 1 edge, the end of T1), so the mux may not run through
	-- is_rom / is_ramDIVMMC, which carry the N_MREQ term (N_OE and the
	-- DI mux still do, correctly: they act during the cycle). Same
	-- address terms as those, N_MREQ removed; a stale address (halt,
	-- refresh counters) is harmless because the controller only latches
	-- on MREQ cycles.
	signal rom_a  : std_logic := '0';   -- = is_rom's address part
	signal romm_a : std_logic := '0';   -- = is_romDIVMMC's
	signal ramm_a : std_logic := '0';   -- = is_ramDIVMMC's
	
	signal vid_spec_wr : std_logic := '0';
	signal vid_profi_wr : std_logic := '0';
	signal vid_spec_wr_a_bus, vid_spec_rd_a_bus: std_logic_vector(13 downto 0);
	signal vid_profi_wr_a_bus, vid_profi_rd_a_bus: std_logic_vector(15 downto 0);
	signal vid_wr_attr : std_logic;
	signal vid_wr_page : std_logic;
	signal vid_spec_do, vid_profi_do : std_logic_vector(7 downto 0);
	
	signal port1_a, port2_a : std_logic_vector(20 downto 0);
	signal port2_di : std_logic_vector(7 downto 0);
	signal port1_rfsh, port2_rd, port2_wr, port2_rfsh : std_logic;
	signal cpu_wr_en : std_logic;
	signal port2_a_sdr : std_logic_vector(20 downto 0);
	signal port2_di_sdr : std_logic_vector(7 downto 0);
	signal port2_rd_sdr, port2_wr_sdr, port2_rfsh_sdr , n_mreq_sdr: std_logic;
	signal sdr_wr, sdr_rfsh, sdr_idle, sdr_rd,sdr_gs_wait_n : std_logic;

	-- The physical memory is the no-wait SDRAM controller rtl/mem/sdram_nowait.vhd
	-- (Stage 2); the kg_sdpram declaration is the one tools/prepare_upstream.py
	-- generates for that Verilog module.
	component kg_sdpram
	generic (
		DW : integer := 8;
		AW : integer := 10;
		INIT_FILE : string := ""
	);
	port (
		clka : in std_logic := '0';
		wea : in std_logic := '0';
		addra : in std_logic_vector(AW-1 downto 0) := (others => '0');
		dina : in std_logic_vector(DW-1 downto 0) := (others => '0');
		clkb : in std_logic := '0';
		enb : in std_logic := '0';
		addrb : in std_logic_vector(AW-1 downto 0) := (others => '0');
		doutb : out std_logic_vector(DW-1 downto 0)
	);
	end component;

	signal sram_dout : std_logic_vector(7 downto 0);

	-- port B (the loader) into sdram_nowait: a one-entry buffer, `b_req_r`
	-- raised by a loader byte and dropped when b_done toggles (the
	-- controller answers one access per rising edge; see its header)
	signal b_req_r, b_we_r : std_logic := '0';
	signal b_addr_r : std_logic_vector(20 downto 0) := (others => '0');
	signal b_din_r : std_logic_vector(7 downto 0) := (others => '0');
	signal b_done, b_done_s1, b_done_s2 : std_logic := '0';
	signal b_overrun : std_logic;

	
begin

	-- video ram 16k
	U_SPEC_VRAM: kg_sdpram
	generic map(
		DW 			=> 8,
		AW				=> 14
	)
	port map(
		clka 			=> CLK_BUS,
		wea 			=> vid_spec_wr,
		addra 		=> vid_spec_wr_a_bus,
		dina 			=> D,
		
		clkb 			=> CLK_BUS,
		enb 			=> '1',
		addrb 		=> vid_spec_rd_a_bus,
		doutb 		=> vid_spec_do
	);

	-- video ram 64k
	U_PROFI_VRAM: kg_sdpram
	generic map(
		DW 			=> 8,
		AW				=> 16
	)
	port map(
		clka 			=> CLK_BUS,
		wea 			=> vid_profi_wr,
		addra 		=> vid_profi_wr_a_bus,
		dina 			=> D,
		
		clkb 			=> CLK_BUS,
		enb 			=> '1',
		addrb 		=> vid_profi_rd_a_bus,
		doutb 		=> vid_profi_do
	);
	
	VID_DO <= vid_profi_do when DS80 = '1' else vid_spec_do;

	-- spec page:      0001x1 (x=vid page)
	-- profi pix page: 0001x0 (x=vid_page)
	-- profi att page: 1110x0 (x=vid_page)

	-- video mem write: 
	vid_spec_wr <= '1' when DS80 = '0' and ENA_CPU = '1' and N_MREQ = '0' and N_WR = '0' and A(13) = '0' and (ram_page = "000101" or ram_page = "000111") else -- spectrum pix / att
						'0';
	vid_profi_wr <= '1' when DS80 = '1' and ENA_CPU = '1' and N_MREQ = '0' and N_WR = '0' and (ram_page = "000100" or ram_page = "000110") else -- profi pix
						 '1' when DS80 = '1' and ENA_CPU = '1' and N_MREQ = '0' and N_WR = '0' and (ram_page = "111000" or ram_page = "111010") else -- profi att
						 '0';

	-- detect profi attr write
	vid_wr_attr <= '1' when (ram_page(5 downto 3) = "111") else '0';
	
	-- detect video page for write
	vid_wr_page <= ram_page(1);

	-- write address to vram
	vid_spec_wr_a_bus <= vid_wr_page & A(12 downto 0); 
	vid_profi_wr_a_bus <= vid_wr_attr & vid_wr_page & A(13 downto 0);
		
	-- read address from vram
	vid_spec_rd_a_bus <= VID_PAGE & VA(12 downto 0);
	vid_profi_rd_a_bus <= VID_RD & VID_PAGE & VA(13 downto 0);

	-- The GS SDRAM controller (U_SDRAM, upstream's entity work.sdram, and the clk_sdr
	-- state machine that stepped it) is gone with the move to MiSTer's SDRAM: the GS
	-- cpu is reconnected to the sdram instance below in stage 3. Until then the GS bus
	-- never waits and its reads read 0xFF. (port2_* keeps its assignment below.)
	GS_DO <= x"FF";
	GS_WAIT_N <= '1';

	-- the main memory is the MiSTer SDRAM behind the Stage 2 no-wait
	-- controller rtl/mem/sdram_nowait.vhd: every M-cycle the CPU runs is
	-- served inside the M-cycle, no wait state exists (MEM_WAIT is gone from
	-- the entity). The SRAM pins of the board are not driven.
	MA <= (others => '0');
	MD <= (others => 'Z');
	N_MWR <= "11";
	N_MRD <= "11";
	DO <= sram_dout;

	-- 1 = the addressed byte may be written: the address part of stage 1's
	-- port1_wr (RAM and DIVMMC RAM only - ROM reads through this port never
	-- write). The N_MREQ and N_WR terms of is_ram are dropped ON PURPOSE:
	-- the controller latches this at the M-cycle's start sample, two
	-- clk_mem after the clk_bus edge that starts T1, where T80s has not
	-- driven MREQ_n low yet (it toggles at the end of T1) and WR_n is not
	-- low either - with the MREQ term the latch saw '0' and every CPU
	-- write resolved as a precharge. A stale address (halt, refresh
	-- counters) is harmless: the controller only samples it on MREQ cycles.
	cpu_wr_en <= '1' when rom_a = '0' or ramm_a = '1' else '0';

	U_SDRAM: entity work.sdram_nowait
	port map(
		clk_mem => CLK_SDR,
		reset => RESET_MEM,
		bus_phase => BUS_PHASE,
		ready => MEM_READY,
		cpu_reset_n => CPU_RESET_N,
		cpu_ena => ENA_CPU,
		cpu_ts => CPU_TS,
		cpu_mc => CPU_MC,
		cpu_mreq_n => N_MREQ,
		cpu_rd_n => N_RD,
		cpu_wr_n => N_WR,
		cpu_iorq_n => N_IORQ,
		cpu_addr => port1_a,
		cpu_wr_en => cpu_wr_en,
		cpu_din => D,
		cpu_dout => sram_dout,
		b_req => b_req_r,
		b_we => b_we_r,
		b_addr => b_addr_r,
		b_din => b_din_r,
		b_dout => open,           -- port B reads return only to the GS port (stage 3)
		b_done => b_done,
		b_overrun => open,        -- nothing in synthesis; the sims watch it
		sd_ba => SDR_BA,
		sd_a => SDR_A,
		sd_dqm => SDR_DQM,
		sd_ras_n => SDR_RAS_N,
		sd_cas_n => SDR_CAS_N,
		sd_we_n => SDR_WE_N,
		sd_dq => SDR_DQ
	);

	-- the loader writes a byte of boot.rom into the SDRAM through port B.
	-- The CPU is in reset while loader_act = '1' (profi.vhd: reset <= ... or
	-- loader_act ...), so the controller serves every request in its free
	-- window right away: 8 clk_mem per byte against one byte every >= 128
	-- clk_sys (one ROMDATA SPI frame per byte, see rtl/host/mcu_emu.sv) -
	-- the one-entry buffer can never be given the next byte before the last
	-- was served, so b_overrun never rises. b_req is a level and the
	-- controller takes one access per rising edge: it drops when b_done
	-- toggled, so the next byte makes exactly one new rising edge. GS ROM
	-- bytes (loader_ram_a(31) = '1') are dropped as in stage 1 (the GS
	-- returns to the memory in stage 3).
	loader_b: process (CLK_BUS)
	begin
		if rising_edge(CLK_BUS) then
			b_done_s1 <= b_done;    -- the toggle synchroniser into clk_bus
			b_done_s2 <= b_done_s1;
			if ARESET = '1' then
				b_req_r <= '0';
				b_we_r  <= '0';
			else
				if b_done_s1 /= b_done_s2 then
					b_req_r <= '0';
				end if;
				if loader_act = '1' and loader_ram_wr = '1' and loader_ram_a(31) = '0' then
					-- pragma translate_off
					-- A byte arriving while the previous request is still
					-- pending (b_req_r high and no done toggle to clear it
					-- this clock) would overwrite b_addr_r/b_din_r without
					-- a new rising edge on b_req: the controller would serve
					-- the later byte and the earlier one would vanish. The
					-- SPI frame rate keeps this from happening today; this
					-- assertion is the report if it ever does.
					assert not (b_req_r = '1' and b_done_s1 = b_done_s2)
						report "memory: loader write while the previous one is pending"
						severity failure;
					-- pragma translate_on
					b_addr_r <= loader_ram_a(20 downto 0);
					b_din_r  <= loader_ram_do;
					b_we_r   <= '1';
					b_req_r  <= '1';
				end if;
			end if;
		end if;
	end process;

	-- shared port for profi cpu
	port1_a <= loader_ram_a(20 downto 0) when loader_act = '1' else -- loader ram
				  "1010000" & A(13 downto 0) when romm_a = '1' else -- DIVMMC rom
				  "11" & REG_E3(5 downto 0) & A(12 downto 0) when ramm_a = '1' else -- DIVMMC ram 512 kB from #X180000 SRAM
				  "100" & EXT_ROM_BANK(1 downto 0) & rom_page(1 downto 0) & A(13 downto 0) when rom_a = '1' else -- rom from sram high bank
				  '0' & ram_page(5 downto 0) & A(13 downto 0);  -- ram
	-- (stage 1's port1_rd/port1_wr/port1_di drivers of the sram_bridge are
	-- gone: the controller reads the CPU strobes itself, its write mask is
	-- the cpu_wr_en above, and the loader arrives through port B)

	-- shared port for GS cpu
	port2_a <= loader_ram_a(20 downto 0) when loader_act = '1' else 
				  GS_A;
	port2_rd <= '0' when loader_act = '1' else 
					'1' when GS_N_RD = '0' else 
					'0';
	port2_wr <= loader_ram_wr when loader_act = '1' and loader_ram_a(31) = '1' else 
					'0' when loader_act = '1' and loader_ram_a(31) = '0' else
					'1' when GS_N_WR = '0' else
					'0';
	port2_rfsh <= '0' when loader_act = '1' else 
						not GS_N_RFSH ;
	port2_di <= loader_ram_do when loader_act = '1' else 
					GS_D(7 downto 0);

	is_romDIVMMC <= '1' when DIVMMC_EN = '1' and N_MREQ = '0' and (AUTOMAP ='1' or REG_E3(7) = '1') and A(15 downto 13) = "000" else '0';
	is_ramDIVMMC <= '1' when DIVMMC_EN = '1' and N_MREQ = '0' and (AUTOMAP ='1' or REG_E3(7) = '1') and A(15 downto 13) = "001" else '0';
	
	is_rom <= '1' when N_MREQ = '0' and A(15 downto 14)  = "00"  and (WOROM = '0' or DIVMMC_EN = '1') else '0';
	is_ram <= '1' when N_MREQ = '0' and is_rom = '0' else '0';	

	rom_a   <= '1' when A(15 downto 14) = "00" and (WOROM = '0' or DIVMMC_EN = '1') else '0';
	romm_a  <= '1' when DIVMMC_EN = '1' and (AUTOMAP = '1' or REG_E3(7) = '1') and A(15 downto 13) = "000" else '0';
	ramm_a  <= '1' when DIVMMC_EN = '1' and (AUTOMAP = '1' or REG_E3(7) = '1') and A(15 downto 13) = "001" else '0';
	
	-- 00 - bank 0, CPM
	-- 01 - bank 1, TRDOS
	-- 10 - bank 2, Basic-128
	-- 11 - bank 3, Basic-48

	rom_page <= (not(TRDOS)) & ROM_BANK when DIVMMC_EN = '0' else "11";
			
	N_OE <= '0' when (is_ram = '1' or is_rom = '1') and N_RD = '0' else '1';
		
	mux <= A(15 downto 14);
		
	process (mux, RAM_EXT, RAM_BANK, SCR, SCO)
	begin
		case mux is
			when "00" => ram_page <= "000000";                 -- Seg0 ROM 0000-3FFF or Seg0 RAM 0000-3FFF				
			when "01" => if SCO='0' then 
								ram_page <= "000101";
							 else 
								ram_page <= RAM_EXT(2 downto 0) & RAM_BANK(2 downto 0); 
							 end if;	                               -- Seg1 RAM 4000-7FFF	
			when "10" => if SCR='0' then 
								ram_page <= "000010"; 	
							 else 
								ram_page <= "000110"; 
							 end if;                                -- Seg2 RAM 8000-BFFF
			when "11" => if SCO='0' then 
								ram_page <= RAM_EXT(2 downto 0) & RAM_BANK(2 downto 0);	
							 else 
								ram_page <= "000111";               -- Seg3 RAM C000-FFFF	
							 end if;
			when others => null;
		end case;
	end process;
	
	process( CLK_BUS )
	begin
		if rising_edge(CLK_BUS) then
			if N_MREQ = '0' or (A(0) = '0' and N_IORQ = '0')then
				block_reg <='0';
			else
				block_reg <= '1';
			end if;
		end if;
	end process;
	
	page_cont <= '1' when (A(0) = '0' and N_IORQ = '0') or mux="01" else '0';
	
	process (CLK_BUS)
	begin 
		if rising_edge(CLK_BUS) then 
		-- OCH: contend only when 3,5 MHz CLK 
			if (page_cont = '1' and block_reg = '1' and count_block = '1' and DS80 = '0' and TURBO_MODE = "00") then 
				contended <= '1';
			else 
				contended <= '0';
			end if;
		end if;
	end process;
			
end RTL;

