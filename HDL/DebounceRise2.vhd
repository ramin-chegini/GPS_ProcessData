-- File: DebounceRise2.vhd; active entity: Debounce_v2.
-- Filter both input transitions by requiring a stable sampled level before
-- updating dout. The output is a filtered level, not a one-clock edge pulse.
-- WaitCnt is an 8-bit threshold in clk counts; rst is active high.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity Debounce_v2 is
--    generic
--        (
--        WaitCnt : integer := 5*40*1000 -- = wait(s) * clk freq.(Hz) = 5 ms by 40Mhz Clk < 2^24
--        );
    port 
        ( 
        din     : in std_logic;
        clk     : in std_logic;
        rst     : in std_logic;
        WaitCnt : in std_logic_vector(7 downto 0);
        dout    : out std_logic
        );
end Debounce_v2;

architecture bh of Debounce_v2 is

    signal cntr : std_logic_vector(25 downto 0);
    -- Previous sample used for change detection, not a two-stage synchronizer.
    signal DinD1 : std_logic;

begin

    process(clk,din,rst)
    begin
        if (rst = '1' ) then
            DinD1 <= '0';
            cntr <= (others => '0');
            dout <= '0';
        elsif rising_edge(clk) then
            DinD1 <= din;
            -- Any change restarts the stability interval. Hold dout while
            -- counting, then retain the saturated count until another change.
            if DinD1 /= din then
                cntr <= (others => '0');
            else
                -- Comparison precedes increment: after a detected transition,
                -- WaitCnt = 10 updates dout on the 11th unchanged comparison.
                if cntr >= WaitCnt then 
                    dout <= din;
                else
                    cntr <= cntr + 1;
                end if;
            end if;
        end if; 
    end process;

end bh;


-- Historical alternative implementation below is entirely commented out.
-- It is retained as supplied and does not participate in the active design.
--library IEEE;
--use IEEE.STD_LOGIC_1164.ALL;
--use IEEE.STD_LOGIC_ARITH.ALL;
--use IEEE.STD_LOGIC_UNSIGNED.ALL;

--entity Debounce_v2 is
--    generic
--        (
--        WaitCnt : integer := 5*40*1000 -- = wait(s) * clk freq.(Hz) = 5 ms by 40Mhz Clk < 2^24
--        );
--    port 
--        ( 
--        din : in std_logic;
--        rst : in std_logic;
--        clk : in std_logic;
--        dout : out std_logic
--        );
--end Debounce_v2;

--architecture bh of Debounce_v2 is

--    signal cntr : std_logic_vector(25 downto 0);
--    signal DinD1 : std_logic;


--   type state_type is (st_On, st_On2Off,st_Off,st_Off2on); 
--   signal state, next_state : state_type; 
--   signal dout_i : std_logic;  -- example output signal
-- begin
--   SYNC_PROC: process (clk)
--   begin
--      if (clk'event and clk = '1') then
--         if (rst = '1') then
--            state <= st_off;
--            dout <= '0';
--         else
--            state <= next_state;
--            dout <= dout_i;
--         end if;        
--      end if;
--   end process;
	
--   SYNC_PROC_2: process (rst,clk,rst)
--   begin
--		if (rst = '1') then
--			cntr <= (others => '0');
--      elsif (clk'event and clk = '1') then
--         if state = st_on2off or state = st_off2on then
--				cntr <= cntr + '1';	
--			else
--				cntr <= (others => '0');
--			end if;
--      end if;
--   end process; 
--   --MOORE State-Machine - Outputs based on state only
--   OUTPUT_DECODE: process (state)
--   begin
--      if state = st_on then
--         dout_i <= '1';
--      elsif state = st_off then
--         dout_i <= '0';
--      end if;
--   end process;
 
--   NEXT_STATE_DECODE: process (state, din, cntr)
--   begin
--      next_state <= state;  
--      case (state) is
--         when st_on =>
--            if din = '0' then
--               next_state <= st_on2off;
--            end if;
--         when st_on2off =>
--            if din = '1' then
--               next_state <= st_on;
--				elsif cntr >= WaitCnt then
--					next_state <= st_off;
--            end if;
--         when st_off =>
--            if din = '1' then
--               next_state <= st_off2on;
--            end if;
--         when st_off2on =>
--            if din = '0' then
--               next_state <= st_off;
--				elsif cntr >= WaitCnt then
--					next_state <= st_on;
--            end if;				
--         when others =>
--            next_state <= st_off;
--      end case;      
--   end process;


--end bh;
