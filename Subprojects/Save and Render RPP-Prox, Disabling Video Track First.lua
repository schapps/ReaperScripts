-- @description Save and Render RPP Prox, Disabling Video Track Send First
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   This is a simple script to save subprojects, while ensuring any audio from video tracks are muted first.
-- @link https://www.stephenschappler.com
-- @changelog 
--   8/23/24 - v1.0 - Creating the script
--   2/11/25 - v1.01 - Fixing the description typo

-- Function to perform a case-insensitive search for a keyword in a string
local function string_contains(str, keyword)
    return string.lower(str):find(string.lower(keyword), 1, true) ~= nil
  end
  
  -- Function to find and disable the master parent send of tracks containing "video" (case-insensitive)
  local function disable_master_parent_send()
    local tracks = reaper.CountTracks(0)
    local track_states = {}  -- To store the initial state of master parent sends
  
    for i = 0, tracks - 1 do
      local track = reaper.GetTrack(0, i)
      local track_name = ""
      _, track_name = reaper.GetTrackName(track, track_name)
      
      if string_contains(track_name, "video") then
        -- Check the current state of the master parent send
        local is_enabled = reaper.GetMediaTrackInfo_Value(track, "B_MAINSEND")
        track_states[track] = is_enabled  -- Save the state
        
        -- Disable the master parent send
        reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0)
      end
    end
    
    return track_states
  end
  
  -- Function to re-enable the master parent send of tracks containing "video" (case-insensitive)
  local function reenable_master_parent_send(track_states)
    for track, was_enabled in pairs(track_states) do
      if was_enabled == 1 then
        reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 1)
      end
    end
  end
    
    -- Disable master parent sends for tracks named "video" and save track states
    local track_states = disable_master_parent_send()
    
    -- Execute the action to save and render the project as RPP-prox
    reaper.Main_OnCommand(reaper.NamedCommandLookup("42332"), 0)
    
    -- Re-enable the master parent sends for tracks named "video" if they were enabled
    reenable_master_parent_send(track_states)
    