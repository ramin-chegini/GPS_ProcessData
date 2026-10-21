----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 09/25/2025 10:16:00 AM
-- Design Name: 
-- Module Name: GPS_Data_Proc - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: Receive GPS UART bytes, recognize RMC time fields, and buffer
--              a delayed byte stream for the DSP clock domain. Filter the
--              external PPS input separately in two destination clock domains.
-- 
-- Dependencies: uart_paritycheck_gps, Debounce_v2 (DebounceRise2.vhd),
--               UART_FIFO IP, and UNISIM FDCE primitives.
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all ;
use ieee.std_logic_arith.all ;
use ieee.std_logic_unsigned.all ;
use ieee.std_logic_misc.all ;
library unisim;
use unisim.vcomponents.all;

entity GPS_Data_Proc is
    -- These defaults override the standalone UART defaults: 20 MHz, 9600 8N1.
    -- The surrounding byte registers and FIFO require d_width = 8.
        GENERIC
            (
            clk_freq  :  INTEGER    := 20_000_000;  --frequency of system clock in Hertz
            baud_rate :  INTEGER    := 9_600;       --data link baud rate in bits/second
            os_rate   :  INTEGER    := 16;          --oversampling rate to find center of receive bits (in samples per baud period)
            d_width   :  INTEGER    := 8;           --data bus width
            parity    :  INTEGER    := 0;           --0 for no parity, 1 for parity
            parity_eo :  STD_LOGIC  :='0'          --'0' for even, '1' for odd parity
            );        
    -- reset is active high. UART_Clk must match the clk_freq generic.
    -- FIFO writes and GPS_TIME updates use UART_Clk; FIFO reads use clk_dsp.
    -- GPS_TIME holds six ASCII characters (HHMMSS), not a binary timestamp.
    Port ( 
            reset                : in STD_LOGIC;
            UART_Clk             : in STD_LOGIC;
            clk_dsp              : in STD_LOGIC;
            ADC_SamplingClk      : in STD_LOGIC;
            GPS_PPS_1s           : in STD_LOGIC;
            GPS_PPS_1s_Debunced_Elint  : out STD_LOGIC;
            GPS_PPS_1s_Debunced_Comint  : out STD_LOGIC;
            GPS_rx               : in STD_LOGIC;
            GPS_buf_rd_en        : in STD_LOGIC;
            GPS_frame_tick_O     : out STD_LOGIC;
            GPS_buf_full_O       : out STD_LOGIC;
            GPS_buf_data         : out std_logic_vector(7 downto 0);
            GPS_TIME             : out std_logic_vector(47 downto 0)
        );
end GPS_Data_Proc;

architecture Behavioral of GPS_Data_Proc is

signal GPS_frame_tick,GPS_frame_PPS,GPS_frame_tick_int1,Clear,GPS_frame_tick_Rst,GPS_buf_full,GPS_frame_tick_int2 :std_logic:='0';
signal GPS_rx_data  :std_logic_vector(7 downto 0); 
signal GPS_rd :std_logic:='0';
signal GPS_rx_error :std_logic:='0'; 
signal GPS_rx_full ,GPS_rx_full_d1 :std_logic:='0';
-- Index 0 holds the newest accepted byte; higher indices hold older bytes.
-- Index 18 feeds the FIFO, while indices 17..5 supply header/time matching.
type GPS_array is  array (0 to 20) of std_logic_vector(7 downto 0);
signal GPS_Reg_data :  GPS_array; 
signal GPS_rx_empty,uld_rx_data ,rx_busy_out ,GPS_buf_WRen,GPS_buf_empty  :  std_logic ;
   
COMPONENT UART_FIFO
      PORT (
        rst : IN STD_LOGIC;
        wr_clk : IN STD_LOGIC;
        rd_clk : IN STD_LOGIC;
        din : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
        wr_en : IN STD_LOGIC;
        rd_en : IN STD_LOGIC;
        dout : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        full : OUT STD_LOGIC;
        empty : OUT STD_LOGIC;
        rd_data_count : OUT STD_LOGIC_VECTOR(8 DOWNTO 0);
        wr_data_count : OUT STD_LOGIC_VECTOR(8 DOWNTO 0);
--        prog_full : OUT STD_LOGIC;
        wr_rst_busy : OUT STD_LOGIC;
        rd_rst_busy : OUT STD_LOGIC
      );
    END COMPONENT;  
    
begin
  
