library ieee;
use     ieee.std_logic_1164.all;
use     ieee.numeric_std.all;
use     ieee.math_real.all;


use work.ESCBasicTypesPkg.all;
use work.Lan9254Pkg.all;
use work.ESCFoEPkg.all;
use work.FoE2SpiPkg.all;
use work.Udp2BusPkg.all;

entity FoE2Spi is
   generic (
      FILE_MAP_G          : FlashFileArray;
      CLOCK_FREQ_G        : real;
      SPI_CLOCK_FREQ_G    : real    := 10.0E6;
      LD_ERASE_BLK_SIZE_G : natural := 16;
      -- flash page size (for writing)
      LD_PAGE_SIZE_G      : natural := 8;
      -- SPI readback via UDP page size
      -- (necessary because the supported address range
      -- does not cover a full flash device)
      LD_BUS_PAGE_SIZE_G  : natural range 2 to 20 :=16;
      -- enable unrealistic settings
      -- for simulation/testing *DO NOT USE*
      EN_SIM_G            : boolean := false
   );
   port (
      clk                 : in  std_logic;
      rst                 : in  std_logic;

      foeMst              : in  FoEMstType;
      foeSub              : out FoESubType;

      busReq              : in  Udp2BusReqType := UDP2BUSREQ_INIT_C;
      busRep              : out Udp2BusRepType;

      sclk                : out std_logic;
      mosi                : out std_logic;
      miso                : in  std_logic := '1';
      scsb                : out std_logic;

      progress            : out std_logic_vector( 3 downto 0);

      debug               : out std_logic_vector(63 downto 0)
   );
end entity FoE2Spi;

