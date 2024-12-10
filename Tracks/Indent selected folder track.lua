-- @description Indent selected folder track
-- @author Stephen Schappler and Chris Kokkinos
-- @version 1.0
-- @about
--   Script for Chris
-- @link https://www.stephenschappler.com
-- @changelog 
--   12/10/2024 v 1.0 Creating the script

-- Select children of selected folder tracks
command_id = reaper.NamedCommandLookup("_SWS_SELCHILDREN2")
reaper.Main_OnCommand(command_id,0)

-- Save current track selection
command_id = reaper.NamedCommandLookup("_SWS_SAVESEL")
reaper.Main_OnCommand(command_id,0)

-- Select parent of selected folder tracks
command_id = reaper.NamedCommandLookup("_SWS_SELPARENTS2")
reaper.Main_OnCommand(command_id,0)

-- Indent selected tracks
command_id = reaper.NamedCommandLookup("_SWS_INDENT")
reaper.Main_OnCommand(command_id,0)

-- Restore track selection
command_id = reaper.NamedCommandLookup("_SWS_RESTORESEL")
reaper.Main_OnCommand(command_id,0)

-- Go to previous track, leaving other tracks selected
reaper.Main_OnCommand(40286, 0)

-- Make folder from selected tracks
command_id = reaper.NamedCommandLookup("_SWS_MAKEFOLDER")
reaper.Main_OnCommand(command_id,0)


