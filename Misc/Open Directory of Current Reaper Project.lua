-- @description Open Directory of Current Reaper Project
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Reaper Lua script to open the folder of the currently opened project file
-- @link https://www.stephenschappler.com
-- @changelog 
--   10/07/24 v1.0 - Creating the script

function open_project_folder()
    -- Get the full path of the currently opened project file
    local project_path = reaper.GetProjectPath(0, "")
    
    -- If there is no project loaded, show a message
    if project_path == "" then
      reaper.ShowMessageBox("No project is currently opened.", "Error", 0)
      return
    end
  
    -- Remove the project file name from the path to get just the folder
    project_folder = project_path:match("(.*[/\\])")
  
    -- If no folder is found, show an error message
    if project_folder == nil then
      reaper.ShowMessageBox("Could not determine project folder.", "Error", 0)
      return
    end
  
    -- Open the folder in the system's file explorer
    reaper.CF_ShellExecute(project_folder)
  end
  
  -- Run the function
  open_project_folder()
  