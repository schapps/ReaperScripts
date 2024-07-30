-- @description Create subproject from tracks or items and open the subproject
-- @author Stephen Schappler
-- @version 1.2
-- @about
-- This is a simple script to create subprojects with our Sony Subproject Workflow.
-- @link https://www.stephenschappler.com
-- @changelog

-- Function to check if a string contains a substring
function containsString(str, substr)
    return string.find(str, substr, 1, true) ~= nil
end

-- Helper function to convert a potentially relative path to an absolute path
function toAbsolutePath(path)
    local res_path = reaper.GetResourcePath()  -- Gets REAPER's resource path
    return reaper.file_exists(path) and path or (res_path .. "\\" .. path)
end

-- Function to execute a command
function runCommand(commandID)
    reaper.Main_OnCommand(commandID, 0) -- 0 is to use the main section
end

-- Function to clear all markers
function clearAllMarkers()
    -- Loop through all markers and remove them
    local i = reaper.CountProjectMarkers(0) - 1
    while i >= 0 do
        local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers(i)
        reaper.DeleteProjectMarker(0, markrgnindexnumber, isrgn)
        i = i - 1
    end
end

-- Function to add =START and =END markers to time selection
function addMarkersToTimeSelection()
    -- Check if there is a time selection
    local startTime, endTime = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    
    if startTime ~= endTime then
        -- reaper.ShowConsoleMsg("Time selection found from " .. startTime .. " to " .. endTime .. "\n")
        
        -- Clear all existing markers
        clearAllMarkers()

        -- Add new =START and =END markers
        -- reaper.ShowConsoleMsg("Creating =START marker at " .. startTime .. "\n")
        reaper.AddProjectMarker(0, false, startTime, 0, "=START", -1)
        
        -- reaper.ShowConsoleMsg("Creating =END marker at " .. endTime .. "\n")
        reaper.AddProjectMarker(0, false, endTime, 0, "=END", -1)
    else
        reaper.ShowMessageBox("No time selection set. Please set a time selection and run the script again.", "Error", 0)
    end
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

-- Function to check if there is a time selection
function isTimeSelectionPresent()
    local startTime, endTime = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    return startTime ~= endTime
end

-- Function to check if any items are selected
function areItemsSelected()
    return reaper.CountSelectedMediaItems(0) > 0
end

-- Main execution block
if isTimeSelectionPresent() or areItemsSelected() then
    local parentProjectName = getCurrentProjectName()

    -- Time selection: Set time selection to items
    runCommand(40290)

    -- Move tracks to subproject
    runCommand(41997)

    -- Move position of item to edit cursor
    runCommand(41205)

    -- Open associated project in new tab
    runCommand(41816)

    -- Clear all markers and add new =START and =END markers to the time selection
    addMarkersToTimeSelection()

    -- View: Zoom Time Selection
    runCommand(40031)

    -- Save project and render RPP-Prox
    runCommand(42332)

    -- Activate the parent project by name
    activateProjectByName(parentProjectName)

    -- Reset item length 
    command_id = reaper.NamedCommandLookup("_XENAKIOS_RESETITEMLENMEDOFFS")
    reaper.Main_OnCommand(command_id,0)
    
    -- Clear Time selection
    runCommand(40635)

    -- Dynamic Split based on last used settings
    -- runCommand(42951)

    -- Open Harvester for re-naming
    -- command_id = reaper.NamedCommandLookup("_Harvester")
    -- reaper.Main_OnCommand(command_id,0)

    reaper.Undo_EndBlock("Execute custom action sequence", -1)
else
    -- If no time selection or no items are selected, just make the subproject and open it
    -- reaper.ShowMessageBox("No time selection or no items selected. Will create subproject but not render.", "Info", 0)
    local parentProjectName = getCurrentProjectName()

    -- Move tracks to subproject
    runCommand(41997)

    -- Open associated project in new tab
    runCommand(41816)

    reaper.Undo_EndBlock("Partial subproject creation", -1)
end
