-- @description Solo and Play Selected Item(s)
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Solo items selected items
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/29/24 Creating the script

-- Solo selected items
reaper.Main_OnCommand(41559, 0) 

-- Play selected items once using SWS extension command
reaper.Main_OnCommand(reaper.NamedCommandLookup("_XENAKIOS_TIMERTEST1"), 0)

-- Unsolo all items
reaper.Main_OnCommand(41185, 0)     