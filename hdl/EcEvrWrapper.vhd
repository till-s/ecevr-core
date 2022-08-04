
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.IlaWrappersPkg.all;

use work.Lan9254Pkg.all;
use work.Lan9254ESCPkg.all;
use work.MicroUDPPkg.all;
use work.Udp2BusPkg.all;
use work.EvrTxPDOPkg.all;
use work.Evr320ConfigPkg.all;
use work.EEPROMConfigPkg.all;
use work.EcEvrBspPkg.all;

library unisim;
use unisim.vcomponents.all;

entity EcEvrWrapper is
  generic (
    CLK_FREQ_G        : real;
    BUILD_INFO_G      : std_logic_vector(31 downto 0);
    GEN_HBI_ILA_G     : boolean := true;
    GEN_ESC_ILA_G     : boolean := true;
    GEN_EOE_ILA_G     : boolean := true;
    GEN_U2B_ILA_G     : boolean := true;
    GEN_CNF_ILA_G     : boolean := true;
    GEN_I2C_ILA_G     : boolean := true;
    GEN_EEP_ILA_G     : boolean := true;
    NUM_BUS_SUBS_G    : natural := 0
  );
  port (
    sysClk            : in     std_logic;
    sysRst            : in     std_logic;

    escRst            : in     std_logic := '0';
    eepRst            : in     std_logic := '0';
    hbiRst            : in     std_logic := '0';

    lan9254_hbiOb     : out    Lan9254HBIOutType;
    lan9254_hbiIb     : in     Lan9254HBIInpType := LAN9254HBIINP_INIT_C;

    extHbiSel         : in     std_logic         := '0';
    extHbiReq         : in     Lan9254ReqType    := LAN9254REQ_INIT_C;
    extHbiRep         : out    Lan9254RepType;

    rxPDOMst          : out    Lan9254PDOMstType;
    rxPDORdy          : in     std_logic := '1';

    busReqs           : out    Udp2BusReqArray(NUM_BUS_SUBS_G - 1 downto 0);
    busReps           : in     Udp2BusRepArray(NUM_BUS_SUBS_G - 1 downto 0) := (others => UDP2BUSREP_ERROR_C);

    i2c_scl_o         : out    std_logic_vector(NUM_I2C_C  - 1 downto 0);
    i2c_scl_t         : out    std_logic_vector(NUM_I2C_C  - 1 downto 0);
    i2c_scl_i         : in     std_logic_vector(NUM_I2C_C  - 1 downto 0);
    i2c_sda_o         : out    std_logic_vector(NUM_I2C_C  - 1 downto 0);
    i2c_sda_t         : out    std_logic_vector(NUM_I2C_C  - 1 downto 0);
    i2c_sda_i         : in     std_logic_vector(NUM_I2C_C  - 1 downto 0);

    ec_latch_o        : out    std_logic_vector(EC_NUM_LATCH_INP_C - 1 downto 0);
    ec_sync_i         : in     std_logic_vector(EC_NUM_SYNC_OUT_C  - 1 downto 0) := (others => '0');

    lan9254_irq       : in     std_logic := '0';

    testFailed        : out    std_logic_vector( 4 downto 0);
    escStats          : out    StatCounterArray(21 downto 0);
    escState          : out    ESCStateType;
    escDebug          : out    std_logic_vector(23 downto 0);
    eepEmulActive     : out    std_logic;

    timingMGTStatus   : in     std_logic_vector(31 downto 0) := (others => '0');

    timingRecClk      : in     std_logic;
    timingRecRst      : in     std_logic;

    timingRxData      : in     std_logic_vector(15 downto 0);
    timingDataK       : in     std_logic_vector( 1 downto 0);
    evrEventsAdj      : out    std_logic_vector( 3 downto 0)
  );
end entity EcEvrWrapper;

