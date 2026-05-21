-- @description Spread Items to Stacked Tracks
-- @author Stephen Schappler
-- @version 1.0
-- @link https://www.stephenschappler.com
-- @changelog
--   2026-05-20 v1.0 - Creating the script

function main()
    local item_count = reaper.CountSelectedMediaItems(0)
    if item_count == 0 then
        reaper.ShowMessageBox("No items selected.", "Spread to Tracks", 0)
        return
    end

    -- Collect selected items and sort left to right by position (track as tiebreak)
    local items = {}
    for i = 0, item_count - 1 do
        table.insert(items, reaper.GetSelectedMediaItem(0, i))
    end

    table.sort(items, function(a, b)
        local pos_a = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
        local pos_b = reaper.GetMediaItemInfo_Value(b, "D_POSITION")
        if pos_a ~= pos_b then return pos_a < pos_b end
        local ta = reaper.GetMediaItem_Track(a)
        local tb = reaper.GetMediaItem_Track(b)
        return reaper.GetMediaTrackInfo_Value(ta, "IP_TRACKNUMBER") <
               reaper.GetMediaTrackInfo_Value(tb, "IP_TRACKNUMBER")
    end)

    local ref_item     = items[1]
    local ref_pos      = reaper.GetMediaItemInfo_Value(ref_item, "D_POSITION")
    local ref_track    = reaper.GetMediaItem_Track(ref_item)
    local ref_track_idx = reaper.GetMediaTrackInfo_Value(ref_track, "IP_TRACKNUMBER") - 1  -- 0-based

    -- Insert any missing tracks directly below the reference track
    for i = 1, #items - 1 do
        local needed_idx = ref_track_idx + i
        if reaper.CountTracks(0) <= needed_idx then
            reaper.InsertTrackAtIndex(needed_idx, false)
        end
    end

    -- Move items 2..N to their target tracks and align start times
    for i = 2, #items do
        local target_track = reaper.GetTrack(0, ref_track_idx + (i - 1))
        reaper.MoveMediaItemToTrack(items[i], target_track)
        reaper.SetMediaItemPosition(items[i], ref_pos, false)
    end

    reaper.UpdateArrange()
end

reaper.Undo_BeginBlock()
main()
reaper.Undo_EndBlock("Spread items to stacked tracks", -1)
