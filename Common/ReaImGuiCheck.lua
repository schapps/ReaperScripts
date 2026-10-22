-- @noindex
-- Shared ReaImGui dependency check, shipped with the Schapps ReaImGUI Theme
-- package (see its @provides). Not a standalone script -- dofile() this and
-- call the returned function with the ReaImGui API version the script needs:
--
--   local ImGui = dofile(path_to_this_file)("0.10")
--   if not ImGui then return end
--
-- Returns the ImGui module (same as require 'imgui' '0.10') when ReaImGui is
-- installed and new enough. Otherwise tells the user what's wrong (missing,
-- or installed but too old), offers to open ReaPack to the ReaImGui package,
-- and returns nil.

local REAIMGUI_PACKAGE = "ReaImGui: ReaScript binding for Dear ImGui"

local function installedVersion()
  if reaper.ImGui_GetVersion then
    return select(3, reaper.ImGui_GetVersion())
  end
end

-- True if version string a (e.g. "0.9.3") is older than b (e.g. "0.10"),
-- comparing numeric components left to right; missing components count as 0.
local function isOlder(a, b)
  local pa, pb = {}, {}
  for n in a:gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
  for n in b:gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x < y end
  end
  return false
end

-- Shows msg, adding an "Open ReaPack now?" prompt when ReaPack is available
-- to jump straight to the ReaImGui package.
local function notify(title, msg)
  if reaper.ReaPack_BrowsePackages then
    local answer = reaper.MB(msg .. "\n\nOpen ReaPack to the ReaImGui package now?", title, 4)
    if answer == 6 then  -- Yes
      reaper.ReaPack_BrowsePackages("ReaImGui")
    end
  else
    reaper.MB(msg .. "\n\nReaPack itself isn't installed -- get it from https://reapack.com first.", title, 0)
  end
end

return function(api_version)
  if not reaper.ImGui_GetBuiltinPath then
    -- ImGui_GetBuiltinPath arrived in ReaImGui 0.9, so an older install
    -- still exposes other ImGui_* functions without it.
    local old = installedVersion() or (reaper.ImGui_CreateContext and "an older version")
    if old then
      notify("ReaImGui Update Required", string.format(
        "This script needs ReaImGui %s or newer, but %s is installed.\n\n" ..
        "Update \"%s\" via Extensions > ReaPack > Synchronize packages, then restart REAPER.",
        api_version, old, REAIMGUI_PACKAGE))
    else
      notify("ReaImGui Required", string.format(
        "This script needs the ReaImGui extension, which isn't installed.\n\n" ..
        "Install \"%s\" via Extensions > ReaPack > Browse packages, then restart REAPER.",
        REAIMGUI_PACKAGE))
    end
    return nil
  end

  -- Compare versions here rather than pcall'ing the imgui.lua loader: when
  -- ReaImGui is too old, the loader's error is also reported through
  -- REAPER's own ReaScript error dialog once the script ends, even if it
  -- was caught.
  local installed = installedVersion()
  if installed and isOlder(installed, api_version) then
    notify("ReaImGui Update Required", string.format(
      "This script needs ReaImGui %s or newer, but %s is installed.\n\n" ..
      "Update \"%s\" via Extensions > ReaPack > Synchronize packages, then restart REAPER.",
      api_version, installed, REAIMGUI_PACKAGE))
    return nil
  end

  package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
  return require "imgui" (api_version)
end
