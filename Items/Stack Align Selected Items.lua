-- @description Stack Align Selected Items
-- @author Stephen Schappler
-- @version 1.0
-- @link https://www.stephenschappler.com
-- @changelog
--   2026-05-20 v1.0 - Creating the script

function main()
    local item_count = reaper.CountSelectedMediaItems(0)
    if item_count == 0 then
        reaper.ShowMessageBox("No items selected.", "Stack Align", 0)
        return
    end

    -- Group selected items by track
    local tracks = {}
    local track_order = {}

    for i = 0, item_count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local track = reaper.GetMediaItem_Track(item)

        if not tracks[track] then
            tracks[track] = {}
            table.insert(track_order, track)
        end
        table.insert(tracks[track], item)
    end

    if #track_order < 2 then
        reaper.ShowMessageBox("Select items on at least 2 different tracks.", "Stack Align", 0)
        return
    end

    -- Sort tracks top to bottom by track number
    table.sort(track_order, function(a, b)
        return reaper.GetMediaTrackInfo_Value(a, "IP_TRACKNUMBER") <
               reaper.GetMediaTrackInfo_Value(b, "IP_TRACKNUMBER")
    end)

    -- Sort items within each track left to right by position
    for _, track in ipairs(track_order) do
        table.sort(tracks[track], function(a, b)
            return reaper.GetMediaItemInfo_Value(a, "D_POSITION") <
                   reaper.GetMediaItemInfo_Value(b, "D_POSITION")
        end)
    end

    local ref_items = tracks[track_order[1]]

    for t = 2, #track_order do
        local other_items = tracks[track_order[t]]
        for i = 1, math.min(#ref_items, #other_items) do
            local ref_pos = reaper.GetMediaItemInfo_Value(ref_items[i], "D_POSITION")
            reaper.SetMediaItemPosition(other_items[i], ref_pos, false)
        end
    end

    reaper.UpdateArrange()
end

reaper.Undo_BeginBlock()
main()
reaper.Undo_EndBlock("Stack align items", -1)
