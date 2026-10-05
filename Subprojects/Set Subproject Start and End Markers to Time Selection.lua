-- @description Set Subproject Start and End Markers to Time Selection
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Moves the subproject render bound markers ("=START" and "=END") to the
--   start and end of the current time selection. Any marker that doesn't
--   exist is created. If there are duplicate =START or =END markers, the
--   extras are removed so the subproject bounds are unambiguous.
-- @link https://www.stephenschappler.com
-- @changelog
--   10/05/26 v1.0 - Initial release

local START_NAME = "=START"
local END_NAME = "=END"

local function main()
  local sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if sel_end <= sel_start then
    reaper.MB("Please make a time selection first.", "Set Subproject Start and End Markers", 0)
    return
  end

  -- Find the first =START / =END markers and note any duplicates
  local found = {} -- name -> { id, color }
  local duplicate_ids = {}
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  for i = 0, num_markers + num_regions - 1 do
    local _, isrgn, _, _, name, id, color = reaper.EnumProjectMarkers3(0, i)
    if not isrgn and (name == START_NAME or name == END_NAME) then
      if found[name] then
        duplicate_ids[#duplicate_ids + 1] = id
      else
        found[name] = { id = id, color = color }
      end
    end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local targets = { [START_NAME] = sel_start, [END_NAME] = sel_end }
  for name, pos in pairs(targets) do
    local m = found[name]
    if m then
      reaper.SetProjectMarker4(0, m.id, false, pos, 0, name, m.color, 0)
    end
  end

  for _, id in ipairs(duplicate_ids) do
    reaper.DeleteProjectMarker(0, id, false)
  end
  for name, pos in pairs(targets) do
    if not found[name] then
      reaper.AddProjectMarker(0, false, pos, 0, name, -1)
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Set subproject start and end markers to time selection", -1)
end

main()
