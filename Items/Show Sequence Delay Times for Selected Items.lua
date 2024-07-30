-- @description Show Sequence Delay Times for Selected Items
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Show sequence delay times needed in seconds and ticks (for Scream) for selected items.
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/30/24 Creating the script

-- Get the selected items count
local itemCount = reaper.CountSelectedMediaItems(0)
if itemCount < 2 then
    reaper.ShowMessageBox("Please select at least two items.", "Error", 0)
    return
end

-- Collect the selected items and sort them by their start time
local items = {}
for i = 0, itemCount - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    table.insert(items, {item=item, position=position})
end

table.sort(items, function(a, b) return a.position < b.position end)

-- Calculate the time intervals
local intervals = {}
for i = 1, itemCount - 1 do
    local item1 = items[i].item
    local item2 = items[i + 1].item
    local position1 = items[i].position
    local position2 = items[i + 1].position
    local delay = position2 - position1
    local delayTicks = delay * 240
    local take1 = reaper.GetActiveTake(item1)
    local take2 = reaper.GetActiveTake(item2)
    local name1 = take1 and reaper.GetTakeName(take1) or "Unnamed Item"
    local name2 = take2 and reaper.GetTakeName(take2) or "Unnamed Item"
    table.insert(intervals, {name1=name1, name2=name2, delay=delay, delayTicks=delayTicks})
end

-- Build the output string
local output = ""
for i, interval in ipairs(intervals) do
    output = output .. string.format("From '%s' to '%s': \n%.3f seconds (%.0f ticks)\n\n",
                                      interval.name1, interval.name2, interval.delay, interval.delayTicks)
end

-- Display the output in a popup window
reaper.ShowMessageBox(output, "Time Intervals Between Items", 0)