architecture Impl of EcEvrWrapper is

  constant NUM_BUS_MSTS_C           : natural := 1;
  constant BUS_MIDX_PDO_C           : natural := 0;

  constant EVR_BASE_ADDR_C          : unsigned(31 downto 0) := x"0000_0000";

  constant NUM_LOC_SUBS_C           : natural := 3;
  constant NUM_BUS_SUBS_C           : natural := NUM_LOC_SUBS_C + NUM_BUS_SUBS_G;
  constant BUS_SIDX_EVR_C           : natural := 0;
  constant BUS_SIDX_LOC_C           : natural := 1;
  constant BUS_SIDX_I2C_C           : natural := 2;

  constant NUM_HBI_MSTS_C           : natural := 1;
  constant PRI_HBI_MSTS_C           : integer := -1;
  constant HBI_MIDX_PDO_C           : integer := PRI_HBI_MSTS_C;
  constant HBI_MSTS_LDX_C           : integer := PRI_HBI_MSTS_C;
  constant HBI_MSTS_RDX_C           : integer := HBI_MSTS_LDX_C + NUM_HBI_MSTS_C - 1;

  constant MAX_TXPDO_SEGMENTS_C     : natural := 16;

  constant NUM_I2C_MST_C            : natural :=  2;
  constant I2C_MST_CFG_C            : natural :=  0;
  constant I2C_MST_BUS_C            : natural :=  1;

  signal configReq      : EEPROMConfigReqType;
  signal configAck      : EEPROMConfigAckType := EEPROM_CONFIG_ACK_ASSERT_C;
  signal eepWriteReq    : EEPROMWriteWordReqType;
  signal eepWriteAck    : EEPROMWriteWordAckType;
  signal dbufSegments   : MemXferArray(MAX_TXPDO_SEGMENTS_C - 1 downto 0);
  signal configRetries  : unsigned(3 downto 0);
  signal configRstR     : std_logic := '0';
  signal configRstRIn   : std_logic;
  signal configRst      : std_logic;
  signal configDebug    : std_logic_vector(31 downto 0);
  signal configInit     : std_logic;


  signal escHbiReq      : Lan9254ReqType := LAN9254REQ_INIT_C;
  signal escHbiRep      : Lan9254RepType := LAN9254REP_INIT_C;

  signal hbiReq         : Lan9254ReqType;
  signal hbiRep         : Lan9254RepType;


  signal busSubReq      : Udp2BusReqArray(NUM_BUS_SUBS_C - 1 downto 0) := (others => UDP2BUSREQ_INIT_C);
  signal busSubRep      : Udp2BusRepArray(NUM_BUS_SUBS_C - 1 downto 0) := (others => UDP2BUSREP_INIT_C);

  signal busMstReq      : Udp2BusReqArray(NUM_BUS_MSTS_C - 1 downto 0) := (others => UDP2BUSREQ_INIT_C);
  signal busMstRep      : Udp2BusRepArray(NUM_BUS_MSTS_C - 1 downto 0) := (others => UDP2BUSREP_INIT_C);

  signal hbiMstReq      : Lan9254ReqArray(HBI_MSTS_LDX_C downto HBI_MSTS_RDX_C) := (others => LAN9254REQ_INIT_C);
  signal hbiMstRep      : Lan9254RepArray(HBI_MSTS_LDX_C downto HBI_MSTS_RDX_C) := (others => LAN9254REP_INIT_C);


  signal usr_evts_adj   : std_logic_vector(3 downto 0);
  signal latchedEvents  : std_logic_vector(1 downto 0);
  signal extra_events   : std_logic_vector(NUM_EXTRA_EVENTS_C - 1 downto 0);
  signal evrTimestampHi : std_logic_vector(31 downto 0) := (others => '0');
  signal evrTimestampLo : std_logic_vector(31 downto 0) := (others => '0');

  signal eventCode      : std_logic_vector( 7 downto 0) := (others => '0');
  signal eventCodeVld   : std_logic                     := '0';

  signal txPdoTrgCount  : unsigned(15 downto 0);

  signal eepEmulActLoc  : std_logic;

  signal i2cStrmLock    : std_logic_vector(NUM_I2C_MST_C - 1 downto 0);

  signal i2cStrmReqMst, i2cStrmRepMst : Lan9254StrmMstArray(NUM_I2C_MST_C - 1 downto 0);
  signal i2cStrmReqRdy, i2cStrmRepRdy : std_logic_vector   (NUM_I2C_MST_C - 1 downto 0);

  signal sda_o_loc, scl_o_loc, sda_t_loc, scl_t_loc : std_logic_vector(NUM_I2C_C - 1 downto 0);

