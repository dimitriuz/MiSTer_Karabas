library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity probe_int is end;
architecture t of probe_int is
  signal clk : std_logic := '0';
  signal cen : std_logic := '0';
  signal rst_n : std_logic := '0';
  signal int_n, m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n : std_logic;
  signal a : std_logic_vector(15 downto 0);
  signal di, do_c, mdo : std_logic_vector(7 downto 0);
  signal ms_oe_n, ms_int_n : std_logic;
  signal ev : std_logic := '0';
  signal msx : std_logic_vector(7 downto 0) := x"05";
  type ram_t is array (0 to 65535) of std_logic_vector(7 downto 0);
  function init return ram_t is
    variable r : ram_t := (others => x"00");
  begin
    r(0):=x"F3"; r(1):=x"31"; r(2):=x"00"; r(3):=x"F0"; r(4):=x"C3"; r(5):=x"00"; r(6):=x"01";
    r(32):=x"F5"; r(33):=x"DB"; r(34):=x"D3"; r(35):=x"3A"; r(36):=x"00"; r(37):=x"80";
    r(38):=x"3C"; r(39):=x"32"; r(40):=x"00"; r(41):=x"80"; r(42):=x"F1"; r(43):=x"FB";
    r(44):=x"ED"; r(45):=x"4D";
    r(256):=x"3E"; r(257):=x"90"; r(258):=x"ED"; r(259):=x"47"; r(260):=x"ED"; r(261):=x"5E";
    r(262):=x"3E"; r(263):=x"04"; r(264):=x"D3"; r(265):=x"F3"; r(266):=x"3E"; r(267):=x"01"; r(268):=x"D3"; r(269):=x"B3";
    r(270):=x"FB"; r(271):=x"18"; r(272):=x"FE";
    r(16#90E7#):=x"20"; r(16#90E8#):=x"00";
    return r;
  end function;
  signal ram : ram_t := init;
  signal cnt : integer range 0 to 7 := 0;
  signal isr_count : integer := 0;
  signal rd_data_count : integer := 0;
begin
  clk <= not clk after 17.7778 ns;
  process(clk) begin if rising_edge(clk) then cnt <= (cnt + 1) mod 8; end if; end process;
  cen <= '1' when cnt = 0 else '0';
  rst_n <= '0', '1' after 1 us;
  cpu : entity work.T80s port map(RESET_n => rst_n, CLK => clk, CEN => cen, WAIT_n => '1',
     INT_n => ms_int_n, NMI_n => '1', BUSRQ_n => '1', M1_n => m1_n, MREQ_n => mreq_n,
     IORQ_n => iorq_n, RD_n => rd_n, WR_n => wr_n, RFSH_n => rfsh_n, HALT_n => open,
     BUSAK_n => open, OUT0 => '1', A => a, DI => di, DO => do_c);
  ms : entity work.serial_mouse port map(CLK => clk, CLKEN => cen, N_RESET => rst_n, A => a,
     DI => do_c, WR_N => wr_n, RD_N => rd_n, IORQ_N => iorq_n, M1_N => m1_n, DS80 => '1',
     CPM => '1', DOS => '0', ROM14 => '1', MS_X => msx, MS_Y => x"03", MS_BTNS => "001",
     MS_PRESET => '1', MS_EVENT => ev, DO => mdo, INT_N => ms_int_n, OE_N => ms_oe_n);
  -- bus mux as the top: the mouse where it drives, RAM on memory reads, else FF
  di <= ram(to_integer(unsigned(a))) when (mreq_n = '0' and rd_n = '0') else
        mdo when ms_oe_n = '0' else x"FF";
  process(clk) begin
    if rising_edge(clk) then
      if mreq_n = '0' and wr_n = '0' then ram(to_integer(unsigned(a))) <= do_c; end if;
    end if;
  end process;
  process(clk) begin
    if rising_edge(clk) and cen = '1' then
      if iorq_n = '0' and wr_n = '0' then report "OUT addr=" & integer'image(to_integer(unsigned(a(7 downto 0)))) & " d=" & integer'image(to_integer(unsigned(do_c))); end if;
      if iorq_n = '0' and m1_n = '0' then report "INTA"; end if;
    end if;
  end process;
  -- the program is the RAM's initial value (one driver)
  process
  begin
    for k in 1 to 6 loop
      wait for 60 us; msx <= std_logic_vector(unsigned(msx)+1); ev <= not ev;
      wait for 60 us;
      report "event " & integer'image(k) & ": isr count=" & integer'image(to_integer(unsigned(ram(32768)))) & " int_n=" & std_logic'image(ms_int_n);
    end loop;
    wait;
  end process;
end;