-- Filter the physical PPS level independently in each consumer clock domain.
-- WaitCnt = 10 is measured in local clock counts, not milliseconds.
ElintPPS_Debounce : entity work.Debounce_v2 
    port  map
        ( 
            din     => GPS_PPS_1s,
            clk     => ADC_SamplingClk,
            rst     => reset,
            WaitCnt => x"0A",
            dout    => GPS_PPS_1s_Debunced_Elint
        );  
        
ComintPPS_Debounce : entity work.Debounce_v2 
    port  map
        ( 
            din     => GPS_PPS_1s,
            clk     => clk_dsp,
            rst     => reset,
            WaitCnt => x"0A",
            dout    => GPS_PPS_1s_Debunced_Comint
        );          
  
  
  -- Independent-clock, 8-bit, 512-entry FIFO supplied by IP/UART_FIFO.xcix.
  -- The reader controls rd_en externally; empty is not exported by this top.
  -- Count and reset-busy outputs are declared above but left unmapped here.
  Ins_GPS_UART_FIFO : UART_FIFO
    port map 
        (
            rst         => reset,
            
            wr_clk      => UART_Clk,
            din         => GPS_Reg_data(18),
            wr_en       => uld_rx_data, 
           
            rd_clk      => clk_dsp,
            rd_en       => GPS_buf_rd_en,
            dout        => GPS_buf_data,
            full        => GPS_buf_full,
            empty       => GPS_buf_empty
        );
 
GPS_buf_full_O   <= GPS_buf_full;
GPS_frame_tick_O <= GPS_frame_tick_int2;
       
-- This integration receives only; the reusable UART transmitter is disabled.
Inst_GPS_uart : entity Work.uart_paritycheck_gps
  GENERIC map(
    clk_freq   => clk_freq,         --! frequency of system clock in Hertz
    baud_rate  => baud_rate,        --! data link baud rate in bits/second
    os_rate    => os_rate,          --! oversampling rate to find center of receive bits (in samples per baud period)
    d_width    => d_width,          --! data bus width
    parity     => parity,           --! 0 for no parity, 1 for parity
    parity_eo  => parity_eo )       --! '0' for even, '1' for odd parity
  PORT map(
    clk      => UART_Clk,                --! system clock
    reset    => reset ,            --! ascynchronous reset
    
    tx_ena   => '0',                --! initiate transmission
    tx_data  => (others => '0'),            --! data to transmit
    tx_busy  => open,            --! transmission in progress
    tx       => open,                 --! transmit pin
        
    rx       => GPS_rx,                 --! receive pin
    rx_busy  => open,            --! data reception in progress
    rx_ena   => GPS_rx_full,            --! data reception completed
    rx_error => GPS_rx_error,           --! start, parity, or stop bit error detected
    rx_data  => GPS_rx_data             --! data received
    );	 
    
 -- Shift history only on GPS_rd, so positions are measured in accepted bytes.
 gps_reg_gen: for i in 0 to 19 generate
            begin
                process(UART_Clk,reset)
                    begin    
                        if (reset='1') then
                              GPS_Reg_data(i+1) <= (others =>'0');
                        elsif rising_edge(UART_Clk) then
                            if (GPS_rd='1') then
                                 GPS_Reg_data(i+1)    <=GPS_Reg_data(i);  
                          end if;
                        end if;
                    end process; 
      end generate gps_reg_gen;    
  process(UART_Clk,reset)
          begin    
              if (reset='1') then
                    GPS_rd                 <= '0';
                    GPS_Reg_data(0) <= (others =>'0');
                    GPS_TIME <= (others =>'0');
                    GPS_frame_PPS <= '0'; 
                    GPS_frame_tick <= '0';   
                    GPS_buf_WRen <= '0';
              elsif rising_edge(UART_Clk) then
              
                  -- rx_ena can span multiple UART clocks. Accept its rising
                  -- edge only when the UART reports no framing/parity error.
              	   GPS_rx_full_d1 <= GPS_rx_full; 
                  if (GPS_rx_full_d1 = '0' and GPS_rx_full='1' and GPS_rx_error='0' ) then 
                      GPS_rd <= '1';
                  else
                      GPS_rd                 <= '0';
                  end if;
                  -- Signal assignments use the previous GPS_rd value; this
                  -- load and the generated history shift occur together.
                  if (GPS_rd='1') then
                    GPS_Reg_data(0)   <= GPS_rx_data;    
                  end if;
                  
                  -- Exact "$GNRMC," match drives the frame-event latch below.
                  -- GPS_frame_PPS is derived from text, not the PPS input pin.
                  if(GPS_Reg_data(17) = X"24" and GPS_Reg_data(16)= X"47" and GPS_Reg_data(15)= X"4E"  and GPS_Reg_data(14)= X"52" and GPS_Reg_data(13)= X"4D" and GPS_Reg_data(12)= X"43" and GPS_Reg_data(11)= X"2C") then -- and GPS_Reg_data(1)= X"2C" and GPS_Reg_data(0)= X"41" ) then
                        GPS_frame_PPS <= '1';
                  else
                        GPS_frame_PPS <= '0';                          
                  end if;                  
                  -- Time/capture matching accepts "$G?RMC,": index 15 is
                  -- not tested by the existing expression.
                  -- Copy fixed HHMMSS byte positions without digit, status,
                  -- field-length, or NMEA checksum validation.
                  if(GPS_Reg_data(17) = X"24" and GPS_Reg_data(16)= X"47"  and GPS_Reg_data(14)= X"52" and GPS_Reg_data(13)= X"4D" and GPS_Reg_data(12)= X"43" and GPS_Reg_data(11)= X"2C") then -- and GPS_Reg_data(1)= X"2C" and GPS_Reg_data(0)= X"41" ) then
