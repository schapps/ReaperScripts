-- @description Open Subproject Item
-- @author Stephen Schappler
-- @version 1.3
-- @about
--   Opens all selected subproject items in new REAPER project tabs, keeping all
--   other open projects intact. If a subproject is already open, switches to it.
-- @link https://www.stephenschappler.com
-- @changelog
--   05/06/26 - v1.3 Collect paths before opening to fix multi-select only opening one
--   05/06/26 - v1.2 Support opening multiple selected subproject items
--   05/06/26 - v1.1 Use GetSubProjectFromSource + new tab; no longer triggers external editor
--   08/23/24 - v1.0 Initial release

local count = reaper.CountSelectedMediaItems(0)
if count == 0 then
  reaper.MB("No items selected.", "Open Subproject Item", 0)
  return
end

-- Collect all targets first. GetSelectedMediaItem(0, i) uses the current active
-- project, so once we open the first tab REAPER's focus shifts and subsequent
-- calls would query the wrong project. Gather everything before touching tabs.
local to_open = {}
for i = 0, count - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  local take = reaper.GetActiveTake(item)
  if take then
    local src = reaper.GetMediaItemTake_Source(take)
    local fp  = reaper.GetMediaSourceFileName(src, "")
    if fp:sub(-4):lower() == ".rpp" then
      to_open[#to_open + 1] = {
        fp       = fp,
        existing = reaper.GetSubProjectFromSource(src),
      }
    end
  end
end

if #to_open == 0 then
  reaper.MB("None of the selected items are subprojects (.rpp).", "Open Subproject Item", 0)
  return
end

for _, entry in ipairs(to_open) do
  if entry.existing then
    reaper.SelectProjectInstance(entry.existing)
  else
    reaper.Main_OnCommand(40859, 0)  -- new project tab (keep current)
    reaper.Main_openProject(entry.fp)
  end
end

reaper.UpdateArrange()
