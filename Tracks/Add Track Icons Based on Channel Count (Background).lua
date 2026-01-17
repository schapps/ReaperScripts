-- @description Add track icons based on channel count (Background)
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Runs in the background and updates track icons when track channel
--   counts change or tracks are added.
-- @link https://www.stephenschappler.com
-- @changelog 
--   1/8/2026 Adding Script


local resource = reaper.GetResourcePath()
local quad_icon = resource .. "/Data/track_icons/Quad Channels.png"
local surround_icon = resource .. "/Data/track_icons/Surround Channels.png"

local function get_icon_path(track)
  local _, icon_path = reaper.GetSetMediaTrackInfo_String(track, "P_ICON", "", false)
  return icon_path
end

local function set_icon_path(track, icon_path)
  reaper.GetSetMediaTrackInfo_String(track, "P_ICON", icon_path, true)
end

local function scan_tracks()
  reaper.PreventUIRefresh(1)

  local track_count = reaper.CountTracks(0)
  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local chans = reaper.GetMediaTrackInfo_Value(track, "I_NCHAN")
    local icon_path = get_icon_path(track)

    local is_managed = (icon_path == quad_icon or icon_path == surround_icon)
    if chans == 4 then
      if icon_path == "" or is_managed then
        if icon_path ~= quad_icon then
          set_icon_path(track, quad_icon)
        end
      end
    elseif chans == 6 then
      if icon_path == "" or is_managed then
        if icon_path ~= surround_icon then
          set_icon_path(track, surround_icon)
        end
      end
    else
      if is_managed then
        set_icon_path(track, "")
      end
    end
  end

  reaper.PreventUIRefresh(-1)
end

local last_state = -1
local function main()
  local state = reaper.GetProjectStateChangeCount(0)
  if state ~= last_state then
    last_state = state
    scan_tracks()
  end
  reaper.defer(main)
end

main()
