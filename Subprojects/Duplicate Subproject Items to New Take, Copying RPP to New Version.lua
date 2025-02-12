-- @description Duplicate Subproject Items to New Take, Copying RPP to New Version
-- @author Stephen Schappler
-- @version 1.1
-- @about
--   Duplicate Subproject Items as New Takes with Versioning (Multiple Items) and Open Each New Subproject in a New Tab
-- @link https://www.stephenschappler.com
-- @changelog 
--   02/11/25 - v1.0 Creating the script.
--   02/12/25 - v1.1 Modifying the script so that it takes the user back to the parent project at the end.


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
-- Begin Undo block
reaper.Undo_BeginBlock()

local parentProjectName = getCurrentProjectName()

local numItems = reaper.CountSelectedMediaItems(0)
if numItems == 0 then
  reaper.ShowMessageBox("No media items selected.", "Error", 0)
  return
end

-- Table to store new version file paths keyed by original file path.
local newVersionMap = {}

for i = 0, numItems - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  if not item then
    reaper.ShowMessageBox("Error retrieving one of the selected items.", "Error", 0)
    return
  end

  -- Use the active take of this item.
  local take = reaper.GetActiveTake(item)
  if not take then
    reaper.ShowMessageBox("One of the selected items has no active take.", "Error", 0)
    return
  end

  -- Retrieve the subproject file from the active take.
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then
    reaper.ShowMessageBox("Unable to retrieve the subproject source for one of the items.", "Error", 0)
    return
  end

  local origFile = reaper.GetMediaSourceFileName(src, "")
  if not origFile or origFile == "" then
    reaper.ShowMessageBox("Could not determine the subproject file path for one of the items.", "Error", 0)
    return
  end

  -- Parse the file path into folder, filename, base, and extension.
  local folder, filename = origFile:match("^(.-)[\\/]([^\\/]-)$")
  if not folder or not filename then
    reaper.ShowMessageBox("Failed to parse the subproject file path for one of the items.", "Error", 0)
    return
  end

  local base, ext = filename:match("^(.*)%.([^.]+)$")
  if not base or not ext then
    reaper.ShowMessageBox("Failed to parse the subproject file name for one of the items.", "Error", 0)
    return
  end

  -- Check that the file extension is ".rpp".
  if ext:lower() ~= "rpp" then
    reaper.ShowMessageBox("One of the selected items is not a subproject (not a .rpp file).", "Error", 0)
    return
  end

  -- Check if we already processed this original file.
  local newFilePath = newVersionMap[origFile]
  if not newFilePath then
    -- Determine a new version filename.
    local origBase, currentVer = base:match("^(.*)_v(%d%d)$")
    local newVer
    if currentVer then
      newVer = tonumber(currentVer) + 1
    else
      newVer = 2
    end

    local newFilename = string.format("%s_v%02d.%s", (origBase or base), newVer, ext)
    newFilePath = folder .. "/" .. newFilename

    while file_exists(newFilePath) do
      newVer = newVer + 1
      newFilename = string.format("%s_v%02d.%s", (origBase or base), newVer, ext)
      newFilePath = folder .. "/" .. newFilename
    end

    -- Copy the original subproject file to the new file.
    local infile = io.open(origFile, "rb")
    if not infile then
      reaper.ShowMessageBox("Could not open subproject file for reading:\n" .. origFile, "Error", 0)
      return
    end
    local content = infile:read("*all")
    infile:close()

    local outfile = io.open(newFilePath, "wb")
    if not outfile then
      reaper.ShowMessageBox("Could not create new subproject file for writing:\n" .. newFilePath, "Error", 0)
      return
    end
    outfile:write(content)
    outfile:close()

    -- Store the new file path so we reuse it for other items referencing the same original.
    newVersionMap[origFile] = newFilePath
  end

  -- Now add a new take to the item.
  local newTake = reaper.AddTakeToMediaItem(item)
  if not newTake then
    reaper.ShowMessageBox("Failed to add a new take to one of the items.", "Error", 0)
    return
  end

  -- Create a PCM source from the new subproject file and assign it to the new take.
  local newSource = reaper.PCM_Source_CreateFromFile(newFilePath)
  if not newSource then
    reaper.ShowMessageBox("Failed to create PCM source from new subproject file for one of the items.", "Error", 0)
    return
  end
  reaper.SetMediaItemTake_Source(newTake, newSource)

  -- Preserve the start offset from the original take.
  local origOffset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  reaper.SetMediaItemTakeInfo_Value(newTake, "D_STARTOFFS", origOffset)

  -- Copy the original take's name to the new take.
  local retval, origTakeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  if retval then
    reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", origTakeName, true)
  end

  -- Select the new take by setting it as the active take.
  local takeCount = reaper.CountTakes(item)
  reaper.SetMediaItemInfo_Value(item, "I_CURTAKE", takeCount - 1)
end

-- Now, iterate over the selected items and open each subproject.
-- This simulates the mouse modifier behavior ("Open subproject") without closing the parent project.
for i = 0, numItems - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  if item then
    -- Get the active take and check its file extension.
    local take = reaper.GetActiveTake(item)
    if take then
      local src = reaper.GetMediaItemTake_Source(take)
      if src then
        local filePath = reaper.GetMediaSourceFileName(src, "")
        if filePath and filePath:sub(-4):lower() == ".rpp" then
          -- Select only this item.
          reaper.SetMediaItemSelected(item, true)
          for j = 0, numItems - 1 do
            local other = reaper.GetSelectedMediaItem(0, j)
            if other and other ~= item then
              reaper.SetMediaItemSelected(other, false)
            end
          end
          -- Open the subproject.
          reaper.Main_OnCommand(40109, 0)
          -- Save and render the RPP.
          reaper.Main_OnCommand(42332, 0)
        end
      end
    end
  end
end

-- Activate the parent project by name
activateProjectByName(parentProjectName)

reaper.UpdateArrange()
reaper.TrackList_AdjustWindows(false)
reaper.Undo_EndBlock("Duplicate Subprojects for Multiple Items (Versioned, New Takes Selected, Opened)", -1)
