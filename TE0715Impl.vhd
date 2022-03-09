-------------------------------------------------------------------------------
-- File       : TE0715.vhd
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2015-04-08
-- Last update: 2017-02-16
-------------------------------------------------------------------------------
-- Description: Top Level Entity
-------------------------------------------------------------------------------
-- This file is part of 'Example Project Firmware'.
-- It is subject to the license terms in the LICENSE.txt file found in the
-- top-level directory of this distribution and at:
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
-- No part of 'Example Project Firmware', including this file,
-- may be copied, modified, propagated, or distributed except according to
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Structurally this project is a bit of a mess. This is due to the fact that
-- In SURF and Timing the MGTs are handled independently, i.e., ethernet and
-- timing 'embed' MGTs in their respective wrappers.
-- No problem because they can be clocked by individual 'channel PLLs'.
--
-- However, the Artix/GTP Transceiver lacks individual channel PLLs and therefore
-- must use/share the two available quad PLLs.
-- Unfortunately, both, the SURF/ethernet as well as the timing wrappers assume
-- they are the sole owners of a quad and instantiate the quad PLL which creates
-- a conflict.
--
-- When only a single quad is available then timing and ethernet have to share
-- the quad PLLs (each one can use one of the two available PLLs).
--
-- OTOH, we don't want to change the structure completely as it works fine for
-- other platforms (GTX). For this reason a modified version of the ethernet
-- wrapper was created (GigEthGtp7WrapperAdv) which adds ports and generics
-- that provide outside access to the quad pll.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;
use work.AxiLitePkg.all;
use work.AxiPkg.all;
use work.EthMacPkg.all;
use work.TimingPkg.all;
use work.TimingConnectorPkg.all;
use work.ZynqBspPkg.all;
use work.Ila_256Pkg.all;

use work.Lan9254Pkg.all;
use work.Lan9254ESCPkg.all;
use work.MicroUDPPkg.all;
use work.Udp2BusPkg.all;
use work.EvrTxPDOPkg.all;
use work.Evr320ConfigPkg.all;
use work.EEPROMConfigPkg.all;

library unisim;
use unisim.vcomponents.all;

