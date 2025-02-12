-- @description Duplicate Subproject Items to New Take, Copying RPP to New Version
-- @author Stephen Schappler
-- @version 1.2
-- @about
--   Duplicate Subproject Items as New Takes with Versioning (Multiple Items) and Open Each New Subproject in a New Tab
-- @link https://www.stephenschappler.com
-- @changelog 
--   02/11/25 - v1.0 Creating the script.
--   02/12/25 - v1.1 Modifying the script so that it takes the user back to the parent project at the end.
--   02/12/25 - v1.2 Adding in take markers that show the name of the rpp version for each take


------------------------------------------------------------
-- Helper function: Check if a file exists.
local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

-- Function to get project name
function getCurrentProjectName()
    projectName = reaper.GetProjectName(0, "")
    -- reaper.ShowConsoleMsg("Current project name: " .. projectName .. "\n")
    return projectName
end

-- Function to activate project by name
function activateProjectByName(targetName)
    local projIndex = 0
    while true do
        local proj = reaper.EnumProjects(projIndex, "")
        if not proj then
            -- reaper.ShowConsoleMsg("No more projects to check.\n")
            break
        end
        projectName = reaper.GetProjectName(proj, "")
        if projectName == nil then
            projectName = "Unnamed Project"
        end
        -- reaper.ShowConsoleMsg("Checking project: " .. projectName .. "\n")
        if projectName == targetName then
            -- reaper.ShowConsoleMsg("Activating project: " .. projectName .. "\n")
            reaper.SelectProjectInstance(proj)
            break
        end
        projIndex = projIndex + 1
    end
end

------------------------------------------------------------
-- Helper function: Check if a file exists.
local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

-- Function to get project name
function getCurrentProjectName()
    return reaper.GetProjectName(0, "")
end

-- Function to activate project by name
function activateProjectByName(targetName)
    local projIndex = 0
    while true do
        local proj = reaper.EnumProjects(projIndex, "")
        if not proj then break end
        if reaper.GetProjectName(proj, "") == targetName then
            reaper.SelectProjectInstance(proj)
            break
        end
        projIndex = projIndex + 1
    end
end

-- Function to save selected items
function saveSelectedItems()
    local savedItems = {}
    for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
        savedItems[#savedItems + 1] = reaper.GetSelectedMediaItem(0, i)
    end
    return savedItems
end

-- Function to restore selected items
function restoreSelectedItems(savedItems)
    reaper.Main_OnCommand(40289, 0) -- Unselect all items
    for _, item in ipairs(savedItems) do
        reaper.SetMediaItemSelected(item, true)
    end
end

------------------------------------------------------------
-- Begin Undo block
reaper.Undo_BeginBlock()

local parentProjectName = getCurrentProjectName()
local selectedItems = saveSelectedItems()

local numItems = reaper.CountSelectedMediaItems(0)
if numItems == 0 then
  reaper.ShowMessageBox("No media items selected.", "Error", 0)
  return
end

local newVersionMap = {}

for i = 0, numItems - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  if not item then
    reaper.ShowMessageBox("Error retrieving selected items.", "Error", 0)
    return
  end

  local take = reaper.GetActiveTake(item)
  if not take then
    reaper.ShowMessageBox("One of the items has no active take.", "Error", 0)
    return
  end

  local src = reaper.GetMediaItemTake_Source(take)
  if not src then
    reaper.ShowMessageBox("Unable to retrieve source for one of the items.", "Error", 0)
    return
  end

  local origFile = reaper.GetMediaSourceFileName(src, "")
  if not origFile or origFile == "" then
    reaper.ShowMessageBox("Could not determine subproject file path.", "Error", 0)
    return
  end

  local folder, filename = origFile:match("^(.-)[\\/]([^\\/]-)$")
  if not folder or not filename then
    reaper.ShowMessageBox("Failed to parse file path.", "Error", 0)
    return
  end

  local base, ext = filename:match("^(.*)%.([^.]+)$")
  if not base or ext:lower() ~= "rpp" then
    reaper.ShowMessageBox("Invalid subproject file.", "Error", 0)
    return
  end

  local newFilePath = newVersionMap[origFile]
  if not newFilePath then
    local origBase, currentVer = base:match("^(.*)_v(%d%d)$")
    local newVer = currentVer and tonumber(currentVer) + 1 or 2

    repeat
      newFilePath = string.format("%s/%s_v%02d.%s", folder, (origBase or base), newVer, ext)
      newVer = newVer + 1
    until not file_exists(newFilePath)

    local infile = io.open(origFile, "rb")
    if not infile then
      reaper.ShowMessageBox("Could not open subproject file:\n" .. origFile, "Error", 0)
      return
    end
    local content = infile:read("*all")
    infile:close()

    local outfile = io.open(newFilePath, "wb")
    if not outfile then
      reaper.ShowMessageBox("Could not create new subproject file:\n" .. newFilePath, "Error", 0)
      return
    end
    outfile:write(content)
    outfile:close()

    newVersionMap[origFile] = newFilePath
  end

  local newTake = reaper.AddTakeToMediaItem(item)
  if not newTake then
    reaper.ShowMessageBox("Failed to add take.", "Error", 0)
    return
  end

  local newSource = reaper.PCM_Source_CreateFromFile(newFilePath)
  if not newSource then
    reaper.ShowMessageBox("Failed to create PCM source.", "Error", 0)
    return
  end
  reaper.SetMediaItemTake_Source(newTake, newSource)

  local origOffset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  reaper.SetMediaItemTakeInfo_Value(newTake, "D_STARTOFFS", origOffset)

  local retval, origTakeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  if retval then
    reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", origTakeName, true)
  end

  local takeCount = reaper.CountTakes(item)
  reaper.SetMediaItemInfo_Value(item, "I_CURTAKE", takeCount - 1)
end

for i = 0, numItems - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  if item then
    local take = reaper.GetActiveTake(item)
    if take then
      local src = reaper.GetMediaItemTake_Source(take)
      if src then
        local filePath = reaper.GetMediaSourceFileName(src, "")
        if filePath and filePath:sub(-4):lower() == ".rpp" then
          reaper.SetMediaItemSelected(item, true)
          for j = 0, numItems - 1 do
            local other = reaper.GetSelectedMediaItem(0, j)
            if other and other ~= item then
              reaper.SetMediaItemSelected(other, false)
            end
          end
          reaper.Main_OnCommand(40109, 0) -- Open subproject
          reaper.Main_OnCommand(42332, 0) -- Save and render RPP
        end
      end
    end
  end
end

activateProjectByName(parentProjectName)

restoreSelectedItems(selectedItems)

-- Insert take markers for each saved item at the left-bound offset.
for _, item in ipairs(selectedItems) do
  if item then
    local takeCount = reaper.CountTakes(item)
    if takeCount > 1 then
      local newTake = reaper.GetTake(item, takeCount - 1)
      if newTake then
        local src = reaper.GetMediaItemTake_Source(newTake)
        if src then
          local filePath = reaper.GetMediaSourceFileName(src, "")
          local newFileName = filePath:match("([^\\/]+)%.rpp$")
          if newFileName then
            -- Calculate the offset where the item's left bound is set.
            local marker_offset = reaper.GetMediaItemTakeInfo_Value(newTake, "D_STARTOFFS")
            reaper.SetTakeMarker(newTake, -1, newFileName, marker_offset)
          end
        end
      end
    end
  end
end

reaper.UpdateArrange()
reaper.TrackList_AdjustWindows(false)
reaper.Undo_EndBlock("Duplicate Subprojects (Versioned, New Takes, Selection Restored, Markers)", -1)
