-- @description Save and Render RPP Prox, Disabling Video Track Send First
-- @author Stephen Schappler
-- @version 1.03
-- @about
--   This is a simple script to save subprojects, while ensuring any audio from video tracks are muted first.
-- @link https://www.stephenschappler.com
-- @changelog 
--   8/23/24 - v1.0 - Creating the script
--   2/11/25 - v1.01 - Fixing the description typo
--   4/16/25 - v1.02 - Making it so that the subproject's parent project is activated after saving.
--   10/3/25 - v1.03 - Disabling the return to parent project function until I can debug it better, as it will fail often.

local function string_contains(str, keyword)
  return string.lower(str):find(string.lower(keyword), 1, true) ~= nil
end

local function disable_master_parent_send()
  local tracks = reaper.CountTracks(0)
  local track_states = {}

  for i = 0, tracks - 1 do
    local track = reaper.GetTrack(0, i)
    local _, track_name = reaper.GetTrackName(track, "")
    
    if string_contains(track_name, "video") then
      local is_enabled = reaper.GetMediaTrackInfo_Value(track, "B_MAINSEND")
      track_states[track] = is_enabled
      reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0)
    end
  end
  
  return track_states
end

local function reenable_master_parent_send(track_states)
  for track, was_enabled in pairs(track_states) do
    if was_enabled == 1 then
      reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 1)
    end
  end
end

-- Function to return to the parent project
local function escape_pattern(str)
  return str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

local function return_to_parent_project()
  local current_proj_file = reaper.GetProjectName(0, "", 512)
  if not current_proj_file or current_proj_file == "" or current_proj_file == "untitled project" then
    reaper.ShowMessageBox("This subproject hasn't been saved yet — please save it first!", "Error", 0)
    return
  end

  -- Extract just the base filename (no path)
  local subproj_filename = current_proj_file:match("([^\\/]+)$"):lower()
  local escaped_filename = escape_pattern(subproj_filename)

  local proj_idx = 0
  local found_parent = false

  while true do
    local proj, proj_fn = reaper.EnumProjects(proj_idx, "")
    if not proj then break end

    if proj ~= 0 and proj ~= reaper.EnumProjects(-1, "") then
      local file = io.open(proj_fn, "r")
      if file then
        local contents = file:read("*all"):lower()
        file:close()

        -- Proper Lua pattern matching now!
        local pattern = '<source rpp_project.-file%s-"[^"]-' .. escaped_filename .. '"'
        if contents:find(pattern) then
          reaper.SelectProjectInstance(proj)
          found_parent = true
          break
        end
      end
    end

    proj_idx = proj_idx + 1
  end

  if not found_parent then
    reaper.ShowMessageBox("The subproject's parent project cannot be found. Is it open?", "Error", 0)
  end
end


-- Main execution
reaper.Undo_BeginBlock()

local track_states = disable_master_parent_send()
reaper.Main_OnCommand(reaper.NamedCommandLookup("42332"), 0) -- Save and render RPP-PROX
reenable_master_parent_send(track_states)

-- Return to parent
-- return_to_parent_project()

reaper.Undo_EndBlock("Save and Render RPP Prox with Parent Return", -1)
