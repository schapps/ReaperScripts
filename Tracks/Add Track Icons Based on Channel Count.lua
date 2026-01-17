-- @description Add track icons based on channel count
-- @author Stephen Schappler
-- @version 1.1
-- @about
--   Sets track icons for tracks with 4 or 6 channels using icons in
--   REAPER's Data/track_icons folder.
-- @link https://www.stephenschappler.com
-- @changelog 
--   1/8/2026 Adding Script


local function set_icon_for_track(track, icon_name)
  local resource = reaper.GetResourcePath()
  local icon_path = resource .. "/Data/track_icons/" .. icon_name
  reaper.GetSetMediaTrackInfo_String(track, "P_ICON", icon_path, true)
end

local function get_icon_path(track)
  local _, icon_path = reaper.GetSetMediaTrackInfo_String(track, "P_ICON", "", false)
  return icon_path
end

local function clear_icon_for_track(track)
  reaper.GetSetMediaTrackInfo_String(track, "P_ICON", "", true)
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local resource = reaper.GetResourcePath()
local quad_icon = resource .. "/Data/track_icons/Quad Channels.png"
local surround_icon = resource .. "/Data/track_icons/Surround Channels.png"

local track_count = reaper.CountTracks(0)
for i = 0, track_count - 1 do
  local track = reaper.GetTrack(0, i)
  local chans = reaper.GetMediaTrackInfo_Value(track, "I_NCHAN")
  if chans == 4 then
    set_icon_for_track(track, "Quad Channels.png")
  elseif chans == 6 then
    set_icon_for_track(track, "Surround Channels.png")
  else
    local icon_path = get_icon_path(track)
    if icon_path == quad_icon or icon_path == surround_icon then
      clear_icon_for_track(track)
    end
  end
end

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Add track icons to quad and surround tracks", -1)
