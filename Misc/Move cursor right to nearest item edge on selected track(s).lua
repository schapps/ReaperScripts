-- @description Move cursor to nearest right item edge on selected track(s)
-- @author Stephen Schappler
-- @version 1.1
-- @about
--   Navigation Script
-- @link https://www.stephenschappler.com
-- @changelog 
--   8/28/2025 - Creating the script

function main()
  local cursor_pos = reaper.GetCursorPosition()
  local nearest_edge = nil

  -- Count selected tracks
  local sel_track_count = reaper.CountSelectedTracks(0)
  if sel_track_count == 0 then
    reaper.ShowMessageBox("No tracks selected!", "Error", 0)
    return
  end

  -- Loop through selected tracks
  for i = 0, sel_track_count - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    local item_count = reaper.CountTrackMediaItems(track)

    -- Loop through items on track
    for j = 0, item_count - 1 do
      local item = reaper.GetTrackMediaItem(track, j)
      local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local item_end = item_start + item_len

      -- Check start edge
      if item_start > cursor_pos then
        if (not nearest_edge) or (item_start < nearest_edge) then
          nearest_edge = item_start
        end
      end

      -- Check end edge
      if item_end > cursor_pos then
        if (not nearest_edge) or (item_end < nearest_edge) then
          nearest_edge = item_end
        end
      end
    end
  end

  if nearest_edge then
    reaper.SetEditCurPos(nearest_edge, true, false) -- moveview, seekplay
  else
    -- reaper.ShowMessageBox("No item edge to the right on selected tracks.", "Info", 0)
  end
end

reaper.Undo_BeginBlock()
main()
reaper.Undo_EndBlock("Move cursor to nearest right item edge on selected track(s)", -1)