architecture top_level of TE0715 is
   constant  ECEVR_C          : boolean := ( PRJ_VARIANT_G'length > 4 and PRJ_VARIANT_G(1 to 5) = "ecevr" );
   constant  IBERT_C          : boolean := ( PRJ_VARIANT_G = "ibert"  );
   constant  DEVBRD_C         : boolean := ( PRJ_VARIANT_G = "devbd" or ECEVR_C );
   constant  COPY_CLOCKS_C    : boolean := ( PRJ_VARIANT_G = "toggle" );
   constant  TBOX_C           : boolean := ( PRJ_VARIANT_G = "toggle" or PRJ_VARIANT_G = "tbox" );

   constant  TIMING_PLL_C     : natural range 0 to 1 := 1;
   constant  TIMING_PLL_SEL_C : slv(1 downto 0) := ite( TIMING_PLL_C = 0, "00", "11" );

   function  isArtix(part : string := PRJ_PART_G) return boolean is
      variable prefix: string(0 to 6);
   begin
      prefix := part(part'left to part'left + 6);
      return    prefix = "XC7Z012" or prefix = "XC7Z015"
             or prefix(prefix'left to prefix'left + 3) = "XC7A";
   end function isArtix;

   function numLed(var : string) return natural is
   begin
      if    ( TBOX_C ) then
         return 5;
      elsif ( ECEVR_C ) then
         return 11;
      else
         return 0;
      end if;
   end function numLed;

   constant  NUM_LED_C      : natural := numLed( PRJ_VARIANT_G );

   attribute IO_BUFFER_TYPE : string;
   attribute IOSTANDARD     : string;
   attribute SLEW           : string;
   attribute PULLUP         : string;
   attribute PULLDOWN       : string;

   -- pull-down the wait/ack into 'wait' state in case the EEPROM is not yet set up
   -- correctly for using the push-pull driver with WAIT_ACK enabled (see Lan9254Hbi.vhd;
   -- the datasheet incorrectly describes the lsbits in reg. 150).
   attribute PULLDOWN       of B34_L15_N : signal is ite((PRJ_VARIANT_G = "ecevr-hbi16m"), "TRUE", "FALSE");
   attribute IO_BUFFER_TYPE of mgtTxP    : signal is ite(IBERT_C, "OBUF", "NONE");
   attribute IO_BUFFER_TYPE of mgtTxN    : signal is ite(IBERT_C, "OBUF", "NONE");
   attribute IO_BUFFER_TYPE of mgtRxP    : signal is ite(IBERT_C, "IBUF", "NONE");
   attribute IO_BUFFER_TYPE of mgtRxN    : signal is ite(IBERT_C, "IBUF", "NONE");

   -- must match CONFIG.PCW_NUM_F2P_INTR_INPUTS {16} setting for IP generation
   constant NUM_IRQS_C  : natural          := 16;
   constant CLK_FREQ_C  : real             := 50.0E6;
   constant CLK_PER_C   : real             := 1.0/CLK_FREQ_C;

   constant FEEDTHRU_C  : natural          := ite( CLK_FEEDTHRU_G, 1, 0 );

   constant TIMING_UDP_PORT_C       : natural := ite( not TBOX_C, 0, 8197 );

   constant TIMING_GTP_HAS_COMMON_C : boolean := ((not isArtix) or (TIMING_UDP_PORT_C = 0));

   constant ETH_MAC_C   : slv(47 downto 0) := x"aa0300564400";  -- 00:44:56:00:03:01 (ETH only)

   constant NUM_AXI_SLV_C : natural        := 4;

   constant NUM_SPI_C     : positive       := 2;


   -- some differential outputs are swapped on PCB
   constant TIMING_TRIG_INVERT_C : slv(NUM_TRIGS_G - 1 downto 0) := "1100010";

   constant BLINK_TIME_C         : natural := natural( CLK_FREQ_C * 0.2 );
   constant BLINK_TIME_UNS_C     : unsigned(bitSize(BLINK_TIME_C) - 1 downto 0) := to_unsigned(BLINK_TIME_C, bitSize(BLINK_TIME_C));

   constant TIMING_SFP_MGT_C     : natural := ite( TIMING_ETH_MGT_G = 1, 2, 1 );

   signal   mgtRefClk   : slv(1 downto 0);
   signal   mgtRefClkBuf: slv(1 downto 0);

   signal   outClk      : sl;
   signal   outRst      : sl;

   signal   txDiv       : unsigned(27 downto 0) := to_unsigned(0, 28);
   signal   rxDiv       : unsigned(27 downto 0) := to_unsigned(0, 28);

   signal   rxLedData   : slv(1 downto 0);
   signal   rxLedTimer  : unsigned(BLINK_TIME_UNS_C'range) := to_unsigned(0, BLINK_TIME_UNS_C'length);
   signal   rxLedState  : sl := '0';
   signal   rxClkState  : sl := rxDiv(27);

   signal   dbgTrig     : slv(3 downto 0);

   signal   macAddr     : slv(47 downto 0);

   signal   timingSfpRxP: sl;
   signal   timingSfpRxN: sl;
   signal   timingSfpTxP: sl;
   signal   timingSfpTxN: sl;

   signal   timingEthRxP: sl;
   signal   timingEthRxN: sl;
   signal   timingEthTxP: sl;
   signal   timingEthTxN: sl;

   signal   ethTxMaster, ethRxMaster : AxiStreamMasterType;
   signal   ethTxSlave , ethRxSlave  : AxiStreamSlaveType;

   signal   timingIb    : TimingWireIbType := TIMING_WIRE_IB_INIT_C;
   signal   timingOb    : TimingWireObType := TIMING_WIRE_OB_INIT_C;
   signal   timingRx    : TimingRxType     := TIMING_RX_INIT_C;

   signal   sfp_tx_dis  : slv(NUM_SFPS_G - 1 downto 0) := (others => '0');
   signal   sfp_tx_flt  : slv(NUM_SFPS_G - 1 downto 0);
   signal   sfp_los     : slv(NUM_SFPS_G - 1 downto 0);
   signal   sfp_presentb: slv(NUM_SFPS_G - 1 downto 0);

   signal   psEthPhyLed0: sl;
   signal   si5344LOLb  : sl := '1';
   signal   si5344INTRb : sl := '1';

   signal   sysRstbOut_o: sl := '1';
   signal   sysRstbOut_t: sl := '1';
   signal   sysRstbOut_i: sl := '1';
   signal   sysRstbInp  : sl := '1';

   signal   spiOb       : ZynqSpiOutArray(NUM_SPI_C - 1 downto 0);
   signal   spiIb       : ZynqSpiArray   (NUM_SPI_C - 1 downto 0);

   signal   spiCtl_o    : Slv32Array(3 downto 0);
   signal   spiCtl_i    : Slv32Array(1 downto 0) := (others => (others => '0'));

   signal   led         : slv(NUM_LED_C - 1 downto 0)   := ( others => '0' );

   signal   diffOut     : slv(NUM_TRIGS_G - 1 downto 0) := ( others => '0' );

   COMPONENT ibert_7series_gt_0
      PORT (
         TXN_O : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
         TXP_O : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
         RXOUTCLK_O : OUT STD_LOGIC;
         RXN_I : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
         RXP_I : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
         GTREFCLK0_I : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
         GTREFCLK1_I : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
         SYSCLK_I : IN STD_LOGIC
      );
   END COMPONENT ibert_7series_gt_0;

   component processing_system7_0
      PORT (
         SPI0_SCLK_I : in STD_LOGIC;
         SPI0_SCLK_O : out STD_LOGIC;
         SPI0_SCLK_T : out STD_LOGIC;
         SPI0_MOSI_I : in STD_LOGIC;
         SPI0_MOSI_O : out STD_LOGIC;
         SPI0_MOSI_T : out STD_LOGIC;
         SPI0_MISO_I : in STD_LOGIC;
         SPI0_MISO_O : out STD_LOGIC;
         SPI0_MISO_T : out STD_LOGIC;
         SPI0_SS_I : in STD_LOGIC;
         SPI0_SS_O : out STD_LOGIC;
         SPI0_SS1_O : out STD_LOGIC;
         SPI0_SS2_O : out STD_LOGIC;
         SPI0_SS_T : out STD_LOGIC;
         USB0_PORT_INDCTL : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
         USB0_VBUS_PWRSELECT : OUT STD_LOGIC;
         USB0_VBUS_PWRFAULT : IN STD_LOGIC;
         M_AXI_GP0_ARVALID : OUT STD_LOGIC;
         M_AXI_GP0_AWVALID : OUT STD_LOGIC;
         M_AXI_GP0_BREADY : OUT STD_LOGIC;
         M_AXI_GP0_RREADY : OUT STD_LOGIC;
         M_AXI_GP0_WLAST : OUT STD_LOGIC;
         M_AXI_GP0_WVALID : OUT STD_LOGIC;
         M_AXI_GP0_ARID : OUT STD_LOGIC_VECTOR(11 DOWNTO 0);
         M_AXI_GP0_AWID : OUT STD_LOGIC_VECTOR(11 DOWNTO 0);
         M_AXI_GP0_WID : OUT STD_LOGIC_VECTOR(11 DOWNTO 0);
         M_AXI_GP0_ARBURST : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
         M_AXI_GP0_ARLOCK : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
         M_AXI_GP0_ARSIZE : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
         M_AXI_GP0_AWBURST : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
         M_AXI_GP0_AWLOCK : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
         M_AXI_GP0_AWSIZE : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
         M_AXI_GP0_ARPROT : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
         M_AXI_GP0_AWPROT : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
         M_AXI_GP0_ARADDR : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
         M_AXI_GP0_AWADDR : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
         M_AXI_GP0_WDATA : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
         M_AXI_GP0_ARCACHE : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
         M_AXI_GP0_ARLEN : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
         M_AXI_GP0_ARQOS : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
         M_AXI_GP0_AWCACHE : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
         M_AXI_GP0_AWLEN : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
         M_AXI_GP0_AWQOS : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
         M_AXI_GP0_WSTRB : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
         M_AXI_GP0_ACLK : IN STD_LOGIC;
         M_AXI_GP0_ARREADY : IN STD_LOGIC;
         M_AXI_GP0_AWREADY : IN STD_LOGIC;
         M_AXI_GP0_BVALID : IN STD_LOGIC;
         M_AXI_GP0_RLAST : IN STD_LOGIC;
         M_AXI_GP0_RVALID : IN STD_LOGIC;
         M_AXI_GP0_WREADY : IN STD_LOGIC;
         M_AXI_GP0_BID : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
         M_AXI_GP0_RID : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
         M_AXI_GP0_BRESP : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
         M_AXI_GP0_RRESP : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
         M_AXI_GP0_RDATA : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
         IRQ_F2P : IN STD_LOGIC_VECTOR(NUM_IRQS_C - 1 DOWNTO 0);
         FCLK_CLK0 : OUT STD_LOGIC;
         FCLK_RESET0_N : OUT STD_LOGIC;
         FCLK_RESET1_N : OUT STD_LOGIC;
         MIO : INOUT STD_LOGIC_VECTOR(53 DOWNTO 0);
         DDR_CAS_n : INOUT STD_LOGIC;
         DDR_CKE : INOUT STD_LOGIC;
         DDR_Clk_n : INOUT STD_LOGIC;
         DDR_Clk : INOUT STD_LOGIC;
         DDR_CS_n : INOUT STD_LOGIC;
         DDR_DRSTB : INOUT STD_LOGIC;
         DDR_ODT : INOUT STD_LOGIC;
         DDR_RAS_n : INOUT STD_LOGIC;
         DDR_WEB : INOUT STD_LOGIC;
         DDR_BankAddr : INOUT STD_LOGIC_VECTOR(2 DOWNTO 0);
         DDR_Addr : INOUT STD_LOGIC_VECTOR(14 DOWNTO 0);
         DDR_VRN : INOUT STD_LOGIC;
         DDR_VRP : INOUT STD_LOGIC;
         DDR_DM : INOUT STD_LOGIC_VECTOR(3 DOWNTO 0);
         DDR_DQ : INOUT STD_LOGIC_VECTOR(31 DOWNTO 0);
         DDR_DQS_n : INOUT STD_LOGIC_VECTOR(3 DOWNTO 0);
         DDR_DQS : INOUT STD_LOGIC_VECTOR(3 DOWNTO 0);
         PS_SRSTB : INOUT STD_LOGIC;
         PS_CLK : INOUT STD_LOGIC;
         PS_PORB : INOUT STD_LOGIC
      );
   END component processing_system7_0;

   constant AXIS_SIZE_C : positive         := 1;

   constant AXIS_WIDTH_C    : positive     := 4;

   signal   sysClk          : sl;
   signal   sysRst          : sl;
   signal   sysRstN         : sl;

   signal   appIrqs         : slv(7 downto 0);

   constant IRQ_MAX_C       : natural := ite( NUM_IRQS_C > 8, 8, NUM_IRQS_C );

   signal   cpuIrqs         : slv(NUM_IRQS_C - 1 downto 0) := (others => '0');

   signal   axilWriteMaster : AxiLiteWriteMasterType := AXI_LITE_WRITE_MASTER_INIT_C;
   signal   axilReadMaster  : AxiLiteReadMasterType  := AXI_LITE_READ_MASTER_INIT_C;
   signal   axilWriteSlave  : AxiLiteWriteSlaveType  := AXI_LITE_WRITE_SLAVE_INIT_C;
   signal   axilReadSlave   : AxiLiteReadSlaveType   := AXI_LITE_READ_SLAVE_INIT_C;

   signal   axiWriteMaster  : AxiWriteMasterType     := AXI_WRITE_MASTER_INIT_C;
   signal   axiReadMaster   : AxiReadMasterType      := AXI_READ_MASTER_INIT_C;
   signal   axiWriteSlave   : AxiWriteSlaveType      := AXI_WRITE_SLAVE_INIT_C;
   signal   axiReadSlave    : AxiReadSlaveType       := AXI_READ_SLAVE_INIT_C;

   signal   axilReadMasters : AxiLiteReadMasterArray (NUM_AXI_SLV_C - 1 downto 0) := (others => AXI_LITE_READ_MASTER_INIT_C);
   signal   axilWriteMasters: AxiLiteWriteMasterArray(NUM_AXI_SLV_C - 1 downto 0) := (others => AXI_LITE_WRITE_MASTER_INIT_C);
   signal   axilReadSlaves  : AxiLiteReadSlaveArray  (NUM_AXI_SLV_C - 1 downto 0) := (others => AXI_LITE_READ_SLAVE_INIT_C);
   signal   axilWriteSlaves : AxiLiteWriteSlaveArray (NUM_AXI_SLV_C - 1 downto 0) := (others => AXI_LITE_WRITE_SLAVE_INIT_C);

   signal   timingTrig      : TimingTrigType;
   signal   timingRecClk    : sl;
   signal   timingRecRst    : sl;
   signal   outClkLoc       : sl := '0';

   signal   timingRxStat    : TimingPhyStatusType;
   signal   timingTxStat    : TimingPhyStatusType;

   signal   timingTxClk     : sl;

   signal   trigReg         : slv(NUM_TRIGS_G - 1 downto 0) := TIMING_TRIG_INVERT_C;
   signal   recClk2         : slv(1 downto 0) := "00";

   signal   spi0_ss_d       : slv(SPI_MAX_SS_C - 1 downto 0)      := (others => '1');

   signal   spi_ss0_i       : slv(NUM_SPI_C - 1 downto 0) := (others => '1'); -- AR# 47511

   signal   pl_spi_irq      : sl;

   signal   ila1            : slv(63 downto 0) := (others => '0');

   signal   axilIlaSpare0   : slv(23 downto 0) := (others => '0');
   signal   axilIlaSpare1   : slv(23 downto 0) := (others => '0');
   signal   axilIlaSpare2   : slv(23 downto 0) := (others => '0');

   attribute IOB : string;
   attribute IOB of trigReg : signal is "TRUE";
   attribute IOB of recClk2 : signal is "TRUE";

   attribute FLOX           : real;
   attribute FLOX           of B34_L10_P     : signal is 1.2345;

begin

   assert    PRJ_VARIANT_G = "tbox"      or PRJ_VARIANT_G = "ibert"     or PRJ_VARIANT_G = "devbd" or PRJ_VARIANT_G = "toggle"
          or PRJ_VARIANT_G = "ecevr-spi" or PRJ_VARIANT_G = "ecevr-dio" or PRJ_VARIANT_G = "ecevr-hbi16m"
   severity failure;

   sysRst <= not sysRstN;

   U_Sys : component processing_system7_0
      port map (
         DDR_Addr(14 downto 0)         => DDR_addr(14 downto 0),
         DDR_BankAddr(2 downto 0)      => DDR_ba(2 downto 0),
         DDR_CAS_n                     => DDR_cas_n,
         DDR_CKE                       => DDR_cke,
         DDR_CS_n                      => DDR_cs_n,
         DDR_Clk                       => DDR_ck_p,
         DDR_Clk_n                     => DDR_ck_n,
         DDR_DM(3 downto 0)            => DDR_dm(3 downto 0),
         DDR_DQ(31 downto 0)           => DDR_dq(31 downto 0),
         DDR_DQS(3 downto 0)           => DDR_dqs_p(3 downto 0),
         DDR_DQS_n(3 downto 0)         => DDR_dqs_n(3 downto 0),
         DDR_DRSTB                     => DDR_reset_n,
         DDR_ODT                       => DDR_odt,
         DDR_RAS_n                     => DDR_ras_n,
         DDR_VRN                       => FIXED_IO_ddr_vrn,
         DDR_VRP                       => FIXED_IO_ddr_vrp,
         DDR_WEB                       => DDR_we_n,
         FCLK_CLK0                     => sysClk,
         FCLK_RESET0_N                 => sysRstN,
         FCLK_RESET1_N                 => open,
         IRQ_F2P                       => cpuIrqs,
         MIO(53 downto 0)              => FIXED_IO_mio,
         M_AXI_GP0_ACLK                => sysClk,
         M_AXI_GP0_ARADDR(31 downto 0) => axiReadMaster.araddr(31 downto 0),
         M_AXI_GP0_ARBURST(1 downto 0) => axiReadMaster.arburst,
         M_AXI_GP0_ARCACHE(3 downto 0) => axiReadMaster.arcache,
         M_AXI_GP0_ARID(11 downto 0)   => axiReadMaster.arid(11 downto 0),
         M_AXI_GP0_ARLEN(3 downto 0)   => axiReadMaster.arlen(3 downto 0),
         M_AXI_GP0_ARLOCK(1 downto 0)  => axiReadMaster.arlock,
         M_AXI_GP0_ARPROT(2 downto 0)  => axiReadMaster.arprot,
         M_AXI_GP0_ARQOS(3 downto 0)   => axiReadMaster.arqos,
         M_AXI_GP0_ARREADY             => axiReadSlave.arready,
         M_AXI_GP0_ARSIZE(2 downto 0)  => axiReadMaster.arsize,
         M_AXI_GP0_ARVALID             => axiReadMaster.arvalid,
         M_AXI_GP0_AWADDR(31 downto 0) => axiWriteMaster.awaddr(31 downto 0),
         M_AXI_GP0_AWBURST(1 downto 0) => axiWriteMaster.awburst,
         M_AXI_GP0_AWCACHE(3 downto 0) => axiWriteMaster.awcache,
         M_AXI_GP0_AWID(11 downto 0)   => axiWriteMaster.awid(11 downto 0),
         M_AXI_GP0_AWLEN(3 downto 0)   => axiWriteMaster.awlen(3 downto 0),
         M_AXI_GP0_AWLOCK(1 downto 0)  => axiWriteMaster.awlock,
         M_AXI_GP0_AWPROT(2 downto 0)  => axiWriteMaster.awprot,
         M_AXI_GP0_AWQOS(3 downto 0)   => axiWriteMaster.awqos,
         M_AXI_GP0_AWREADY             => axiWriteSlave.awready,
         M_AXI_GP0_AWSIZE(2 downto 0)  => axiWriteMaster.awsize,
         M_AXI_GP0_AWVALID             => axiWriteMaster.awvalid,
         M_AXI_GP0_BID(11 downto 0)    => axiWriteSlave.bid(11 downto 0),
         M_AXI_GP0_BREADY              => axiWriteMaster.bready,
         M_AXI_GP0_BRESP(1 downto 0)   => axiWriteSlave.bresp,
         M_AXI_GP0_BVALID              => axiWriteSlave.bvalid,
         M_AXI_GP0_RDATA(31 downto 0)  => axiReadSlave.rdata(31 downto 0),
         M_AXI_GP0_RID(11 downto 0)    => axiReadSlave.rid(11 downto 0),
         M_AXI_GP0_RLAST               => axiReadSlave.rlast,
         M_AXI_GP0_RREADY              => axiReadMaster.rready,
         M_AXI_GP0_RRESP(1 downto 0)   => axiReadSlave.rresp,
         M_AXI_GP0_RVALID              => axiReadSlave.rvalid,
         M_AXI_GP0_WDATA(31 downto 0)  => axiWriteMaster.wdata(31 downto 0),
         M_AXI_GP0_WID(11 downto 0)    => axiWriteMaster.wid(11 downto 0),
         M_AXI_GP0_WLAST               => axiWriteMaster.wlast,
         M_AXI_GP0_WREADY              => axiWriteSlave.wready,
         M_AXI_GP0_WSTRB(3 downto 0)   => axiWriteMaster.wstrb(3 downto 0),
         M_AXI_GP0_WVALID              => axiWriteMaster.wvalid,
         PS_CLK                        => FIXED_IO_ps_clk,
         PS_PORB                       => FIXED_IO_ps_porb,
         PS_SRSTB                      => FIXED_IO_ps_srstb,
         USB0_PORT_INDCTL              => open,
         USB0_VBUS_PWRFAULT            => '0',
         USB0_VBUS_PWRSELECT           => open,
         SPI0_SCLK_I                   => spiIb(1).sclk,
         SPI0_SCLK_O                   => spiOb(1).o.sclk,
         SPI0_SCLK_T                   => spiOb(1).t.sclk,
         SPI0_MOSI_I                   => spiIb(1).mosi,
         SPI0_MOSI_O                   => spiOb(1).o.mosi,
         SPI0_MOSI_T                   => spiOb(1).t.mosi,
         SPI0_MISO_I                   => spiIb(1).miso,
         SPI0_MISO_O                   => spiOb(1).o.miso,
         SPI0_MISO_T                   => spiOb(1).t.miso,
         SPI0_SS_I                     => spi_ss0_i(1),
         SPI0_SS_O                     => spiOb(1).o_ss(0),
         SPI0_SS1_O                    => spiOb(1).o_ss(1),
         SPI0_SS2_O                    => spiOb(1).o_ss(2),
         SPI0_SS_T                     => spiOb(1).t_ss0
      );

   U_PL_SPI  : entity work.AxilSpiMaster
      generic map (
         AXIL_CLK_PERIOD_G => CLK_PER_C,
         SPI_SCLK_PERIOD_G => 5.0E-8   -- 1 MHz
      )
      port map (
         --Global Signals
         axilClk         => sysClk,
         axilRst         => sysRst,
         -- Parallel interface
         axilReadMaster  => axilReadMasters(1),
         axilWriteMaster => axilWriteMasters(1),
         axilReadSlave   => axilReadSlaves(1),
         axilWriteSlave  => axilWriteSlaves(1),

         --SPI interface
         spiSs(0)        => spiOb(0).o_ss(1),
         spiSclk         => spiOb(0).o.sclk,
         spiMosi         => spiOb(0).o.mosi,
         spiMiso         => spiIb(0).miso,

         ctl_o           => spiCtl_o,
         ctl_i           => spiCtl_i,

         irq             => pl_spi_irq
      );

      spiOb(0).t.sclk <= '0';
      spiOb(0).t.mosi <= '0';
      spiOb(0).t.miso <= '1';
      spiOb(0).o.miso <= '0';

   GEN_SPI_ILA : if ( false ) generate
      U_SPI_ILA : Ila_256
         port map (
            clk => sysClk,
            probe0( 0) => spiIb(0).sclk,
            probe0( 1) => spiOb(0).o.sclk,
            probe0( 2) => spiOb(0).t.sclk,

            probe0( 3) => spiIb(0).mosi,
            probe0( 4) => spiOb(0).o.mosi,
            probe0( 5) => spiOb(0).t.mosi,

            probe0( 6) => spiIb(0).miso,
            probe0( 7) => spiOb(0).o.miso,
            probe0( 8) => spiOb(0).t.miso,

            probe0( 9) => spi0_ss_d(0),
            probe0(10) => spiOb(0).o_ss(0),
            probe0(11) => spiOb(0).t_ss0,

            probe0(12) => spi0_ss_d(1),
            probe0(13) => spiOb(0).o_ss(1),

            probe0(14) => spi0_ss_d(2),
            probe0(15) => spiOb(0).o_ss(2),

            probe0(63 downto 16) => (others => '0'),

            probe1     => ila1
         );
   end generate GEN_SPI_ILA;

   GEN_BUFDS : for i in 1 downto 0 generate
   begin
   U_IBUFDS : component IBUFDS_GTE2
      generic map (
         CLKRCV_TRST      => true, -- ug476
         CLKCM_CFG        => true, -- ug476
         CLKSWING_CFG     => "11"  -- ug476
      )
      port map (
         I                => mgtRefClkP(i),
         IB               => mgtRefClkN(i),
         CEB              => '0',
         O                => mgtRefClk(i),
         ODIV2            => open
      );

   U_MGT_BUFG : component BUFG
      port map (
         I   => mgtRefClk(i),
         O   => mgtRefClkBuf(i)
      );
   end generate;

   GEN_NOT_IBERT : if ( not IBERT_C ) generate

      U_OBUF_TIMING_SFP_P : component OBUF
         port map (
            I => timingSfpTxP,
            O => mgtTxP( TIMING_SFP_MGT_C )
         );
      U_OBUF_TIMING_SFP_N : component OBUF
         port map (
            I => timingSfpTxN,
            O => mgtTxN( TIMING_SFP_MGT_C )
         );
      U_IBUF_TIMING_SFP_P : component IBUF
         port map (
            I => mgtRxP( TIMING_SFP_MGT_C ),
            O => timingSfpRxP
         );
      U_IBUF_TIMING_SFP_N : component IBUF
         port map (
            I => mgtRxN( TIMING_SFP_MGT_C ),
            O => timingSfpRxN
         );

--   U_Ila_Axi : entity work.IlaAxi4SurfWrapper
--      port map (
--          axiClk                      => sysClk,
--          axiRst                      => sysRst,
--          axiReadMaster               => axiReadMaster,
--          axiReadSlave                => axiReadSlave,
--          axiWriteMaster              => axiWriteMaster,
--          axiWriteSlave               => axiWriteSlave
--      );

   GEN_AXI_ILA : if ( false  ) generate
   U_Ila_Axil : entity work.IlaAxiLite
      port map (
          axilClk                => sysClk,
          mAxilRead              => axilReadMaster,
          sAxilRead              => axilReadSlave,
          mAxilWrite             => axilWriteMaster,
          sAxilWrite             => axilWriteSlave,
          spare0                 => axilIlaSpare0,
          spare1                 => axilIlaSpare1,
          spare2                 => axilIlaSpare2
      );
   end generate GEN_AXI_ILA;

   U_A2A : entity work.AxiToAxiLite
      generic map (
         TPD_G            => TPD_G
      )
      port map (
         axiClk           => sysClk,
         axiClkRst        => sysRst,

         axiReadMaster    => axiReadMaster,
         axiReadSlave     => axiReadSlave,
         axiWriteMaster   => axiWriteMaster,
         axiWriteSlave    => axiWriteSlave,

         axilReadMaster   => axilReadMaster,
         axilReadSlave    => axilReadSlave,
         axilWriteMaster  => axilWriteMaster,
         axilWriteSlave   => axilWriteSlave
      );

   -------------------
   -- AXI-Lite Modules
   -------------------
   U_Reg : entity work.AppCore
      generic map (
         TPD_G                   => TPD_G,
         APP_TYPE_G              => ite( TIMING_UDP_PORT_C /= 0, "ETH", "NONE" ),
         AXIL_CLK_FREQUENCY_G    => CLK_FREQ_C,
         DHCP_G                  => true,
         JUMBO_G                 => false,
         USE_RSSI_G              => false,
         USE_JTAG_G              => false,
         USER_UDP_PORT_G         => TIMING_UDP_PORT_C,
         BUILD_INFO_G            => BUILD_INFO_G,
         XIL_DEVICE_G            => "7SERIES",
         AXIL_BASE_ADDR_G        => x"40000000",
         IP_ADDR_G               => x"410AA8C0",  -- 192.168.2.10 (ETH only)
         MAC_ADDR_G              => ETH_MAC_C,
         TPGMINI_G               => true,
         GEN_TIMING_G            => true,
         TIMING_UDP_MSG_G        => (TIMING_UDP_PORT_C /= 0),
         TIMING_GTP_HAS_COMMON_G => TIMING_GTP_HAS_COMMON_C,
         TIMING_TRIG_INVERT_G    => TIMING_TRIG_INVERT_C,
         NUM_AXIL_SLAVES_G       => NUM_AXI_SLV_C,
         NUM_TRIGS_G             => NUM_TRIGS_G
      )
      port map (
         -- Clock and Reset
         clk                  => sysClk,
         rst                  => sysRst,

         -- Ethernet Stream
         txMasters(0)         => ethTxMaster,
         txSlaves (0)         => ethTxSlave,
         rxMasters(0)         => ethRxMaster,
         rxSlaves (0)         => ethRxSlave,

         -- AXI-Lite interface
         sAxilWriteMaster     => axilWriteMaster,
         sAxilWriteSlave      => axilWriteSlave,
         sAxilReadMaster      => axilReadMaster,
         sAxilReadSlave       => axilReadSlave,

         mAxilReadMasters     => axilReadMasters,
         mAxilReadSlaves      => axilReadSlaves,
         mAxilWriteMasters    => axilWriteMasters,
         mAxilWriteSlaves     => axilWriteSlaves,

         -- Timing
         timingIb             => timingIb,
         timingOb             => timingOb,
         timingRx             => timingRx,

         -- ADC Ports
         vPIn                 => '0',
         vNIn                 => '0',
         irqOut               => appIrqs,

         -- Register values
         macAddrOut           => macAddr
      );

   GEN_TIMING_REFCLK_1 : if ( DEVBRD_C ) generate
      timingIb.refClk <= mgtRefClk( 1 );
   end generate GEN_TIMING_REFCLK_1;

   GEN_TIMING_REFCLK_0 : if ( not DEVBRD_C ) generate
      timingIb.refClk <= mgtRefClk( 0 );
   end generate GEN_TIMING_REFCLK_0;

   timingRecClk      <= timingOb.recClk;
   timingRecRst      <= timingOb.recRst;
   timingIb.RxP      <= timingSfpRxP;
   timingIb.RxN      <= timingSfpRxN;
   timingSfpTxP      <= timingOb.txP;
   timingSfpTxN      <= timingOb.txN;
   timingTrig        <= timingOb.trig;
   timingRxStat      <= timingOb.rxStat;
   timingTxStat      <= timingOb.txStat;
   timingTxClk       <= timingOb.txClk;

   GEN_TIMING_UDP : if ( TIMING_UDP_PORT_C /= 0 ) generate

      signal tiedToOne                : sl := '1';
      constant ETH_AXIS_CONFIG_C      : AxiStreamConfigArray(3 downto 0) := (others => EMAC_AXIS_CONFIG_C);

   begin

      U_OBUF_TIMING_ETH_P : component OBUF
         port map (
            I => timingEthTxP,
            O => mgtTxP( TIMING_ETH_MGT_G )
         );
      U_OBUF_TIMING_ETH_N : component OBUF
         port map (
            I => timingEthTxN,
            O => mgtTxN( TIMING_ETH_MGT_G )
         );
      U_IBUF_TIMING_ETH_P : component IBUF
         port map (
            I => mgtRxP( TIMING_ETH_MGT_G ),
            O => timingEthRxP
         );
      U_IBUF_TIMING_ETH_N : component IBUF
         port map (
            I => mgtRxN( TIMING_ETH_MGT_G ),
            O => timingEthRxN
         );

   GEN_GTX_ETH : if ( not isArtix ) generate

   U_PL_ETH_GTX : entity work.GigEthGtx7Wrapper
      generic map (
         TPD_G               => TPD_G,
         -- Clocking Configurations
         USE_GTREFCLK_G      => true, --  FALSE: gtClkP/N,  TRUE: gtRefClk
         -- AXI-Lite Configurations
         EN_AXI_REG_G        => true,
         -- AXI Streaming Configurations
         AXIS_CONFIG_G       => ETH_AXIS_CONFIG_C
      )
      port map (
         -- Local Configurations
         localMac(0)         => macAddr,
         -- Streaming DMA Interface
         dmaClk(0)           => sysClk,
         dmaRst(0)           => sysRst,
         dmaIbMasters(0)     => ethRxMaster,
         dmaIbSlaves (0)     => ethRxSlave,
         dmaObMasters(0)     => ethTxMaster,
         dmaObSlaves (0)     => ethTxSlave,
--         -- Slave AXI-Lite Interface
         axiLiteClk(0)       => sysClk,
         axiLiteRst(0)       => sysRst,
         axiLiteReadMasters(0)  => axilReadMasters(0),
         axiLiteReadSlaves(0)   => axilReadSlaves(0),
         axiLiteWriteMasters(0) => axilWriteMasters(0),
         axiLiteWriteSlaves(0)  => axilWriteSlaves(0),
         -- Misc. Signals
         extRst              => sysRst,
         phyClk              => open,
         phyRst              => open,
--         phyReady            : out slv(NUM_LANE_G-1 downto 0);
--         sigDet              : in  slv(NUM_LANE_G-1 downto 0)                     := (others => '1');
         -- MGT Clock Port (125.00 MHz or 250.0 MHz)
         gtRefClk            => mgtRefClkBuf(1),
--         gtClkP              : in  sl                                             := '1';
--         gtClkN              : in  sl                                             := '0';
         gtTxPolarity(0)     => tiedToOne,
         -- MGT Ports
         gtTxP(0)            => timingEthTxP,
         gtTxN(0)            => timingEthTxN,
         gtRxP(0)            => timingEthRxP,
         gtRxN(0)            => timingEthRxN
      );

   end generate GEN_GTX_ETH;

   GEN_GTP_ETH : if ( isArtix ) generate
      signal qpllLocked     : slv(1 downto 0);
      signal qpllResetOut   : slv(1 downto 0);
      signal qpllRefClkLost : slv(1 downto 0);
      signal qpllRst        : slv(1 downto 0) := "00";
      signal mmcmLocked     : sl;
   begin

   timingIb.rxPllSel     <= TIMING_PLL_SEL_C;
   timingIb.txPllSel     <= TIMING_PLL_SEL_C;
   timingIb.pllLocked    <= qpllLocked    (TIMING_PLL_C );
   timingIb.refClkLost   <= qpllRefClkLost(TIMING_PLL_C );
   timingIb.pllRstRequest<= qpllResetOut;
   timingIb.debug(0)     <= mmcmLocked;
   timingIb.debug(1)     <= qpllLocked(0);
   timingIb.debug(2)     <= qpllLocked(1);
   timingIb.debug(3)     <= qpllRefClkLost(0);
   timingIb.debug(4)     <= qpllRefClkLost(1);
   qpllRst(TIMING_PLL_C) <= timingOb.pllRst;

   U_PL_ETH_GTP : entity work.GigEthGtp7WrapperAdv
      generic map (
         TPD_G               => TPD_G,
         -- Clocking Configurations
         USE_GTREFCLK_G      => true, --  FALSE: gtClkP/N,  TRUE: gtRefClk
         -- PLL1 configuration (for timing line rate and 16-bit output width)
         -- line rate is 2*PLL_CLOCK / PLL_DIVISOR
         PLL1_FBDIV_IN_G     => 2,
         PLL1_FBDIV_45_IN_G  => 5,
         -- AXI-Lite Configurations
         PLL0_REFCLK_SEL_G   => "010", -- mgtRefClk(1) / 125MHz
         PLL1_REFCLK_SEL_G   => ite( DEVBRD_C, "010", "001" ),
         EN_AXI_REG_G        => true,
         -- AXI Streaming Configurations
         AXIS_CONFIG_G       => ETH_AXIS_CONFIG_C
      )
      port map (
         -- Local Configurations
         localMac(0)         => macAddr,
         -- Streaming DMA Interface
         dmaClk(0)           => sysClk,
         dmaRst(0)           => sysRst,
         dmaIbMasters(0)     => ethRxMaster,
         dmaIbSlaves (0)     => ethRxSlave,
         dmaObMasters(0)     => ethTxMaster,
         dmaObSlaves (0)     => ethTxSlave,
--         -- Slave AXI-Lite Interface
         axiLiteClk(0)       => sysClk,
         axiLiteRst(0)       => sysRst,
         axiLiteReadMasters(0)  => axilReadMasters(0),
         axiLiteReadSlaves(0)   => axilReadSlaves(0),
         axiLiteWriteMasters(0) => axilWriteMasters(0),
         axiLiteWriteSlaves(0)  => axilWriteSlaves(0),
         -- Misc. Signals
         extRst              => sysRst,
         phyClk              => open,
         phyRst              => open,
--         phyReady            : out slv(NUM_LANE_G-1 downto 0);
--         sigDet              : in  slv(NUM_LANE_G-1 downto 0)                     := (others => '1');
         -- MGT Clock Port (125.00 MHz or 250.0 MHz)
         gtRefClk            => mgtRefClk,
         gtRefClkBufg        => mgtRefClkBuf,
--         gtClkP              : in  sl                                             := '1';
--         gtClkN              : in  sl                                             := '0';
         mmcmLocked          => mmcmLocked,
         -- QPLL
         qpllOutClk          => timingIb.pllClk,
         qpllOutRefClk       => timingIb.pllRefClk,
         qpllLock            => qpllLocked,
         qpllRefClkLost      => qpllRefClkLost,
         qpllResetOut        => qpllResetOut,
         qpllReset           => qpllRst,
         -- Polarity
         gtTxPolarity(0)     => tiedToOne,
         -- MGT Ports
         gtTxP(0)            => timingEthTxP,
         gtTxN(0)            => timingEthTxN,
         gtRxP(0)            => timingEthRxP,
         gtRxN(0)            => timingEthRxN
      );

   end generate GEN_GTP_ETH;

   GEN_ETH_ILA : if ( false ) generate
   U_ILA_ETH_RX : entity work.IlaAxiStream
      port map (
         axisClk         => sysClk,
         trigIn          => dbgTrig(0),
         trigInAck       => dbgTrig(1),
         trigOut         => dbgTrig(2),
         trigOutAck      => dbgTrig(3),
         mAxis           => ethRxMaster,
         sAxis           => ethRxSlave
      );

   U_ILA_ETH_TX : entity work.IlaAxiStream
      port map (
         axisClk         => sysClk,
         trigIn          => dbgTrig(2),
         trigInAck       => dbgTrig(3),
         trigOut         => dbgTrig(0),
         trigOutAck      => dbgTrig(1),
         mAxis           => ethTxMaster,
         sAxis           => ethTxSlave
      );
   end generate GEN_ETH_ILA;

   end generate GEN_TIMING_UDP;

   cpuIrqs(IRQ_MAX_C - 1 downto 0) <= appIrqs(IRQ_MAX_C - 1 downto 0);

   GEN_DIFF_OUT : for i in diffOut'left - FEEDTHRU_C downto 0 generate
   begin
      diffOut(i) <= trigReg(i);
   end generate GEN_DIFF_OUT;

   outClk <= timingRecClk;
   outRst <= timingRecRst;

   P_DIV_RX : process ( outClk ) is
   begin
      if rising_edge( outClk ) then
         if ( outRst = '1' ) then
            rxDiv   <= to_unsigned( 0, rxDiv'length );
            recClk2 <= "00";
         else
            rxDiv   <= rxDiv + 1;
            recClk2 <= not recClk2;
         end if;
      end if;
   end process P_DIV_RX;

   P_DIV_TX : process (timingTxClk) is
   begin
      if rising_edge( timingTxClk ) then
         txDiv <= txDiv + 1;
      end if;
   end process P_DIV_TX;


   G_COPY_CLOCKS : if ( COPY_CLOCKS_C ) generate
      P_COPY_CLOCKS : process ( outClk) is
      begin
         if ( rising_edge( outClk ) ) then
            if ( outRst = '1' ) then
               trigReg <= TIMING_TRIG_INVERT_C;
	        else
               trigReg <= not trigReg;
            end if;
         end if;
      end process P_COPY_CLOCKS;
   end generate;

   G_NOT_COPY_CLOCKS: if ( not COPY_CLOCKS_C ) generate

      P_TRIG_REG : process ( timingTrig ) is
      begin
         trigReg <= timingTrig.trigPulse(trigReg'range);
      end process P_TRIG_REG;

   end generate G_NOT_COPY_CLOCKS;

   U_ODDR : component ODDR
      generic map (
         DDR_CLK_EDGE => "SAME_EDGE"
      )
      port map (
         C   => outClk,
         CE  => '1',
         D1  => '0', -- sample on negative clock edge
         D2  => '1',
         Q   => outClkLoc,
         S   => '0',
         R   => '0'
      );

   GEN_CLK_FEEDTHRU : if ( CLK_FEEDTHRU_G and (diffOut'length > 0) ) generate
   begin
      diffOut(diffOut'left) <= recClk2(0);
   end generate GEN_CLK_FEEDTHRU;
   ----------------
   -- Misc. Signals
   ----------------

   U_SYNC_RX_LED : entity work.SynchronizerVector
      generic map (
         WIDTH_G => 2
      )
      port map (
         clk       => sysClk,
         rst       => sysRst,
         dataIn(0) => si5344LOLb,
         dataIn(1) => rxDiv(27),
         dataOut   => rxLedData
      );

   P_RX_LED : process ( sysClk ) is
   begin

      if ( rising_edge( sysClk ) ) then

         if ( sysRst = '1' ) then
            rxLedTimer <= to_unsigned(0, rxLedTimer'length);
            rxLedState <= '0';
            rxClkState <= '0';
         else
            rxClkState <= rxLedData(1);

            if ( rxLedData(0) = '1' ) then
               -- PLL locked
               rxLedState <= '1';
               rxLedTimer <= to_unsigned(0, rxLedTimer'length);
            else
               if ( rxLedTimer /= 0 ) then
                  rxLedTimer <= rxLedTimer - 1;
               elsif ( rxLedData(1) = '1' and rxClkState = '0' ) then
                  rxLedTimer <= BLINK_TIME_UNS_C;
                  rxLedState <= '1';
               else
                  rxLedState <= '0';
               end if;
            end if;
         end if;
      end if;
   end process P_RX_LED;

   end generate GEN_NOT_IBERT;

   GEN_IBERT : if ( IBERT_C ) generate

   U_IBERT : component ibert_7series_gt_0
      PORT MAP (
         TXN_O          => mgtTxN,
         TXP_O          => mgtTxP,
         RXOUTCLK_O     => open,
         RXN_I          => mgtRxN,
         RXP_I          => mgtRxP,
         GTREFCLK0_I(0) => mgtRefClk(0),
         GTREFCLK1_I(0) => mgtRefClk(1),
         SYSCLK_I       => sysClk
      );

   end generate GEN_IBERT;

   -- common signals (on TE0715 module)

   psEthPhyLed0 <= B34_L9_P;

   GEN_IOMAP_TBOX : if ( TBOX_C ) generate

      GEN_SFPCTL_0 : if ( NUM_SFPS_G > 0 ) generate
         B13_L4_P        <= sfp_tx_dis(0);
         sfp_tx_flt  (0) <= B13_L4_N;
         sfp_los     (0) <= B13_L6_P;
         sfp_presentb(0) <= B13_L6_N;
      end generate GEN_SFPCTL_0;

      GEN_SFPCTL_1 : if ( NUM_SFPS_G > 1 ) generate
         B13_L10_P       <= sfp_tx_dis(1);
         sfp_tx_flt  (1) <= B13_L10_N;
         sfp_los     (1) <= B13_L7_P;
         sfp_presentb(1) <= B13_L7_N;
      end generate GEN_SFPCTL_1;

      -- Ethernet PHY LED[0] -- unfortunately this LED is
      -- virtually disconnected on the TE0715 module. There
      -- is a level translator (U21) with /OE tied to VCC
      -- which basically bricks it...
      -- B13_L2_P <= psEthPhyLed0; -- orange LED/anode green LED/cathode in ethernet connector

      si5344LOLb  <= B13_L24_N;
      si5344INTRb <= B13_L13_P;

      U_RESETBUF : component IOBUF
         port map (
            I  => sysRstbOut_o,
            IO => B13_L19_P,
            O  => sysRstbOut_i,
            T  => sysRstbOut_t
         );

      sysRstbInp <= B13_L19_N;

      -- Green (board edge)
      -- If Si5344 locked: steady green - else blink if recovered RX clock is active
      led(0) <= rxLedState;
      -- led(0) <= sl(rxDiv(27));
      led(1) <= not timingRxStat.locked;

      -- led(2) is the yellow lED in the ethernet connector
      led(2) <= rxDiv(27);
      -- led(3) and (4) are anti-parallel green/orange LEDs in the ethernet connector
      led(3) <= sl(txDiv(27));
      led(4) <= not sl(txDiv(27));

      B13_L9_P    <= led(0); -- green LED, D5 (board edge)
      B13_L1_N    <= led(1); -- red LED, D4 (board edge)
      B13_L2_P    <= led(2); -- yellow LED in eth connector
      B13_L2_N    <= led(3); -- orange/anode - green/cathode in eth connector
      B13_L1_P    <= led(4); -- orange/cathode - green/anode in eth connector

      U_RECCLKBUF : component OBUFDS
         generic map (
            IOSTANDARD => ite( isArtix, "DIFF_HSTL_I_18", "LVDS" ),
            SLEW       => ite( isArtix, "FAST",           ""     )
         )
         port map (
            I  => outClkLoc,
            O  => B34_L10_P,
            OB => B34_L10_N
         );

      U_DIFFOUT_BUF : ZynqOBufDS
         generic map (
            W_G        => diffOut'length,
            IOSTANDARD => "TMDS_33"
         )
         port map (
            o(0).x => B13_L8_P,
            o(0).b => B13_L8_N,
            o(1).x => B13_L23_P,
            o(1).b => B13_L23_N,
            o(2).x => B13_L14_P,
            o(2).b => B13_L14_N,
            o(3).x => B13_L21_P,
            o(3).b => B13_L21_N,
            o(4).x => B13_L20_P,
            o(4).b => B13_L20_N,
            o(5).x => B13_L15_P,
            o(5).b => B13_L15_N,
            o(6).x => B13_L22_P,
            o(6).b => B13_L22_N,

            i      => diffOut
         );

   end generate GEN_IOMAP_TBOX;

   GEN_IOMAP_ECEVR : if ( ECEVR_C ) generate

      -- board-level GPIO
      constant NUM_BRD_GPIO_C           : natural := 2;

      constant NUM_LAN_GPIO_C           : natural := 16;

      constant NUM_LAN_GPI_C            : natural := 8;
      constant NUM_LAN_GPO_C            : natural := 8;

      constant NUM_BUS_MSTS_C           : natural := 1;
      constant BUS_MIDX_PDO_C           : natural := 0;

      constant EVR_BASE_ADDR_C          : unsigned(31 downto 0) := x"0000_0000";

      constant NUM_BUS_SUBS_C           : natural := 2;
      constant BUS_SIDX_EVR_C           : natural := 0;
      constant BUS_SIDX_LOC_C           : natural := 1;

      constant NUM_HBI_MSTS_C           : natural := 1;
      constant PRI_HBI_MSTS_C           : integer := -1;
      constant HBI_MIDX_PDO_C           : integer := PRI_HBI_MSTS_C;
      constant HBI_MSTS_LDX_C           : integer := PRI_HBI_MSTS_C;
      constant HBI_MSTS_RDX_C           : integer := HBI_MSTS_LDX_C + NUM_HBI_MSTS_C - 1;

      constant MAX_TXPDO_SEGMENTS_C     : natural := 16;

      constant LATCH0_MAP_C             : natural := ite( (PRJ_VARIANT_G = "ecevr-dio"), 0, 42 );
      constant LATCH1_MAP_C             : natural := ite( (PRJ_VARIANT_G = "ecevr-dio"), 38, 43 );

      type     IntArray                 is array (integer range <>) of integer;

      -- map GPIO numbers to index in 'fpga' array
      constant lan9254_gpio_map : IntArray(NUM_LAN_GPIO_C - 1 downto 0) := (
          0 => 35,  1 => 36,  2 => 37,  3 => 39,
          4 => 18,  5 => 17,  6 => 16,  7 =>  9,
          8 =>  8,  9 => 27, 10 => 23, 11 => 20,
         12 => 21, 13 => 22, 14 => 24, 15 => 25
      );

      signal brd_gpio_i : std_logic_vector(NUM_BRD_GPIO_C - 1 downto 0);
      signal brd_gpio_o : std_logic_vector(NUM_BRD_GPIO_C - 1 downto 0) := (others => '0');
      signal brd_gpio_t : std_logic_vector(NUM_BRD_GPIO_C - 1 downto 0) := (others => '1');
      signal brd_gpio_tb: std_logic_vector(NUM_BRD_GPIO_C - 1 downto 0) := (others => '0');

      signal fpga_i     : std_logic_vector(43 downto 0);
      signal fpga_o     : std_logic_vector(43 downto 0) := (others => '0');
      signal fpga_t     : std_logic_vector(43 downto 0) := (others => '1');

      -- assume EEPROM is configured for gpio(15 downto 0) -> inputs, gpio(7 downto 0) -> outputs
      --               in/out from viewpoint of LAN9254...

      signal lan9254_gpi: std_logic_vector(NUM_LAN_GPIO_C - 1 downto NUM_LAN_GPO_C) := (others => '0');
      signal lan9254_gpo: std_logic_vector(NUM_LAN_GPO_C  - 1 downto             0);

      signal lan9254_hbiOb : Lan9254HBIOutType := LAN9254HBIOUT_INIT_C;
      signal lan9254_hbiIb : Lan9254HBIInpType := LAN9254HBIINP_INIT_C;

      signal lan9254_irq   : std_logic := '0';

      signal lan9254LocReg : std_logic_vector(31 downto 0) := (others => '0');
      signal lan9254LocRegR: std_logic_vector(31 downto 0) := (others => '0');

      signal ec_SYNC_i     : std_logic_vector( 1 downto 0);
      signal ec_LATCH_o    : std_logic_vector( 1 downto 0) := (others => '0');
      signal ec_LATCH_t    : std_logic_vector( 1 downto 0) := (others => '1');

      signal spiSel        : std_logic := '0';
      signal axiSel        : std_logic := '0';
      signal escRst        : std_logic := '0';
      signal eepRst        : std_logic := '0';
      signal hbiRst        : std_logic := '0';

      signal testFailed    : std_logic_vector(4 downto 0) := (others => '0');

      signal eeprom_sda_i   : std_logic;
      signal eeprom_sda_o   : std_logic := '1';
      signal eeprom_sda_t   : std_logic := '1';

      signal eeprom_scl_i   : std_logic;
      signal eeprom_scl_o   : std_logic := '1';
      signal eeprom_scl_t   : std_logic := '1';

      signal configReq      : EEPROMConfigReqType;
      signal configAck      : EEPROMConfigAckType := EEPROM_CONFIG_ACK_ASSERT_C;
      signal dbufSegments   : MemXferArray(MAX_TXPDO_SEGMENTS_C - 1 downto 0);
      signal configRetries  : unsigned(3 downto 0);
      signal configRstR     : std_logic := '0';
      signal configRstRIn   : std_logic;
      signal configRst      : std_logic;
      signal configDebug    : std_logic_vector(31 downto 0);

begin

      assert NUM_LAN_GPI_C + NUM_LAN_GPO_C = NUM_LAN_GPIO_C severity failure;

      ila1(43 downto 0) <= fpga_i;

      -- RST# and other locReg mappings
      fpga_o(1)    <= not lan9254LocReg(0);
      fpga_t(1)    <= '0';

      spiSel       <= lan9254LocReg(1);
      axiSel       <= lan9254LocReg(2);
      escRst       <= lan9254LocReg(4);
      hbiRst       <= lan9254LocReg(5);
      eepRst       <= lan9254LocReg(6);

      lan9254LocRegR(0) <= lan9254_irq;


      -- SYNC
      ec_SYNC_i(1) <= fpga_i(11);
      fpga_t(11)   <= '1';
      ec_SYNC_i(0) <= fpga_i(29);
      fpga_t(29)   <= '1';

      -- LATCH
      fpga_o(LATCH1_MAP_C) <= ec_LATCH_o(1);
      fpga_t(LATCH1_MAP_C) <= ec_LATCH_t(1);
      fpga_o(LATCH0_MAP_C) <= ec_LATCH_o(0);
      fpga_t(LATCH0_MAP_C) <= ec_LATCH_t(0);

      GEN_IOBUF : ZynqIOBuf
         generic map (
            W_G => fpga_i'length
         )
         port map (
            i      => fpga_o,
            t      => fpga_t,
            o      => fpga_i,

            io( 0) => B34_L15_N,
            io( 1) => B34_L15_P,
            io( 2) => B34_L18_N,
            io( 3) => B34_L2_P,
            io( 4) => B34_L2_N,
            io( 5) => B34_L12_P,
            io( 6) => B34_L6_N,
            io( 7) => B34_L6_P,
            io( 8) => B34_L8_P,
            io( 9) => B35_L16_P,
            io(10) => B35_L16_N,
            io(11) => B34_L7_N,
            io(12) => B35_L18_N,
            io(13) => B35_L18_P,
            io(14) => B35_L21_P,
            io(15) => B35_L15_N,
            io(16) => B35_L15_P,
            io(17) => B35_L8_P,
            io(18) => B35_L13_P,
            io(19) => B35_L13_N,
            io(20) => B35_L11_N,
            io(21) => B35_L14_P,
            io(22) => B35_L14_N,
            io(23) => B35_L3_N,
            io(24) => B35_L12_P,
            io(25) => B35_L12_N,
            io(26) => B35_L7_N,
            io(27) => B35_L23_N,
            io(28) => B35_L23_P,
            io(29) => B35_L4_P,
            io(30) => B35_L2_N,
            io(31) => B35_L2_P,
            io(32) => B35_L5_N,
            io(33) => B35_L17_P,
            io(34) => B35_L17_N,
            io(35) => B35_L6_N,
            io(36) => B35_L24_P,
            io(37) => B35_L24_N,
            io(38) => B35_L0,
            io(39) => B35_L9_N,
            io(40) => B35_L9_P,
            io(41) => B35_L22_N,
            io(42) => B35_L22_P,
            io(43) => B35_L10_N
         );

      GEN_SFPCTL_0 : if ( NUM_SFPS_G > 0 ) generate
         B13_L6_N        <= sfp_tx_dis(0);
         sfp_tx_flt  (0) <= B13_L6_P;
         sfp_los     (0) <= B13_L4_N;
         sfp_presentb(0) <= B13_L4_P;
      end generate GEN_SFPCTL_0;

      GEN_IOMAP_SPIBUF : if ( PRJ_VARIANT_G = "ecevr-spi" ) generate

         fpga_o(10)    <= spiOb(0).o.mosi;
         fpga_t(10)    <= spiOb(0).t.mosi;
         spiIb(0).mosi <= fpga_i(10);

         fpga_o(15)    <= spiOb(0).o.sclk;
         fpga_t(15)    <= spiOb(0).t.sclk;
         spiIb(0).sclk <= fpga_i(15);

         fpga_o( 5)    <= spiOb(0).o.miso;
         fpga_t( 5)    <= spiOb(0).t.miso;
         spiIb(0).miso <= fpga_i( 5);

         fpga_o(40)    <= spiOb(0).o_ss(1);
         fpga_t(40)    <= '0';

      end generate GEN_IOMAP_SPIBUF;

      GEN_IOMAP_HBI16_MUX : if ( PRJ_VARIANT_G = "ecevr-hbi16m" ) generate

         signal fpga_o_05      : std_logic;
         signal fpga_o_10      : std_logic;
         signal fpga_o_15      : std_logic;
         signal fpga_o_40      : std_logic;
         signal fpga_t_05      : std_logic;
         signal fpga_t_10      : std_logic;
         signal fpga_t_15      : std_logic;
         signal fpga_t_40      : std_logic;
         signal fpga_i_05      : std_logic;
         signal fpga_i_10      : std_logic;
         signal fpga_i_15      : std_logic;
         signal fpga_i_40      : std_logic;

         signal axiHbiReq      : Lan9254ReqType := LAN9254REQ_INIT_C;
         signal axiHbiRep      : Lan9254RepType := LAN9254REP_INIT_C;
         signal escHbiReq      : Lan9254ReqType := LAN9254REQ_INIT_C;
         signal escHbiRep      : Lan9254RepType := LAN9254REP_INIT_C;

         signal hbiReq         : Lan9254ReqType;
         signal hbiRep         : Lan9254RepType;

         signal rxPDOMst       : Lan9254PDOMstType;
         signal rxPDORdy       : std_logic := '1';

         signal escState       : ESCStateType;
         signal ctlState       : std_logic_vector(4 downto 0);

         signal hbi_ad_t       : std_logic := '1';
         signal hbi_ob_t       : std_logic := '1';

         signal escStats       : StatCounterArray(21 downto 0);
         signal diagRegsR      : Slv32Array(31 downto 0) := (others => (others => '0'));

         signal phas           : signed(15 downto 0);
         signal pdLocked       : std_logic;

         signal busSubReq      : Udp2BusReqArray(NUM_BUS_SUBS_C - 1 downto 0) := (others => UDP2BUSREQ_INIT_C);
         signal busSubRep      : Udp2BusRepArray(NUM_BUS_SUBS_C - 1 downto 0) := (others => UDP2BUSREP_INIT_C);

         signal busMstReq      : Udp2BusReqArray(NUM_BUS_MSTS_C - 1 downto 0) := (others => UDP2BUSREQ_INIT_C);
         signal busMstRep      : Udp2BusRepArray(NUM_BUS_MSTS_C - 1 downto 0) := (others => UDP2BUSREP_INIT_C);

         signal hbiMstReq      : Lan9254ReqArray(HBI_MSTS_LDX_C downto HBI_MSTS_RDX_C) := (others => LAN9254REQ_INIT_C);
         signal hbiMstRep      : Lan9254RepArray(HBI_MSTS_LDX_C downto HBI_MSTS_RDX_C) := (others => LAN9254REP_INIT_C);

         signal timingMGTSt    : std_logic_vector(31 downto 0) := (others => '0');

         signal usr_evts_adj   : std_logic_vector(3 downto 0);
         signal latchedEvents  : std_logic_vector(1 downto 0);
         signal extra_events   : std_logic_vector(NUM_EXTRA_EVENTS_C - 1 downto 0);
         signal evrTimestampHi : std_logic_vector(31 downto 0) := (others => '0');
         signal evrTimestampLo : std_logic_vector(31 downto 0) := (others => '0');
         signal eventCode      : std_logic_vector( 7 downto 0) := (others => '0');
         signal eventCodeVld   : std_logic                     := '0';

         signal txPdoTrgCount  : unsigned(15 downto 0);

         signal s_spiIb        : ZynqSpiType;
         signal s_fpga_o_05    : std_logic;
         signal s_fpga_t_05    : std_logic;
         signal s_fpga_o_10    : std_logic;
         signal s_fpga_t_10    : std_logic;
         signal s_fpga_o_15    : std_logic;
         signal s_fpga_t_15    : std_logic;
         signal s_fpga_o_40    : std_logic;
         signal s_fpga_t_40    : std_logic;

      begin

         -- work-around for an apparent Vivado bug: if we assign only to
         -- a subset of signal array elements from a combinatorial process
         -- then the default values of other elements are ignored:
         --
         --   signal foo : std_logic_vector(1 downto 0) := (others => '1');
         --
         --   process (x) is
         --   begin
         --     foo(0) <= x;
         --   end process;
         --
         -- will have Vivado ignoring the '1' value for foo(1). Work around
         -- this problem by using (scalar) intermediate signals :-(.
         P_SPI_MUX : process (
            spiSel, axiSel, spiOb, fpga_i,
            fpga_o_05, fpga_t_05, fpga_o_10, fpga_t_10,
            fpga_o_15, fpga_t_15, fpga_o_40, fpga_t_40,
            lan9254_hbiOb,
            spiIb
         ) is
            variable v_spiIb  : ZynqSpiType;
         begin
            v_spiIb  := spiIb(0);
            if ( ( spiSel = '1' ) and ( axiSel = '0' ) ) then
               s_fpga_o_10   <= spiOb(0).o.mosi;
               s_fpga_t_10   <= spiOb(0).t.mosi;
               v_spiIb.mosi  := fpga_i(10);
               fpga_i_10     <= '0';

               s_fpga_o_15   <= spiOb(0).o.sclk;
               s_fpga_t_15   <= spiOb(0).t.sclk;
               v_spiIb.sclk  := fpga_i(15);
               fpga_i_15     <= '0';

               s_fpga_o_05   <= spiOb(0).o.miso;
               s_fpga_t_05   <= spiOb(0).t.miso;
               v_spiIb.miso  := fpga_i( 5);
               fpga_i_05     <= '0';

               s_fpga_o_40   <= spiOb(0).o_ss(1);
               s_fpga_t_40   <= '0';
               fpga_i_40     <= '0';

               hbi_ad_t      <= '1';
               hbi_ob_t      <= '1';
            else
               s_fpga_o_10   <= fpga_o_10;
               s_fpga_t_10   <= fpga_t_10;
               v_spiIb.mosi  := '1';
               fpga_i_10     <= fpga_i(10);

               s_fpga_o_15   <= fpga_o_15;
               s_fpga_t_15   <= fpga_t_15;
               v_spiIb.sclk  := '1';
               fpga_i_15     <= fpga_i(15);

               s_fpga_o_05   <= fpga_o_05;
               s_fpga_t_05   <= fpga_t_05;
               v_spiIb.miso  := '1';
               fpga_i_05     <= fpga_i( 5);

               s_fpga_o_40   <= fpga_o_40;
               s_fpga_t_40   <= fpga_t_40;
               fpga_i_40     <= fpga_i(40);

               hbi_ad_t      <= lan9254_hbiOb.ad_t( 0);
               hbi_ob_t      <= '0';
            end if;
            s_spiIb  <= v_spiIb;
         end process P_SPI_MUX;

         spiIb(0)    <= s_spiIb;

         fpga_o(10)  <= s_fpga_o_10;
         fpga_t(10)  <= s_fpga_t_10;

         fpga_o(15)  <= s_fpga_o_15;
         fpga_t(15)  <= s_fpga_t_15;

         fpga_o( 5)  <= s_fpga_o_05;
         fpga_t( 5)  <= s_fpga_t_05;

         fpga_o(40)  <= s_fpga_o_40;
         fpga_t(40)  <= s_fpga_t_40;

         P_HBI_MUX : process (
            axiSel, axiHbiReq, escHbiReq, hbiRep
         ) is begin
            if ( axiSel = '1' ) then
               hbiReq        <= axiHbiReq;
               axiHbiRep     <= hbiRep;
               escHbiRep     <= LAN9254REP_INIT_C;
            else
               hbiReq        <= escHbiReq;
               axiHbiRep     <= LAN9254REP_DFLT_C;
               escHbiRep     <= hbiRep;
            end if;
         end process P_HBI_MUX;

         lan9254_hbiIb.waitAck <= fpga_i( 0);
         fpga_t(0)             <= '1';

         lan9254_hbiIb.ad(15) <= fpga_i(27);
         lan9254_hbiIb.ad(14) <= fpga_i( 8);
         lan9254_hbiIb.ad(13) <= fpga_i( 9);
         lan9254_hbiIb.ad(12) <= fpga_i(16);
         lan9254_hbiIb.ad(11) <= fpga_i(17);
         lan9254_hbiIb.ad(10) <= fpga_i(18);
         lan9254_hbiIb.ad( 9) <= fpga_i_15;
         lan9254_hbiIb.ad( 8) <= fpga_i(37);
         lan9254_hbiIb.ad( 7) <= fpga_i(36);
         lan9254_hbiIb.ad( 6) <= fpga_i(35);
         lan9254_hbiIb.ad( 5) <= fpga_i_40;
         lan9254_hbiIb.ad( 4) <= fpga_i(39);
         lan9254_hbiIb.ad( 3) <= fpga_i(34);
         lan9254_hbiIb.ad( 2) <= fpga_i( 4);
         lan9254_hbiIb.ad( 1) <= fpga_i_05;
         lan9254_hbiIb.ad( 0) <= fpga_i_10;

         fpga_o(27)           <= lan9254_hbiOb.ad(15);
         fpga_o( 8)           <= lan9254_hbiOb.ad(14);
         fpga_o( 9)           <= lan9254_hbiOb.ad(13);
         fpga_o(16)           <= lan9254_hbiOb.ad(12);
         fpga_o(17)           <= lan9254_hbiOb.ad(11);
         fpga_o(18)           <= lan9254_hbiOb.ad(10);
         fpga_o_15            <= lan9254_hbiOb.ad( 9);
         fpga_o(37)           <= lan9254_hbiOb.ad( 8);
         fpga_o(36)           <= lan9254_hbiOb.ad( 7);
         fpga_o(35)           <= lan9254_hbiOb.ad( 6);
         fpga_o_40            <= lan9254_hbiOb.ad( 5);
         fpga_o(39)           <= lan9254_hbiOb.ad( 4);
         fpga_o(34)           <= lan9254_hbiOb.ad( 3);
         fpga_o( 4)           <= lan9254_hbiOb.ad( 2);
         fpga_o_05            <= lan9254_hbiOb.ad( 1);
         fpga_o_10            <= lan9254_hbiOb.ad( 0);

         fpga_t(27)           <= hbi_ad_t;
         fpga_t( 8)           <= hbi_ad_t;
         fpga_t( 9)           <= hbi_ad_t;
         fpga_t(16)           <= hbi_ad_t;
         fpga_t(17)           <= hbi_ad_t;
         fpga_t(18)           <= hbi_ad_t;
         fpga_t_15            <= hbi_ad_t;
         fpga_t(37)           <= hbi_ad_t;
         fpga_t(36)           <= hbi_ad_t;
         fpga_t(35)           <= hbi_ad_t;
         fpga_t_40            <= hbi_ad_t;
         fpga_t(39)           <= hbi_ad_t;
         fpga_t(34)           <= hbi_ad_t;
         fpga_t( 4)           <= hbi_ad_t;
         fpga_t_05            <= hbi_ad_t;
         fpga_t_10            <= hbi_ad_t;

         fpga_o(22)           <= lan9254_hbiOb.cs;
         fpga_t(22)           <= hbi_ob_t;

         fpga_o(21)           <= lan9254_hbiOb.be(1);
         fpga_t(21)           <= hbi_ob_t;

         fpga_o(20)           <= lan9254_hbiOb.be(0);
         fpga_t(20)           <= hbi_ob_t;

         fpga_o(25)           <= lan9254_hbiOb.rs;
         fpga_t(25)           <= hbi_ob_t;

         fpga_o(24)           <= lan9254_hbiOb.ws;
         fpga_t(24)           <= hbi_ob_t;

         fpga_o(19)           <= lan9254_hbiOb.ale(0);
         fpga_t(19)           <= hbi_ob_t;

         axilIlaSpare0(15 downto  0) <= lan9254_hbiOb.ad(15 downto 0);
         axilIlaSpare0(17 downto 16) <= lan9254_hbiOb.ale;
         axilIlaSpare0(19 downto 18) <= lan9254_hbiOb.be;
         axilIlaSpare0(          20) <= lan9254_hbiOb.rs;
         axilIlaSpare0(          21) <= lan9254_hbiOb.ws;
         axilIlaSpare0(          22) <= lan9254_hbiOb.cs;
         axilIlaSpare0(          23) <= lan9254_hbiOb.ad_t(0);

         axilIlaSpare1(15 downto  0) <= lan9254_hbiIb.ad(15 downto 0);
         axilIlaSpare1(          16) <= lan9254_hbiIb.waitAck;

         U_AXIL_HBI_BRIDGE : entity work.AxilLan9254HbiMaster
            port map (
               axilClk           => sysClk,
               axilRst           => sysRst,

               axilWriteMaster   => axilWriteMasters(2),
               axilWriteSlave    => axilWriteSlaves (2),
               axilReadMaster    => axilReadMasters (2),
               axilReadSlave     => axilReadSlaves  (2),

               hbiReq            => axiHbiReq,
               hbiRep            => axiHbiRep,

               locRegRW          => lan9254LocReg,
               locRegR           => lan9254LocRegR
            );

         GEN_LED_MAP : for i in 3 downto 0 generate
            led(i) <= lan9254LocReg(8+i);
         end generate GEN_LED_MAP;

         U_HBI : entity work.Lan9254HBI
            generic map (
               CLOCK_FREQ_G => CLK_FREQ_C
            )
            port map (
               clk          => sysClk,
               rst          => hbiRst,

               req          => hbiReq,
               rep          => hbiRep,

               hbiOut       => lan9254_hbiOb,
               hbiInp       => lan9254_hbiIb
            );

         ctlState                     <= axilIlaSpare2(4 downto 0);
         lan9254LocRegR(12 downto  8) <= ctlState;
         lan9254LocRegR(20 downto 16) <= testFailed;

         U_PD  : entity work.PhaseDetector
            generic map (
               CLK_PERIOD_G => 5.385, -- ns
               DECM_MULT_G  => 256
            )
            port map (
               pclk(0)      => timingOb.txClk,
               pclk(1)      => timingOb.recClk,
               clk          => sysClk,
               rst          => sysRst,
               locked       => pdLocked,
               phas         => phas
            );

         diagRegsR(31)(31 downto 16) <= std_logic_vector(resize(phas,16));
         diagRegsR(31)(15 downto  1) <= (others => '0');
         diagRegsR(31)(           0) <= pdLocked;

         U_ESC : entity work.Lan9254ESCWrapper
            generic map (
               CLOCK_FREQ_G          => CLK_FREQ_C,
               NUM_BUS_SUBS_G        => NUM_BUS_SUBS_C,
               NUM_BUS_MSTS_G        => NUM_BUS_MSTS_C,
               NUM_EXT_HBI_MASTERS_G => NUM_HBI_MSTS_C,
               EXT_HBI_MASTERS_PRI_G => PRI_HBI_MSTS_C,
               -- our EvrTxPDO talks to the HBI directly
               DISABLE_TXPDO_G       => true
            )
            port map (
               clk          => sysClk,
               rst          => escRst,

               escState     => escState,
               debug        => axilIlaSpare2,

               req          => escHbiReq,
               rep          => escHbiRep,

               myAddr       => configReq.net,
               myAddrAck    => configAck.net,

               escConfigReq => configReq.esc,
               escConfigAck => configAck.esc,

               extHBIReq    => hbiMstReq,
               extHBIRep    => hbiMstRep,

               busMstReq    => busMstReq,
               busMstRep    => busMstRep,

               busSubReq    => busSubReq,
               busSubRep    => busSubRep,

               txPDOMst     => open,
               txPDORdy     => open,

               rxPDOMst     => rxPDOMst,
               rxPDORdy     => rxPDORdy,

               irq          => lan9254_irq,

               testFailed   => testFailed,
               stats        => escStats
            );

         U_EVR : entity work.evr320_udp2bus_wrapper
            generic map (
               g_BUS_CLOCK_FREQ  => natural( CLK_FREQ_C ),
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

               evr_rx_data       => timingRx.data,
               evr_rx_charisk    => timingRx.dataK,
               mgt_status_i      => timingMGTSt
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

         ec_LATCH_o(0) <= latchedEvents(0);
         ec_LATCH_t(0) <= '0'; -- out
         ec_LATCH_o(1) <= extra_events(2);
         ec_LATCH_t(1) <= '0'; -- out

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
               CLOCK_FREQ_G       => CLK_FREQ_C,
               MAX_TXPDO_MAPS_G   => MAX_TXPDO_SEGMENTS_C
            )
            port map (
               clk                => sysClk,
               rst                => configRst,

               configReq          => configReq,
               configAck          => configAck,
               dbufMaps           => dbufSegments,

               i2cAddr2BMode      => '0',

               i2cSclInp          => eeprom_scl_i,
               i2cSclOut          => eeprom_scl_o,
               i2cSclHiZ          => eeprom_scl_t,

               i2cSdaInp          => eeprom_sda_i,
               i2cSdaOut          => eeprom_sda_o,
               i2cSdaHiZ          => eeprom_sda_t,

               retries            => configRetries
            );

         G_I2C_ILA : if ( true ) generate
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
                  clk        => ilaClk,
                  probe0(0)  => eeprom_scl_i,
                  probe0(1)  => eeprom_sda_i,
                  probe0(2)  => eeprom_scl_o,
                  probe0(3)  => eeprom_sda_o,
                  probe0(4)  => eeprom_scl_t,
                  probe0(5)  => eeprom_sda_t,
                  probe0(63 downto 6) => (others => '0')
               );
         end generate G_I2C_ILA;

         configRst <= escRst or configRstR or eepRst;

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
            configRstRin                    <= configRstR;
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
               when 4 => v    := BUILD_INFO_G(BUILD_INFO_G'left downto BUILD_INFO_G'left - 32 + 1);
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

         timingMGTSt <= (
             0     => timingIb.pllLocked,
             1     => timingIb.pllLocked,
             2     => '1', -- (non-existing/needed MMCM locked)
             3     => timingOb.txStat.resetDone,
             4     => timingOb.rxStat.resetDone,
             18    => timingRx.decErr(0),
             19    => timingRx.decErr(1),
             20    => timingRx.dspErr(0),
             21    => timingRx.dspErr(1),
            others => '0'
         );

         U_DIAG_REGS : entity work.AxiLiteRegs
            generic map (
               NUM_READ_REG_G => diagRegsR'length
            )
            port map (
               axiClk         => sysClk,
               axiClkRst      => sysRst,

               axiWriteMaster => axilWriteMasters(3),
               axiWriteSlave  => axilWriteSlaves (3),
               axiReadMaster  => axilReadMasters (3),
               axiReadSlave   => axilReadSlaves  (3),
               writeRegister  => open,
               readRegister   => diagRegsR
         );

         P_DIAG_ASSIGN : process ( escStats ) is
         begin
            for i in escStats'range loop
               diagRegsR(i)                    <= (others => '0');
               diagRegsR(i)(escStats(i)'range) <= std_logic_vector(escStats(i));
            end loop;
         end process P_DIAG_ASSIGN;

         rxPDORdy         <= '1';

         P_LED : process ( sysClk ) is
         begin
            if ( rising_edge( sysClk ) ) then
               if ( rxPDOMst.valid = '1' and to_integer( rxPDOMst.wrdAddr ) = 0 and rxPDOMst.ben(0) = '1' ) then
                  led(7 downto 4) <= rxPDOMst.data(3 downto 0);
               end if;
            end if;
         end process P_LED;

      end generate GEN_IOMAP_HBI16_MUX;

      GEN_GPIO_MAP : if ( PRJ_VARIANT_G = "ecevr-spi" or PRJ_VARIANT_G = "ecevr-dio" ) generate
         GEN_GPI_MAP : for i in lan9254_gpi'range generate
            fpga_o(lan9254_gpio_map(i)) <= lan9254_gpi(i);
            fpga_t(lan9254_gpio_map(i)) <= '0';
         end generate GEN_GPI_MAP;

         GEN_GPO_MAP : for i in lan9254_gpo'range generate
            lan9254_gpo(i)              <= fpga_i(lan9254_gpio_map(i));
            fpga_t(lan9254_gpio_map(i)) <= '1';
         end generate GEN_GPO_MAP;


         -- hack to drive RST#
         lan9254LocReg(0) <= timingTxStat.resetDone;

         -- led(0..7) left -> right; 4 red; 4 grn
         GEN_LED_MAP : for i in lan9254_gpo'range generate
            led(i)          <= lan9254_gpo(i);
         end generate GEN_LED_MAP;

         -- control board GPIO from ethercat
         brd_gpio_o(0)  <= lan9254_gpo(0);
         brd_gpio_t(0)  <= lan9254_gpo(1);
         brd_gpio_o(1)  <= lan9254_gpo(2);
         brd_gpio_t(1)  <= lan9254_gpo(3);

         lan9254_gpi(NUM_LAN_GPO_C + 0) <= brd_gpio_i(0);
         lan9254_gpi(NUM_LAN_GPO_C + 1) <= brd_gpio_i(1);
         lan9254_gpi(NUM_LAN_GPO_C + 7 downto NUM_LAN_GPO_C + 2) <= lan9254_gpo(7 downto 2);

      end generate GEN_GPIO_MAP;

      -- GPIO
      U_GPIO_DAT_BUF : entity work.ZynqIOBuf
         generic map (
            W_G   => NUM_BRD_GPIO_C
         )
         port map (
            io(0)  => B35_L10_P,
            io(1)  => B35_L20_P,
            i      => brd_gpio_o,
            o      => brd_gpio_i,
            t      => brd_gpio_t
         );

      brd_gpio_tb <= not brd_gpio_t;

      U_GPIO_DIR_BUF : entity work.ZynqIOBuf
         generic map (
            W_G   => NUM_BRD_GPIO_C
         )
         port map (
            io(0)  => B35_L20_N,
            io(1)  => B35_L25,
            i      => brd_gpio_tb,
            o      => open,
            t      => (others => '0')
         );

      -- must not use ZynqIOBuf here because the 'tbox' project variant
      -- uses TMDS_33 for some of these pins which can only be uni-directional
      B13_L15_N <= led( 0);
      B13_L15_P <= led( 1);
      B13_L20_P <= led( 2);
      B13_L20_N <= led( 3);
      B13_L21_P <= led( 4);
      B13_L21_N <= led( 5);
      -- blue-wired to EEPROM I2C-SCL B13_L18_N <= led( 6);
      -- blue-wired to EEPROM I2C-SDA B13_L18_P <= led( 7);
      B13_L3_P  <= led( 8);
      B13_L3_N  <= led( 9);
      B13_L5_N  <= led(10);

      B13_L18_P    <= 'Z' when eeprom_sda_t = '1' else eeprom_sda_o;
      eeprom_sda_i <= B13_L18_P;
      B13_L18_N    <= 'Z' when eeprom_scl_t = '1' else eeprom_scl_o;
      eeprom_scl_i <= B13_L18_N;

      -- ylo led in PS-ethernet connector
      led(8)          <= not timingTxStat.resetDone;
      -- grn-cat/amb-ano in PS-ethernet conn.
      led(9)          <= '0';
      -- grn-ano/amb-cat in PS-ethernet conn.
      led(10)         <= '0';

      GEN_MAP_DIGIO : if ( PRJ_VARIANT_G = "ecevr-dio" ) generate
      -- OE_EXT
      fpga_o(19) <= '1';
      fpga_t(19) <= '0';
      end generate GEN_MAP_DIGIO;

      GEN_MAP_IRQ   : if ( PRJ_VARIANT_G /= "ecevr_dio" ) generate

         U_SYNC_IRQ : entity work.SynchronizerBit
            generic map (
               RSTPOL_G   => not EC_IRQ_ACT_C
            )
            port map (
               clk        => sysClk,
               rst        => sysRst,
               datInp(0)  => fpga_i(38),
               datOut(0)  => lan9254_irq
            );

         fpga_t(38) <= '1';

      end generate GEN_MAP_IRQ;

      -- IRQ
      GEN_IRQ_8 : if ( (NUM_IRQS_C > 8) and  (PRJ_VARIANT_G /= "ecevr_dio") ) generate
         cpuIrqs(8) <= lan9254_irq;
      end generate GEN_IRQ_8;

      GEN_IRQ_9 : if ( NUM_IRQS_C > 9 ) generate
         cpuIrqs(9) <= pl_spi_irq;
      end generate GEN_IRQ_9;

   end generate GEN_IOMAP_ECEVR;

   GEN_IOMAP_DEVBD : if ( PRJ_VARIANT_G = "devbd" ) generate

      GEN_SFPCTL_0 : if ( NUM_SFPS_G > 0 ) generate
         B13_L6_N        <= sfp_tx_dis(0);
         sfp_tx_flt  (0) <= B13_L6_P;
         sfp_los     (0) <= B13_L4_N;
         sfp_presentb(0) <= B13_L4_P;
      end generate GEN_SFPCTL_0;

   end generate GEN_IOMAP_DEVBD;

end top_level;