--                  if(GPS_Reg_data(17) = X"24" and GPS_Reg_data(16)= X"47" and GPS_Reg_data(15)= X"4E" and GPS_Reg_data(14)= X"52" and GPS_Reg_data(13)= X"4D" and GPS_Reg_data(12)= X"43" and GPS_Reg_data(11)= X"2C") then -- and GPS_Reg_data(1)= X"2C" and GPS_Reg_data(0)= X"41" ) then
                        GPS_frame_tick <= '1';
                        GPS_TIME <= GPS_Reg_data(10) & GPS_Reg_data(9) &  GPS_Reg_data(8) & GPS_Reg_data(7)&GPS_Reg_data(6) & GPS_Reg_data(5) ;
                  else
                        GPS_frame_tick <= '0';                          
                  end if;
                  -- Arm capture on a time match while the FIFO is empty.
                  -- Capture stays armed until full; sentence endings do not
                  -- terminate it. empty originates in the FIFO read domain.
                  if (GPS_frame_tick = '1' and GPS_buf_empty='1') then 
                      GPS_buf_WRen <= '1';
                  elsif (GPS_buf_full='1') then 
                      GPS_buf_WRen <= '0';
                  end if;
                  -- Register the byte write request; FIFO din is history[18].
                  if (GPS_buf_WRen = '1') then
                        uld_rx_data <= GPS_rd;
                  else
                        uld_rx_data <= '0';
                  end if;
              end if;
          end process;      
--  uld_rx_data <= GPS_rd when GPS_buf_WRen='1' else '0';   
------------------------------------------------------------------------------------
------------------------------------------------------------------------------------
-- Existing event-transfer circuit: a rising text match clocks a sticky latch.
-- clk_dsp samples it, then a delayed acknowledgement clears the first two
-- registers asynchronously. This is separate from physical PPS filtering.
FDCE_inst : FDCE
   generic map (
      INIT => '0') -- Initial value of register ('0' or '1')  
   port map (
      Q => GPS_frame_tick_int1,      -- Data output
      C => GPS_frame_PPS,      -- Clock input
      CE => '1',    -- Clock enable input
      CLR => Clear,  -- Asynchronous clear input
      D => '1'       -- Data input
   );
   
Clear <= reset or GPS_frame_tick_Rst;

FDCE_inst2 : FDCE
   generic map (
      INIT => '0') -- Initial value of register ('0' or '1')  
   port map (
      Q => GPS_frame_tick_int2,      -- Data output
      C => clk_dsp,      -- Clock input
      CE => '1',    -- Clock enable input
      CLR => Clear,  -- Asynchronous clear input
      D => GPS_frame_tick_int1       -- Data input
   );
FDCE_inst3 : FDCE
   generic map (
      INIT => '0') -- Initial value of register ('0' or '1')  
   port map (
      Q => GPS_frame_tick_Rst,      -- Data output
      C => clk_dsp,      -- Clock input
      CE => '1',    -- Clock enable input
      CLR => reset,  -- Asynchronous clear input
      D => GPS_frame_tick_int2       -- Data input
   );             
             
end Behavioral;