begin

  busSubRep(NUM_BUS_SUBS_C - 1 downto NUM_LOC_SUBS_C) <= busReps;
  busReqs                                             <= busSubReq(NUM_BUS_SUBS_C - 1 downto NUM_LOC_SUBS_C);

  P_HBI_MUX : process (
    extHbiSel, extHbiReq, escHbiReq, hbiRep
  ) is begin
    if ( extHbiSel = '1' ) then
      hbiReq        <= extHbiReq;
      extHbiRep     <= hbiRep;
      escHbiRep     <= LAN9254REP_INIT_C;
    else
      hbiReq        <= escHbiReq;
      extHbiRep     <= LAN9254REP_DFLT_C;
      escHbiRep     <= hbiRep;
    end if;
  end process P_HBI_MUX;


  U_HBI : entity work.Lan9254HBI
    generic map (
      CLOCK_FREQ_G => CLK_FREQ_G,
      GEN_ILA_G    => GEN_HBI_ILA_G
    )
    port map (
      clk          => sysClk,
      rst          => hbiRst,

      req          => hbiReq,
      rep          => hbiRep,

      hbiOut       => lan9254_hbiOb,
      hbiInp       => lan9254_hbiIb
    );

  U_ESC : entity work.Lan9254ESCWrapper
    generic map (
      CLOCK_FREQ_G          => CLK_FREQ_G,
      NUM_BUS_SUBS_G        => NUM_BUS_SUBS_C,
      NUM_BUS_MSTS_G        => NUM_BUS_MSTS_C,
      NUM_EXT_HBI_MASTERS_G => NUM_HBI_MSTS_C,
      EXT_HBI_MASTERS_PRI_G => PRI_HBI_MSTS_C,
      -- our EvrTxPDO talks to the HBI directly
      DISABLE_TXPDO_G       => true,
      GEN_ESC_ILA_G         => GEN_ESC_ILA_G,
      GEN_EOE_ILA_G         => GEN_EOE_ILA_G,
      GEN_U2B_ILA_G         => GEN_U2B_ILA_G
    )
    port map (
      clk             => sysClk,
      rst             => escRst,

      configRstReq    => configInit,

      escState        => escState,
      debug           => escDebug,

      req             => escHbiReq,
      rep             => escHbiRep,

      myAddr          => configReq.net,
      myAddrAck       => configAck.net,

      eepWriteReq     => eepWriteReq,
      eepWriteAck     => eepWriteAck,
      eepEmulActive   => eepEmulActLoc,

      escConfigReq    => configReq.esc,
      escConfigAck    => configAck.esc,

      extHBIReq       => hbiMstReq,
      extHBIRep       => hbiMstRep,

      busMstReq       => busMstReq,
      busMstRep       => busMstRep,

      busSubReq       => busSubReq,
      busSubRep       => busSubRep,

      txPDOMst        => open,
      txPDORdy        => open,

      rxPDOMst        => rxPDOMst,
      rxPDORdy        => rxPDORdy,

      irq             => lan9254_irq,

      testFailed      => testFailed,
      stats           => escStats
    );

  U_EVR : entity work.evr320_udp2bus_wrapper
    generic map (
      g_BUS_CLOCK_FREQ  => natural( CLK_FREQ_G ),
      g_N_EVT_DBL_BUFS  => 0,
      g_DATA_STREAM_EN  => 1,
      g_EXTRA_RAW_EVTS  => NUM_EXTRA_EVENTS_C
    )
    port map (
      bus_CLK           => sysClk,
      bus_RESET         => sysRst,

      bus_Req           => busSubReq(BUS_SIDX_EVR_C),
      bus_Rep           => busSubRep(BUS_SIDX_EVR_C),

      evr_CfgReq        => configReq.evr320,
      evr_CfgAck        => configAck.evr320,

      clk_evr           => timingRecClk,
      rst_evr           => timingRecRst,

      usr_events_adj_o  => usr_evts_adj,
      extra_events_o    => extra_events,

      event_o           => eventCode,
      event_vld_o       => eventCodeVld,
      timestamp_hi_o    => evrTimestampHi,
      timestamp_lo_o    => evrTimestampLo,

      evr_rx_data       => timingRxData,
      evr_rx_charisk    => timingDataK,
      mgt_status_i      => timingMGTStatus
    );

  P_LATCH : process ( timingRecClk ) is
  begin
    if ( rising_edge( timingRecClk ) ) then
      if ( timingRecRst = '1' ) then
        latchedEvents <= (others => '0');
      else
        if ( extra_events(0) = '1' ) then
          latchedEvents(0) <= '1';
        end if;
        if ( extra_events(1) = '1' ) then
          latchedEvents(0) <= '0';
        end if;
        if ( extra_events(2) = '1' ) then
          latchedEvents(1) <= '1';
        end if;
        if ( extra_events(3) = '1' ) then
          latchedEvents(1) <= '0';
        end if;
      end if;
    end if;
  end process P_LATCH;

  ec_latch_o(0) <= latchedEvents(0);
  ec_latch_o(1) <= latchedEvents(1);

  evrEventsAdj  <= usr_evts_adj;

  U_TXPDO : entity work.EvrTxPDO
    generic map (
      NUM_EVENT_DWORDS_G => 8,
      EVENT_MAP_G        => EVENT_MAP_IDENT_C,
      MEM_BASE_ADDR_G    => EVR_BASE_ADDR_C,
      MAX_MEM_XFERS_G    => MAX_TXPDO_SEGMENTS_C,
      TXPDO_ADDR_G       => unsigned(ESC_SM3_SMA_C)
    )
    port map (
      evrClk             => timingRecClk,
      evrRst             => timingRecRst,

      pdoTrg             => usr_evts_adj(0),
      tsHi               => evrTimestampHi,
      tsLo               => evrTimestampLo,
      eventCode          => eventCode,
      eventCodeVld       => eventCodeVld,
      eventMapClr        => x"FF",

      busClk             => sysClk,
      busRst             => escRst,

      dbufMaps           => dbufSegments,
      config             => configReq.txPDO,

      lanReq             => hbiMstReq(HBI_MIDX_PDO_C),
      lanRep             => hbiMstRep(HBI_MIDX_PDO_C),

      busReq             => busMstReq(BUS_MIDX_PDO_C),
      busRep             => busMstRep(BUS_MIDX_PDO_C),

      trgCnt             => txPdoTrgCount
    );

  U_EEP_CFG : entity work.EEPROMConfigurator
    generic map (
      MAX_TXPDO_MAPS_G   => MAX_TXPDO_SEGMENTS_C,
      GEN_ILA_G          => GEN_CNF_ILA_G
    )
    port map (
      clk                => sysClk,
      rst                => configRst,

      configReq          => configReq,
      configAck          => configAck,
      eepWriteReq        => eepWriteReq,
      eepWriteAck        => eepWriteAck,
      dbufMaps           => dbufSegments,
      emulActive         => eepEmulActLoc,

      i2cAddr2BMode      => '0',

      i2cStrmRxMst       => i2cStrmRepMst(I2C_MST_CFG_C),
      i2cStrmRxRdy       => i2cStrmRepRdy(I2C_MST_CFG_C),
      i2cStrmTxMst       => i2cStrmReqMst(I2C_MST_CFG_C),
      i2cStrmTxRdy       => i2cStrmReqRdy(I2C_MST_CFG_C),
      i2cStrmLock        => i2cStrmLock  (I2C_MST_CFG_C),

      retries            => configRetries
    );

  U_BUS_I2C : entity work.Bus2I2cStreamIF
    port map (
      clk                => sysClk,
      rst                => sysRst,

      busReq             => busSubReq(BUS_SIDX_I2C_C),
      busRep             => busSubRep(BUS_SIDX_I2C_C),

      strmMstOb          => i2cStrmReqMst(I2C_MST_BUS_C),
      strmRdyOb          => i2cStrmReqRdy(I2C_MST_BUS_C),
      strmMstIb          => i2cStrmRepMst(I2C_MST_BUS_C),
      strmRdyIb          => i2cStrmRepRdy(I2C_MST_BUS_C),
      strmLock           => i2cStrmLock  (I2C_MST_BUS_C)
    );

  U_I2C_MST : entity work.I2cWrapper
    generic map (
      CLOCK_FREQ_G       => CLK_FREQ_G,
      NUM_I2C_MST_G      => NUM_I2C_MST_C,
      NUM_I2C_BUS_G      => NUM_I2C_C,
      GEN_I2CSTRM_ILA_G  => GEN_I2C_ILA_G
    )
    port map (
      clk                => sysClk,
      rst                => sysRst,

      i2cStrmMstIb       => i2cStrmReqMst,
      i2cStrmRdyIb       => i2cStrmReqRdy,
      i2cStrmMstOb       => i2cStrmRepMst,
      i2cStrmRdyOb       => i2cStrmRepRdy,

      i2cStrmLock        => i2cStrmLock,

      i2cSclInp          => i2c_scl_i,
      i2cSclOut          => scl_o_loc,
      i2cSclHiZ          => scl_t_loc,

      i2cSdaInp          => i2c_sda_i,
      i2cSdaOut          => sda_o_loc,
      i2cSdaHiZ          => sda_t_loc
    );
     

  G_EEP_ILA : if ( GEN_EEP_ILA_G ) generate
    signal clkdiv : unsigned(5 downto 0) := (others => '0');
    signal ilaClk : std_logic;
  begin

    P_DIV : process ( sysClk ) is
    begin
      if ( rising_edge( sysClk ) ) then
        clkdiv <= clkdiv + 1;
      end if;
    end process P_DIV;

    U_BUF : BUFG port map( I => std_logic(clkdiv(4)), O => ilaClk );

    U_ILA : Ila_256
      port map (
        clk         => ilaClk,
        probe0( 0)  => i2c_scl_i(EEP_I2C_IDX_C),
        probe0( 1)  => i2c_sda_i(EEP_I2C_IDX_C),
        probe0( 2)  => scl_o_loc(EEP_I2C_IDX_C),
        probe0( 3)  => sda_o_loc(EEP_I2C_IDX_C),
        probe0( 4)  => scl_t_loc(EEP_I2C_IDX_C),
        probe0( 5)  => sda_t_loc(EEP_I2C_IDX_C),
        probe0( 6)  => '0',
        probe0( 7)  => '0',
        probe0( 8)  => i2c_scl_i(PLL_I2C_IDX_C),
        probe0( 9)  => i2c_sda_i(PLL_I2C_IDX_C),
        probe0(10)  => scl_o_loc(PLL_I2C_IDX_C),
        probe0(11)  => sda_o_loc(PLL_I2C_IDX_C),
        probe0(12)  => scl_t_loc(PLL_I2C_IDX_C),
        probe0(13)  => sda_t_loc(PLL_I2C_IDX_C),
        probe0(63 downto 14) => (others => '0'),

        probe1      => (others => '0'),
        probe2      => (others => '0'),
        probe3      => (others => '0')
      );
  end generate G_EEP_ILA;

  configRst <= escRst or configRstR or eepRst or configInit;

  P_CFG_SEQ : process ( sysClk ) is
  begin
    if ( rising_edge( sysClk ) ) then
      if ( escRst = '1' ) then
        configRstR <= '0';
      else
        configRstR <= configRstRIn;
      end if;
    end if;
  end process P_CFG_SEQ;

  P_DIAG : process ( busSubReq(BUS_SIDX_LOC_C), dbufSegments, configReq,
                     configRetries, configRstR, configDebug, txPdoTrgCount ) is
    variable a : unsigned( 7 downto 0 );
    variable v : std_logic_vector(31 downto 0);
    variable q : Udp2BusReqType;
  begin
    q := busSubReq(BUS_SIDX_LOC_C);
    a := unsigned(q.dwaddr(7 downto 0));
    v := (others => '0');
    busSubRep(BUS_SIDX_LOC_C)       <= UDP2BUSREP_INIT_C;
    busSubRep(BUS_SIDX_LOC_C).valid <= '1';
    configRstRIn                    <= configRstR;
    case ( to_integer( a ) ) is
      when 0 => v(0) := configReq.net.macAddrVld;
                v(1) := configReq.net.ip4AddrVld;
                v(2) := configReq.net.udpPortVld;
                v(3) := configReq.esc.valid;
                v(15 downto 8) := std_logic_vector( to_unsigned( configReq.txPDO.numMaps, 8 ) );
                v(24) := configReq.txPDO.hasTs;
                v(25) := configReq.txPDO.hasEventCodes;
                v(26) := configReq.txPDO.hasLatch0P;
                v(27) := configReq.txPDO.hasLatch0N;
                v(28) := configReq.txPDO.hasLatch1P;
                v(29) := configReq.txPDO.hasLatch1N;
                v(31) := configRstR;
                if ( (not q.rdnwr and q.valid and q.be(3)) = '1' ) then
                   configRstRIn <= q.data(31);
                end if;

      when 1 => v    :=           configReq.net.macAddr(31 downto  0);
      when 2 => v    := x"0000" & std_logic_vector( txPdoTrgCount );
      when 3 => v    :=           configReq.net.ip4Addr;
      when 4 => v    := BUILD_INFO_G;
      when 5 => v    := configReq.esc.sm3Len & configReq.esc.sm2Len;
      when 6 => v(configRetries'range) := std_logic_vector(configRetries);
      when 7 => v    := configDebug;
      when 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 =>
                v    :=   std_logic_vector( to_unsigned( SwapType'pos(dbufSegments(to_integer(a) - 8).swp), 4 ) )
                        & "00" & std_logic_vector( dbufSegments(to_integer(a) - 8).num )
                        & std_logic_vector( dbufSegments(to_integer(a) - 8).off );
      when others =>
    end case;
    busSubRep(BUS_SIDX_LOC_C).rdata <= v;
  end process P_DIAG;

  i2c_scl_o     <= scl_o_loc;
  i2c_scl_t     <= scl_t_loc;
  i2c_sda_o     <= sda_o_loc;
  i2c_sda_t     <= sda_t_loc;

  eepEmulActive <= eepEmulActLoc;

end architecture Impl;