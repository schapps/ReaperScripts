-- @description Move Selected Items to Duplicate Tracks
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Gives every selected item its own track. For each track holding more than
--   one selected item, the track is duplicated (name, FX, routing, envelopes
--   and all other settings included) once per extra item, and the items are
--   spread one per duplicate directly below the original. The first item stays
--   on the original track and every item keeps its original start time, length
--   and take settings.
-- @link https://www.stephenschappler.com
-- @changelog
--   09/22/26 v1.0 - Initial release

local function track_index(track)
    return math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1  -- 0-based
end

-- Duplicate track_src (all settings, FX, envelopes) and strip the copied items.
-- The duplicate lands directly below the source; returns the new track.
local function duplicate_track_empty(track_src)
    reaper.Main_OnCommand(40297, 0)  -- Track: Unselect (clear selection of) all tracks
    reaper.SetTrackSelected(track_src, true)
    reaper.Main_OnCommand(40062, 0)  -- Track: Duplicate tracks

    local dup = reaper.GetTrack(0, track_index(track_src) + 1)
    if not dup then return nil end

    for i = reaper.CountTrackMediaItems(dup) - 1, 0, -1 do
        reaper.DeleteTrackMediaItem(dup, reaper.GetTrackMediaItem(dup, i))
    end

    return dup
end

local function main()
    local item_count = reaper.CountSelectedMediaItems(0)
    if item_count == 0 then
        reaper.ShowMessageBox("No items selected.", "Move Items to Duplicate Tracks", 0)
        return
    end

    -- Group selected items by their source track, keeping track order stable
    local groups, order = {}, {}
    for i = 0, item_count - 1 do
        local item  = reaper.GetSelectedMediaItem(0, i)
        local track = reaper.GetMediaItem_Track(item)
        if not groups[track] then
            groups[track] = {}
            table.insert(order, track)
        end
        table.insert(groups[track], item)
    end

    -- Left to right within each track, so items land in timeline order
    for _, track in ipairs(order) do
        table.sort(groups[track], function(a, b)
            return reaper.GetMediaItemInfo_Value(a, "D_POSITION") <
                   reaper.GetMediaItemInfo_Value(b, "D_POSITION")
        end)
    end

    local moved = 0
    for _, track_src in ipairs(order) do
        local items = groups[track_src]
        if #items > 1 then
            -- Folder depth lives on the track that closes the folder, so hand it
            -- to the last duplicate instead of leaving it on the source track
            local depth = reaper.GetMediaTrackInfo_Value(track_src, "I_FOLDERDEPTH")

            local dups = {}
            for _ = 2, #items do
                local dup = duplicate_track_empty(track_src)
                if not dup then break end
                reaper.SetMediaTrackInfo_Value(dup, "I_FOLDERDEPTH", 0)
                table.insert(dups, dup)
            end

            -- Each duplicate is inserted directly below the source, so the
            -- creation order is not the arrange order - sort top to bottom
            table.sort(dups, function(a, b) return track_index(a) < track_index(b) end)

            if depth < 0 and #dups > 0 then
                reaper.SetMediaTrackInfo_Value(track_src, "I_FOLDERDEPTH", 0)
                reaper.SetMediaTrackInfo_Value(dups[#dups], "I_FOLDERDEPTH", depth)
            end

            -- Item 1 stays put; the rest each get a duplicate of their own,
            -- earliest item on the topmost duplicate
            for i = 2, #items do
                local dup = dups[i - 1]
                -- Moving between tracks leaves position, length and takes untouched
                if dup and reaper.MoveMediaItemToTrack(items[i], dup) then
                    moved = moved + 1
                end
            end
        end
    end

    -- Duplicating tracks clobbers the track selection and can drop item selection
    reaper.Main_OnCommand(40297, 0)  -- Track: Unselect (clear selection of) all tracks
    for _, track in ipairs(order) do
        reaper.SetTrackSelected(track, true)
    end
    for _, track in ipairs(order) do
        for _, item in ipairs(groups[track]) do
            reaper.SetMediaItemSelected(item, true)
        end
    end

    return moved
end

reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock()

local ok, moved = pcall(main)

reaper.Undo_EndBlock("Move selected items to duplicate tracks", -1)
reaper.PreventUIRefresh(-1)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()

if not ok then
    reaper.ShowMessageBox(tostring(moved), "Move Items to Duplicate Tracks", 0)
end
