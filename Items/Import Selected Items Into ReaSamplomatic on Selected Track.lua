-- @description Import Selected Items Into ReaSamplomatic on Selected Track
-- @author Analogmad, MPL, modification by Stephen Schappler
-- @version 1.0
-- Initial Script by MPL Modified by Analogmad (Chris Kowalski), and further modified by Stephen Schappler
-- From Analogmad: MPL Helped me with this via the Reaper Forums. I had an issue of putting all samples into one RS5K. Added Arming for Audio Recording. Added Velocity Randomizer
-- From Stephen Schappler: I changed the MIDI Velcotiy randomizer this script uses (it now uses one I wrote for this purpose), as well as the actions used to render items to a new takes before and after getting loaded into the sampler
-- @about
--   Import Selected Items Into ReaSamplomatic on Selected Track
-- @link https://www.stephenschappler.com
-- @changelog 
--   9/3/24 v1.0 - Adding script to ReaPack

local script_title = 'Import Selected Items into ReaSamplomatic on Selected Track'
-------------------------------------------------------------------------------    
function GetRS5kID(tr)
local id = -1
for i = 1, reaper.TrackFX_GetCount(tr) do
  if ({reaper.TrackFX_GetFXName(tr, i-1, '')})[2]:find('RS5K') then return i-1 end
end
return id
end
------------------------------------------------------------------------------- 
function GetMidiToolID(tr)
local id = -1
for i = 1, reaper.TrackFX_GetCount(tr) do
  local fxName = ({reaper.TrackFX_GetFXName(tr, i-1, '')})[2]
  if fxName:find('Randomize') then return i-1 end
end
return id
end
------------------------------------------------------------------------------- 
function ExportSelItemsToRs5k(track)   
local number_of_samples = reaper.CountSelectedMediaItems(0)

  -- Get the index of MIDI randomizer plugin
local miditool_pos = GetMidiToolID(track)

  -- Add the MIDI Randomizer JS if it doesn't exist
if miditool_pos == -1 then
  miditool_pos = reaper.TrackFX_AddByName(track, 'MIDI Randomize Note Velocity', false, -1)
end
--]]

-- Get the index of the ReaSamplOmatic5000 plugin
local rs5k_pos = GetRS5kID(track)

-- Add the ReaSamplOmatic5000 plugin if it doesn't exist
if rs5k_pos == -1 then
  rs5k_pos = reaper.TrackFX_AddByName(track, 'ReaSamplOmatic5000 (Cockos)', false, -1)
end

-- Iterate through samples and add them to the same ReaSamplOmatic5000 instance
for i = 1, number_of_samples do
  local item = reaper.GetSelectedMediaItem(0, i-1)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then goto skip_to_next_item end
  
  local tk_src = reaper.GetMediaItemTake_Source(take)
  local filename = reaper.GetMediaSourceFileName(tk_src, '')
  
  --reaper.TrackFX_SetParam(track, midirand_pos, 1, number_of_samples) -- setting amount of samples in sampler in velocity Generator
  reaper.TrackFX_SetParamNormalized(track, rs5k_pos, 3, 0) -- note range start
  reaper.TrackFX_SetParamNormalized(track, rs5k_pos, 8, .17) -- max voices = 12
  reaper.TrackFX_SetParamNormalized(track, rs5k_pos, 9, 0) -- attack
  reaper.TrackFX_SetParamNormalized(track, rs5k_pos, 11, 1) -- obey note offs
  reaper.TrackFX_SetNamedConfigParm(track, rs5k_pos, "FILE"..(i-1), filename)
  ::skip_to_next_item::
end
if rs5k_pos then reaper.TrackFX_SetNamedConfigParm(track, rs5k_pos, "DONE","") end
end

-------------------------------------------------------------------------------  
function main(track)   
-- track check
  local track = reaper.GetSelectedTrack(0,0)
  if not track then return end
  
-- item check
  local item = reaper.GetSelectedMediaItem(0,0)
  if not item then return true end        
 
-- render items to new take
reaper.Main_OnCommand(41999,0)

-- export to RS5k
  ExportSelItemsToRs5k(track) 
  MIDI_prepare(track)

-- go back to first take
reaper.Main_OnCommand(reaper.NamedCommandLookup("_XENAKIOS_SELECTFIRSTTAKEOFITEMS"), 0)    

-- crop to active take in items, so we don't see the extra take created for rendering and exporting to the sampler
reaper.Main_OnCommand(40131,0)

-- close the fx windows so we don't have to have them open
reaper.Main_OnCommand(reaper.NamedCommandLookup("_S&M_WNCLS5"), 0)    
end
------------------------------------------------------------------------------- 
function MIDI_prepare(tr)
  local bits_set=tonumber('111111'..'00000',2)
  reaper.SetMediaTrackInfo_Value( tr, 'I_RECINPUT', 4096+bits_set ) -- set input to all MIDI
  reaper.SetMediaTrackInfo_Value( tr, 'I_RECMON', 1) -- monitor input
  reaper.SetMediaTrackInfo_Value( tr, 'I_RECARM', 1) -- arm track
  reaper.SetMediaTrackInfo_Value( tr, 'I_RECMODE',1) -- record STEREO out
end

-------------------------------------------------------------------------------  

reaper.Undo_BeginBlock()
main()  
reaper.Undo_EndBlock(script_title, 1)