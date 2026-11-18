-- tb_serial_mouse: the Profi's serial mouse (upstream serial_mouse.vhd, the
-- 8251-style chip at #D3 data / #F3 status+control that the CP/M mouse driver
-- reads) as the CPU sees it, with the core's select rewrite applied (the file
-- under test is the prepare_upstream.py SERIAL_MOUSE_REWRITES output; the
-- runner also runs the unmodified upstream file and requires it to FAIL, which
-- is the board finding of 2026-11-18: with the upstream select the chip is
-- deselected exactly when its output enable would let it onto the bus).
--
-- Cases (each prints `PASS <case>` or `FAIL <case> <reason>`):
--   cpm_ds80      CP/M mode (cpm=1, rom14=1), ds80=1: after the command write
--                 (RxE) and a mouse report the status port shows RxRDY with
--                 OE_N low, and the data port yields the three Microsoft-mouse
--                 bytes of the report (X=5, Y=3, left button): 60 05 03 hex;
--   gs_ds80_0     ds80=0 (General Sound is mapped): the chip never drives
--                 (OE_N high) on either port;
--   no_cpm        cpm=0, dos=0: the chip never drives with ds80=1 either.
-- The last line printed is `tb_serial_mouse: PASS` or `tb_serial_mouse: FAIL ...`.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_serial_mouse is end;

architecture t of tb_serial_mouse is
  constant T : time := 35.5556 ns;               -- clk_bus, 28.125 MHz
  signal clk : std_logic := '0';
  signal a : std_logic_vector(15 downto 0) := x"00D3";
  signal di, do_s : std_logic_vector(7 downto 0) := x"00";
  signal wr_n, rd_n, iorq_n : std_logic := '1';
  signal ds80, cpm, rom14 : std_logic := '0';
  signal ev : std_logic := '0';
  signal int_n, oe_n : std_logic;
  signal errors : integer := 0;
begin
  clk <= not clk after T / 2;

  dut : entity work.serial_mouse port map(
    CLK => clk, CLKEN => '1', N_RESET => '1', A => a, DI => di, WR_N => wr_n,
    RD_N => rd_n, IORQ_N => iorq_n, M1_N => '1', DS80 => ds80, CPM => cpm,
    DOS => '0', ROM14 => rom14, MS_X => x"05", MS_Y => x"03", MS_BTNS => "001",
    MS_PRESET => '1', MS_EVENT => ev, DO => do_s, INT_N => int_n, OE_N => oe_n);

  process
    variable got : std_logic_vector(7 downto 0);
    variable oe  : std_logic;
    variable n   : integer;
    variable seen_oe : boolean;

    procedure fail(msg : string) is
    begin
      report "FAIL " & msg severity note;
      errors <= errors + 1;
      wait for 0 ns;
    end procedure;

    procedure io_wr(addr : std_logic_vector(15 downto 0); d : std_logic_vector(7 downto 0)) is
    begin
      a <= addr; di <= d; iorq_n <= '0'; wr_n <= '0'; wait for 4 * T;
      wr_n <= '1'; iorq_n <= '1'; wait for 4 * T;
    end procedure;

    procedure io_rd(addr : std_logic_vector(15 downto 0);
                    variable d : out std_logic_vector(7 downto 0);
                    variable o : out std_logic) is
    begin
      a <= addr; iorq_n <= '0'; rd_n <= '0'; wait for 3 * T;
      d := do_s; o := oe_n;
      rd_n <= '1'; iorq_n <= '1'; wait for 3 * T;
    end procedure;

    type byte3 is array (0 to 2) of std_logic_vector(7 downto 0);
    variable pkt : byte3;
    variable cnt : integer;
    variable ok  : boolean;
  begin
    report "tb_serial_mouse: start";

    -- ---- cpm_ds80 ----
    cpm <= '1'; rom14 <= '1'; ds80 <= '1'; wait for 1 us;
    io_wr(x"00F3", x"04");                         -- RxE
    ev <= not ev; wait for 2 us;                   -- a mouse report
    cnt := 0; n := 0; ok := true;
    while cnt < 3 and n < 400 loop
      io_rd(x"00F3", got, oe);                     -- status
      if oe = '0' and got(1) = '1' then            -- RxRDY
        io_rd(x"00D3", got, oe);                   -- data
        if oe /= '0' then ok := false; end if;
        pkt(cnt) := got; cnt := cnt + 1;
      end if;
      n := n + 1;
    end loop;
    if cnt /= 3 then
      fail("cpm_ds80: no RxRDY with the output enabled, got " & integer'image(cnt) & " of 3 bytes");
    else
      if not ok then fail("cpm_ds80: data read without OE_N low"); end if;
      if pkt(0) /= x"60" then fail("cpm_ds80: byte 0 is not 60"); end if;
      if pkt(1) /= x"05" then fail("cpm_ds80: byte 1 is not 05"); end if;
      if pkt(2) /= x"03" then fail("cpm_ds80: byte 2 is not 03"); end if;
    end if;
    report "case cpm_ds80 done";

    -- ---- gs_ds80_0 ----
    ds80 <= '0'; wait for 1 us;
    seen_oe := false;
    for i in 0 to 5 loop
      io_rd(x"00F3", got, oe); if oe = '0' then seen_oe := true; end if;
      io_rd(x"00D3", got, oe); if oe = '0' then seen_oe := true; end if;
    end loop;
    if seen_oe then fail("gs_ds80_0: the chip drove the bus with ds80=0"); end if;
    report "case gs_ds80_0 done";

    -- ---- no_cpm ----
    cpm <= '0'; ds80 <= '1'; wait for 1 us;
    seen_oe := false;
    for i in 0 to 5 loop
      io_rd(x"00F3", got, oe); if oe = '0' then seen_oe := true; end if;
      io_rd(x"00D3", got, oe); if oe = '0' then seen_oe := true; end if;
    end loop;
    if seen_oe then fail("no_cpm: the chip drove the bus outside CP/M"); end if;
    report "case no_cpm done";

    if errors = 0 then report "tb_serial_mouse: PASS";
    else report "tb_serial_mouse: FAIL " & integer'image(errors) & " checks failed"; end if;
    wait;
  end process;
end;