architecture Impl of FoE2Spi is

   constant DIV2_C                : integer := integer( ceil( CLOCK_FREQ_G/SPI_CLOCK_FREQ_G/2.0 ) );
   constant PAGE_SIZE_C           : natural := 2**LD_PAGE_SIZE_G;

   -- for testing we can reduce the page size but still want a big enough counter
   constant LEN_MAX_C             : natural := ite(PAGE_SIZE_C < 100, 100, PAGE_SIZE_C) - 1;

   constant BLK_SIZE_C            : natural := 2**LD_ERASE_BLK_SIZE_G;

   constant SPICMD_RD_STATUS_C    : std_logic_vector(7 downto 0) := x"05";
   constant SPICMD_WR_ENABLE_C    : std_logic_vector(7 downto 0) := x"06";
   constant SPICMD_WR_PAGE_C      : std_logic_vector(7 downto 0) := x"02";
   constant SPICMD_ERASE_B64_C    : std_logic_vector(7 downto 0) := x"D8";
   constant SPICMD_ERASE_B32_C    : std_logic_vector(7 downto 0) := x"52";
   constant SPICMD_ERASE_S04_C    : std_logic_vector(7 downto 0) := x"20";
   constant SPICMD_ONES_C         : std_logic_vector(7 downto 0) := x"FF";

   constant SPI_ST0_BUSY_IDX_C    : natural                      := 0;

   function SPICMD_ERASE_BLK_F return std_logic_vector is
   begin
      if    ( LD_ERASE_BLK_SIZE_G = 16 ) then return SPICMD_ERASE_B64_C;
      elsif ( LD_ERASE_BLK_SIZE_G = 15 ) then return SPICMD_ERASE_B32_C;
      elsif ( LD_ERASE_BLK_SIZE_G = 12 ) then return SPICMD_ERASE_S04_C;
      else
         assert EN_SIM_G report "INVALID BLOCK SIZE" severity failure;
         return SPICMD_ERASE_B64_C;
      end if;
   end function SPICMD_ERASE_BLK_F;

   constant CSB_ACT_C             : std_logic := '0';
   constant CSB_NOT_ACT_C         : std_logic := not CSB_ACT_C;

   type ProgArray  is array (natural range <>) of std_logic_vector(8 downto 0);

   constant PRG_IDX_DEASS_CSB_C   : natural := 0;
   constant PRG_END_DEASS_CSB_C   : natural := 0;

   constant PRG_IDX_STATUS_C      : natural := PRG_END_DEASS_CSB_C + 1;
   constant PRG_END_STATUS_C      : natural := PRG_IDX_STATUS_C    + 1;

   constant PRG_IDX_WREN_C        : natural := PRG_END_STATUS_C    + 1;
   constant PRG_END_WREN_C        : natural := PRG_IDX_WREN_C      + 2;

   constant PRG_IDX_CMD_C         : natural := PRG_END_WREN_C      + 1;

   constant PRG_END_PAGE_WR_C     : natural := PRG_IDX_CMD_C       + 3;

   constant NUM_SPI_MST_C         : natural := 2;

   constant PRG_TBL_C             : ProgArray := (
      -- can use sequence of 3 to 
      PRG_IDX_DEASS_CSB_C      =>
         ( CSB_NOT_ACT_C &  SPICMD_ONES_C      ),
      PRG_IDX_STATUS_C         =>
         ( CSB_ACT_C     &  SPICMD_RD_STATUS_C ),
      PRG_IDX_STATUS_C + 1     =>
         ( CSB_ACT_C     &  SPICMD_ONES_C      ),

      PRG_IDX_WREN_C           =>
         ( CSB_NOT_ACT_C &  SPICMD_ONES_C      ),
      PRG_IDX_WREN_C      + 1  =>
         ( CSB_ACT_C     &  SPICMD_WR_ENABLE_C ),
      PRG_IDX_WREN_C      + 2  =>
         ( CSB_NOT_ACT_C &  SPICMD_ONES_C      )
   );

   constant PRGSZ_C               : natural := PRG_TBL_C'length + 1 + 3;

   subtype  ProgIdxType is integer range -1 to PRGSZ_C     - 1;
   subtype  ProgLenType is natural range  0 to PRGSZ_C     - 1;
   subtype  CounterType is natural range  0 to PAGE_SIZE_C - 1;

   type StateType  is (IDLE, RUN_PROG, START_ERASE, ERASE, START_WRITE_PAGE, WRITE_PAGE, WAIT_PAGEWR, DONE);

   type RegType is record
      state       : StateType;
      retState    : StateType;
      cmd         : std_logic_vector(7 downto 0);
      rdDat       : std_logic_vector(7 downto 0);
      progDone    : boolean;
      wrVld       : std_logic;
      rdRdy       : std_logic;
      foeSub      : FoeSubType;
      csb         : std_logic;
      addr        : A24Type;
      laddr       : A24Type;
      idx         : ProgIdxType;
      len         : ProgLenType;
      cnt         : CounterType;
      lastSeen    : boolean;
      overrun     : boolean;
      eraseBlink  : unsigned(1 downto 0);
      writeBlink  : unsigned(3 downto 0);
      -- also provide static (non-blinking) flags
      erasing     : std_logic;
      writing     : std_logic;
      spiClaim    : std_logic;
   end record RegType;

   constant REG_INIT_C : RegType := (
      state       => IDLE,
      retState    => IDLE,
      cmd         => SPICMD_ONES_C,
      rdDat       => (others => '0'),
      progDone    => false,
      wrVld       => '0',
      rdRdy       => '0',
      foeSub      => FOE_SUB_INIT_C,
      csb         => CSB_NOT_ACT_C,
      addr        => (others => '0'),
      laddr       => (others => '0'),
      idx         => -1,
      len         => 0,
      cnt         => 0,
      lastSeen    => false,
      overrun     => false,
      eraseBlink  => (others => '0'),
      writeBlink  => (others => '0'),
      erasing     => '0',
      writing     => '0',
      spiClaim    => '0'
   );

   type SpiMuxStateType is ( IDLE, FOE, UDP );

   constant SPI_MUX_STATE_INIT_C : SpiMuxStateType := IDLE;

   signal spiMuxState   : SpiMuxStateType := SPI_MUX_STATE_INIT_C;
   signal spiMuxStateIn : SpiMuxStateType;

   procedure schedProg(
      variable   v  : inout RegType;
      constant  beg : in    natural;
      constant  trm : in    natural;
      constant  cmd : in    std_logic_vector := "";
      constant  csb : in    std_logic        := CSB_ACT_C
   ) is begin
      v           := v;
      v.idx       := beg;
      v.len       := trm;
      if ( cmd'length > 0 ) then
         v.cmd       := cmd;
      end if;
      v.csb       := csb;
      v.retState  := v.state;
      v.state     := RUN_PROG;
   end procedure schedProg;

   procedure schedStatusPoll(variable v : inout RegType; constant deass : boolean := true) is
      variable  beg : natural;
   begin
      if ( deass ) then
         beg := PRG_IDX_DEASS_CSB_C;
      else
         -- just shift ones
         beg := PRG_END_STATUS_C;
      end if;
      schedProg(v, beg, PRG_END_STATUS_C);
   end procedure schedStatusPoll;

   procedure schedDeactCS(variable v : inout RegType) is
   begin
      schedProg(v, PRG_IDX_DEASS_CSB_C, PRG_END_DEASS_CSB_C);
   end procedure schedDeactCS;

   procedure schedEraseBlock(variable v : inout RegType) is
   begin
      schedProg(v, PRG_IDX_WREN_C, PRG_END_PAGE_WR_C, SPICMD_ERASE_BLK_F);
   end procedure schedEraseBlock;
 
   procedure schedWritePage(variable v : inout RegType) is
   begin
      schedProg(v, PRG_IDX_WREN_C, PRG_END_PAGE_WR_C, SPICMD_WR_PAGE_C);
   end procedure schedWritePage;
  
   function sameBlk(constant a1, a2: A24Type) return boolean is
   begin
      return a1(a1'left downto LD_ERASE_BLK_SIZE_G) = a2(a2'left downto LD_ERASE_BLK_SIZE_G);
   end function sameBlk;


   signal r               : RegType := REG_INIT_C;
   signal rin             : RegType;

   signal rdRdy           : std_logic;
   signal wrRdy           : std_logic;
   signal rdVld           : std_logic;
   signal wrVld           : std_logic;
   signal rdDat           : std_logic_vector(7 downto 0);
   signal wrDat           : std_logic_vector(7 downto 0);
   signal csb             : std_logic;


   signal wrVldFoE        : std_logic;
   signal wrRdyFoE        : std_logic;
   signal wrDatFoE        : std_logic_vector(7 downto 0);
   signal rdVldFoE        : std_logic;
   signal rdRdyFoE        : std_logic;
   signal csbFoE          : std_logic;
   signal spiClaimFoE     : std_logic;
   signal spiGrantFoE     : std_logic;

   signal wrVldBus        : std_logic;
   signal wrRdyBus        : std_logic;
   signal wrDatBus        : std_logic_vector(7 downto 0);
   signal rdVldBus        : std_logic;
   signal rdRdyBus        : std_logic;
   signal csbBus          : std_logic;
   signal spiClaimBus     : std_logic;
   signal spiGrantBus     : std_logic;

   signal spiRst          : std_logic;

   signal foeSubLoc       : FoeSubType;
   signal busRepLoc       : Udp2BusRepType := UDP2BUSREP_INIT_C;

begin

   G_CHECK : for i in FILE_MAP_G'range generate
      assert FILE_MAP_G(i).begAddr       mod BLK_SIZE_C = 0
         report "invalid file start address"
         severity failure;
      assert (FILE_MAP_G(i).endAddr + 1) mod BLK_SIZE_C = 0
         report "invalid file end address"
         severity failure;
   end generate G_CHECK;

   assert DIV2_C > 0 report "CLOCK_FREQ_G must be >= 2*SPI_CLOCK_FREQ_G" severity failure;

   assert    ( LD_ERASE_BLK_SIZE_G = 16 )
          or ( LD_ERASE_BLK_SIZE_G = 15 )
          or ( LD_ERASE_BLK_SIZE_G = 12 )
          or ( EN_SIM_G                 )
          report "invalid flash block size" severity failure;

   debug(3 downto 0)         <= std_logic_vector( resize( to_signed( r.idx, 5 ), 4 ) );
   debug(6 downto 4)         <= toSlv( StateType'pos( r.state ), 3 );
   debug(7)                  <= r.foeSub.done;
   debug(8)                  <= foeMst.doneAck;
   debug(9)                  <= foeSubLoc.strmRdy;
   debug(10)                 <= foeMst.strmMst.valid;
   debug(11)                 <= foeMst.strmMst.last;
   debug(12)                 <= wrVld;
   debug(13)                 <= wrRdy;
   debug(14)                 <= rdVld;
   debug(15)                 <= rdRdy;
   debug(23 downto 16)       <= rdDat;
   debug(31 downto 24)       <= wrDat;
   debug(32)                 <= busReq.valid;
   debug(33)                 <= busReq.rdnwr;
   debug(34)                 <= busRepLoc.valid;
   debug(35)                 <= busRepLoc.berr;
   debug(36)                 <= spiClaimBus;
   debug(37)                 <= spiGrantBus;
   debug(38)                 <= spiClaimFoE;
   debug(39)                 <= spiGrantFoE;
   debug(41 downto 40)       <= toSlv( SpiMuxStateType'pos( spiMuxState ), 2 );
   debug(63 downto 42)       <= (others => '0');

   P_COMB : process ( r, wrRdyFoE, rdVldFoE, rdDat, foeMst, spiGrantFoE ) is
      variable v : RegType;
   begin
      v                  := r;

      foeSubLoc          <= r.foeSub;
      wrVldFoE           <= '0';
      rdRdyFoE           <= '0';
      foeSubLoc.strmRdy  <= '0';
      csbFoE             <= r.csb;

      if ( (r.wrVld and wrRdyFoE) = '1' ) then
         v.wrVld := '0';
      end if;

      if    ( r.idx < 0                 ) then
         wrDatFoE <= foeMst.strmMst.data(7 downto 0);
      elsif ( r.idx < PRG_IDX_CMD_C     ) then
         wrDatFoE <= PRG_TBL_C( r.idx )(7 downto 0);
         csbFoE   <= PRG_TBL_C( r.idx )(8);
      elsif ( r.idx = PRG_IDX_CMD_C ) then
         wrDatFoE <= r.cmd;
      elsif ( r.idx = PRG_IDX_CMD_C + 1 ) then
         wrDatFoE <= std_logic_vector( r.addr(23 downto 16) );
      elsif ( r.idx = PRG_IDX_CMD_C + 2 ) then
         wrDatFoE <= std_logic_vector( r.addr(15 downto  8) );
      elsif ( r.idx = PRG_IDX_CMD_C + 3 ) then
         wrDatFoE <= std_logic_vector( r.addr( 7 downto  0) );
      else
         wrDatFoE <= r.cmd;
      end if;

      case r.state is
         when IDLE =>
            -- wait for data
            v.lastSeen := false;
            v.overrun  := false;
            v.progDone := false;
            if ( foeMst.err = '1' ) then
               v.state := DONE;
            elsif ( foeMst.strmMst.valid = '1' ) then
               v.spiClaim := '1';
               v.addr     := FILE_MAP_G( foeMst.fileIdx ).begAddr;
               v.laddr    := FILE_MAP_G( foeMst.fileIdx ).endAddr;
               -- wait for the SPI master to become available
               if ( ( r.spiClaim and spiGrantFoE ) = '1' ) then
                  v.state    := START_ERASE;
               end if;
            end if;

         -- set csb, cmd, idx and len before entry
         when RUN_PROG =>
            wrVldFoE <= r.wrVld;
            rdRdyFoE <= r.rdRdy;
            if (  (r.rdRdy or r.wrVld)  = '0' ) then
               v.wrVld := '1';
            elsif ( (r.wrVld and wrRdyFoE) = '1' ) then
               v.wrVld := '0';
               v.rdRdy := '1';
            elsif ( (r.rdRdy and rdVldFoE) = '1' ) then
               v.rdRdy := '0';
               v.rdDat := rdDat;
               if ( r.idx = r.len ) then
                  v.progDone := true;
                  v.state    := r.retState;
               else
                  v.idx      := r.idx + 1;
               end if;
            end if;

         when START_ERASE =>
            v.erasing := '1';
            if ( not r.progDone ) then
               schedEraseBlock( v );
            else
               v.progDone := false;
               v.state    := ERASE;
            end if;

         when ERASE =>
            if ( not r.progDone ) then
               schedStatusPoll( v );
            else
               v.progDone := false;
               if ( r.rdDat(SPI_ST0_BUSY_IDX_C) = '0' ) then
                  if    ( foeMst.err = '1' ) then
                     schedDeactCS( v );
                     v.retState    := DONE;
                  elsif ( sameBlk( r.addr, r.laddr ) ) then
                     v.addr        := FILE_MAP_G( foeMst.fileIdx ).begAddr;
                     v.state       := START_WRITE_PAGE;
                     v.eraseBlink  := (others => '0');
                  else
                     v.addr        := r.addr + BLK_SIZE_C;
                     v.state       := START_ERASE;
                     v.eraseBlink  := r.eraseBlink + 1;
                  end if;
               end if;
            end if;

         when START_WRITE_PAGE =>
            v.erasing := '0';
            v.writing := '1';
            if ( not r.progDone ) then
               schedWritePage( v );
            else
               v.progDone := false;
               v.cnt      := PAGE_SIZE_C - 1;
               v.idx      := -1;
               v.state    := WRITE_PAGE;
            end if;

         -- assume CSB is asserted already
         when WRITE_PAGE =>
            rdRdyFoE <= r.rdRdy;
            if ( r.rdRdy = '0' ) then
               if ( foeMst.err = '1' ) then
                  schedDeactCS( v );
                  v.retState := DONE;
               else
                  -- take the next byte to the SPI module
                  wrVldFoE           <= foeMst.strmMst.valid;
                  foeSubLoc.strmRdy  <= wrRdyFoE;
                  if ( ( foeMst.strmMst.valid and wrRdyFoE ) = '1' ) then
                     -- it has been accepted; now wait for the reply
                     v.rdRdy    := '1';
                     v.lastSeen := (foeMst.strmMst.last = '1');
                  end if;
               end if;
            elsif ( rdVldFoE = '1' ) then
               v.rdRdy    := '0';
               v.state    := WAIT_PAGEWR;
               v.progDone := false;
               if ( ( r.addr = r.laddr ) or r.lastSeen ) then
                   if ( not r.lastSeen ) then
                      -- end of the write area reached but there are more data
                      v.overrun  := true;
                      v.lastSeen := true;
                   end if;
               else
                   v.addr := r.addr + 1;
                   if ( r.cnt /= 0 ) then
                      v.cnt   := r.cnt - 1;
                      -- keep copying
                      v.state := r.state;
                   end if;
               end if;
            end if;

         when WAIT_PAGEWR =>
            if ( not r.progDone ) then
               schedStatusPoll( v );
            else
               v.progDone := false;
               if ( r.rdDat(SPI_ST0_BUSY_IDX_C) = '0' ) then
                  if ( r.lastSeen or ( foeMst.err = '1' ) ) then
                     if ( r.overrun ) then
                        v.foeSub.abort := '1';
                     end if;
                     schedDeactCS( v );
                     v.retState    := DONE;
                  else
                     v.state       := START_WRITE_PAGE;
                     v.writeBlink  := r.writeBlink + 1;
                  end if;
               end if;
            end if;

         when DONE =>
            v.erasing    := '0';
            v.writing    := '0';
            v.spiClaim   := '0';
            v.eraseBlink := (others => '0');
            v.writeBlink := (others => '0');
            if ( (not r.foeSub.done and not foeMst.fifoRst) = '1' ) then
               v.foeSub.done  := '1';
            elsif ( (r.foeSub.done and foeMst.doneAck) = '1' ) then
               v.foeSub.done  := '0';
               v.foeSub.abort := '0';
               v.state        := IDLE;
            end if;
      end case;

      rin <= v;
   end process P_COMB;

   P_SEQ : process ( clk ) is
   begin
      if ( rising_edge( clk ) ) then
         if ( rst = '1' ) then
            r             <= REG_INIT_C;
            spiMuxState   <= SPI_MUX_STATE_INIT_C;
         else
            r             <= rin;
            spiMuxState   <= spiMuxStateIn;
         end if;
      end if;
   end process P_SEQ;

   U_BUS2SPI : entity work.Bus2SpiFlashIF
      generic map (
         LD_PAGE_SIZE_G => LD_BUS_PAGE_SIZE_G
      )
      port map (
         clk     => clk,
         rst     => spiRst,

         busReq  => busReq,
         busRep  => busRepLoc,

         spiReq  => spiClaimBus,
         spiGnt  => spiGrantBus,

         spiVldI => wrVldBus,
         spiDatI => wrDatBus,
         spiCsel => csbBus,
         spiRdyI => wrRdyBus,

         spiDatO => rdDat,
         spiVldO => rdVldBus,
         spiRdyO => rdRdyBus
      );

   U_SPI : entity work.SpiBitShifter
      generic map (
         DIV2_G => DIV2_C
      )
      port map (
         clk     => clk,
         rst     => spiRst,

         datInp  => wrDat,
         csbInp  => csb,
         vldInp  => wrVld,
         rdyInp  => wrRdy,

         datOut  => rdDat,
         vldOut  => rdVld,
         rdyOut  => rdRdy,

         serClk  => sclk,
         serInp  => miso,
         serOut  => mosi,
         serCsb  => scsb
      );

   P_SPI_MUX : process (
      spiMuxState,
      spiClaimFoE, spiClaimBus,
      wrVldFoE, wrDatFoE, csbFoE, rdRdyFoE,
      wrVldBus, wrDatBus, csbBus, rdRdyBus,
      wrRdy, rdVld
   ) is
      variable v : SpiMuxStateType;
   begin
      v             := spiMuxState;

      wrDat         <= wrDatFoE;
      csb           <= CSB_NOT_ACT_C;
      wrVld         <= '0';
      rdRdy         <= '0';

      wrRdyFoE      <= '0';
      wrRdyBus      <= '0';
      rdVldFoE      <= '0';
      rdVldBus      <= '0';

      spiGrantFoE   <= '0';
      spiGrantBus   <= '0';

      case ( v ) is
         when IDLE =>
            if    ( spiClaimFoE = '1' ) then
               v := FOE;
            elsif ( spiClaimBus = '1' ) then
               v := UDP;
            end if;
         when FOE =>
            if ( spiClaimFoE = '0' ) then
               v := IDLE;
            end if;
         when UDP =>
            if ( spiClaimBus = '0' ) then
               v := IDLE;
            end if;
      end case;

      if    ( v = FOE ) then
         spiGrantFoE <= spiClaimFoE;
         wrVld       <= wrVldFoE;
         wrRdyFoe    <= wrRdy;
         csb         <= csbFoE;
         rdVldFoE    <= rdVld;
         rdRdy       <= rdRdyFoE;
      elsif ( v = UDP ) then
         spiGrantBus <= spiClaimBus;
         wrDat       <= wrDatBus;
         wrVld       <= wrVldBus;
         wrRdyBus    <= wrRdy;
         csb         <= csbBus;
         rdVldBus    <= rdVld;
         rdRdy       <= rdRdyBus;
      end if;
      
      spiMuxStateIn <= v;
   end process P_SPI_MUX;

   spiClaimFoe <= r.spiClaim;

   foeSub      <= foeSubLoc;
   spiRst      <= rst;
   busRep      <= busRepLoc;

   progress(3) <= r.writing;
   progress(2) <= r.erasing;
   progress(1) <= r.writeBlink(r.writeBlink'left);
   progress(0) <= r.eraseBlink(r.eraseBlink'left);

end architecture Impl;