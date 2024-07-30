-- @description Open Directory in Windows Explorer
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Change the directory_path to whatever directory you want to open
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/29/24 Creating the script

-- Specify the directory path you want to open
local directory_path = "E:\\SFX Library" --Directory to open

-- Function to open a directory in Windows Explorer
function openDirectoryInExplorer(path)
    -- Use the os.execute function with 'explorer' command to open the directory
    local command = 'explorer "' .. path .. '"'
    os.execute(command)
end

-- Call the function with the specified path
openDirectoryInExplorer(directory_path)
