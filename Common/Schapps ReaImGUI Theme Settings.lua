-- @description Schapps ReaImGUI Theme Settings
-- @author Stephen Schappler
-- @version 1.7
-- @about
--   Settings window for Schapps ReaImGUI Theme (ReaImGuiTheme.lua) -- lets
--   you customize the theme's primary/secondary accent colors and body/
--   monospace fonts across every script that shares the theme, and
--   export/import those settings as a .spstheme file. Everything is saved
--   to REAPER's ExtState, so it persists across sessions and takes effect
--   immediately in any other theme-using script window already open.
-- @changelog
--   08/29/26 v1.7 - Added Table Row Stripe color (ReaImGuiTheme.lua
--                  v1.32) with a small striped-table preview.
--   08/29/26 v1.6 - Secondary now means secondary action buttons, not
--                  tabs (ReaImGuiTheme.lua v1.30) -- relabeled, and the
--                  preview shows a Secondary Button next to Primary.
--   08/29/26 v1.5 - Tab preview now uses the real theme.TabBar (color/
--                  rename/delete/+) instead of a plain, unused-elsewhere
--                  BeginTabItem stand-in.
--   08/29/26 v1.4 - Font name fields are now dropdowns (same options as
--                  NVK's theme editor) instead of free-text.
--   08/28/26 v1.3 - Collapsing this window (its titlebar's collapse
--                  triangle) was corrupting ReaImGui's native window
--                  state badly enough that every later launch immediately
--                  hit "ImGui_End: Calling End() too many times!", even
--                  in a brand new script instance -- that ruled out a
--                  Lua-side stack mismatch (this script's one Begin/End
--                  pair was already correctly balanced) and pointed at
--                  state living in the extension's C++ side, which only
--                  a REAPER restart clears. Added WindowFlags_NoCollapse
--                  (removes the trigger) and WindowFlags_NoSavedSettings
--                  (removes position/size/collapsed persistence) to the
--                  window's flags so it can't happen again.
--   08/28/26 v1.2 - Auto-terminate a previous running instance of this
--                  script before relaunching (reaper.set_action_options).
--                  Without this, relaunching while an earlier instance's
--                  window was still open -- e.g. mid-development, running
--                  the script again after an edit -- left two ImGui
--                  contexts both Begin()'ing a window with the same
--                  title, which corrupts Dear ImGui's window stack and
--                  throws "ImGui_End: Calling End() too many times!" on
--                  every frame after.
--   08/28/26 v1.1 - Added secondary (tab) accent color, body/mono font
--                  name + size, and Export/Import.
--   08/28/26 v1.0 - Initial release

if not reaper.ImGui_GetBuiltinPath then
  reaper.ShowMessageBox("ReaImGui is required for this script.", "Missing Dependency", 0)
  return
end

-- flag&1: auto-terminate a previous running instance of this script.
-- flag&2: relaunch (this new invocation) after doing so, rather than just
-- terminating and stopping. Requires REAPER >= 7.03.
reaper.set_action_options(1 | 2)

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local script_path = ({reaper.get_action_context()})[2]
local script_dir  = script_path:match("^(.*[/\\])")
local PATH_SEP    = reaper.GetOS():find("Win") and "\\" or "/"
local PRESETS_DIR = script_dir .. "Presets" .. PATH_SEP

-- Lives right next to ReaImGuiTheme.lua, so no "../Common" fallback needed
-- the way scripts elsewhere in the repo require it.
local theme = dofile(script_dir .. "ReaImGuiTheme.lua")

local ctx = ImGui.CreateContext('Schapps ReaImGUI Theme Settings')

-- Backing values for the preview widgets below -- purely cosmetic (nothing
-- reads them), just so the checkbox/slider/tabs are interactive rather
-- than frozen, letting both accents be seen in every state (checked,
-- dragged, selected tab) without leaving the settings window.
local preview_checked = true
local preview_slider = 0.5

-- Preview tabs for theme.TabBar below -- in-memory only, nothing persists
-- to disk, so every opts callback is either a no-op or touches only this
-- local table. This is the same tab bar every other theme-using script's
-- template/preset/style list now renders with (Smart Export, Export
-- Video, Text Overlay), not a separate plain BeginTabItem stand-in, so
-- what's previewed here is what those actually look like.
local preview_tabs = {
  {name = "Tab One", tab_color = 0},
  {name = "Tab Two", tab_color = 0},
}
local preview_active_idx = 1

local function preview_name_in_use(name, exclude_idx)
  for i, t in ipairs(preview_tabs) do
    if t.name == name and i ~= (exclude_idx or -1) then return true end
  end
  return false
end

local PREVIEW_TAB_BAR_OPTS = {
  item_noun     = "Tab",
  app_name      = "Schapps ReaImGUI Theme Settings",
  new_name_base = "New Tab",
  name_in_use   = preview_name_in_use,
  save          = function() end,
  on_create     = function(active_tab) return {tab_color = active_tab.tab_color} end,
  on_click_select  = function() end,
  on_after_create  = function() end,
  on_after_delete  = function() end,
  on_delete        = function() end,
  on_rename        = function() end,
}

-- Font picker options -- same list NVK's theme editor offers.
local FONT_OPTIONS = {"Verdana", "Arial", "Tahoma", "Trebuchet MS", "Menlo", "sans-serif", "serif", "monospace"}
local FONT_OPTIONS_STR = table.concat(FONT_OPTIONS, "\0") .. "\0"

local function font_option_index(name)
  for i, option in ipairs(FONT_OPTIONS) do
    if option == name then return i - 1 end
  end
  return 0
end

-- Status line shown under the Export/Import buttons after the last
-- attempt (success or failure), so mistakes aren't just a silent no-op.
local status_text, status_is_error

local function browse_for_save_path(default_name)
  reaper.RecursiveCreateDirectory(PRESETS_DIR, 0)
  if reaper.JS_Dialog_BrowseForSaveFile then
    local ret, path = reaper.JS_Dialog_BrowseForSaveFile(
      "Export Schapps ReaImGUI Theme", PRESETS_DIR, default_name, "Schapps Theme (*.spstheme)")
    if ret == 1 and path ~= "" then
      if not path:match("%.spstheme$") then path = path .. ".spstheme" end
      return path
    end
    return nil
  end

  -- No JS_ReaScriptAPI extension installed -- fall back to a plain
  -- filename prompt into the Presets folder instead of hard-requiring
  -- the extension just to save a settings file.
  local ok, csv = reaper.GetUserInputs("Export Schapps ReaImGUI Theme", 1, "File name:", default_name)
  if not ok or csv == "" then return nil end
  if not csv:match("%.spstheme$") then csv = csv .. ".spstheme" end
  return PRESETS_DIR .. csv
end

local function browse_for_open_path()
  reaper.RecursiveCreateDirectory(PRESETS_DIR, 0)
  local ret, path = reaper.GetUserFileNameForRead(PRESETS_DIR, "Import Schapps ReaImGUI Theme", "spstheme")
  if ret and path ~= "" then return path end
  return nil
end

-- No collapse button (WindowFlags_NoCollapse) and no persisted position/
-- size/collapsed state (WindowFlags_NoSavedSettings): collapsing this
-- window was observed to corrupt ReaImGui's native window state badly
-- enough that every subsequent launch immediately hit "ImGui_End:
-- Calling End() too many times!" until REAPER itself was restarted --
-- that's state living in the extension's C++ side, not anything this
-- script's Lua controls, so removing the trigger is the only fix
-- available at this level.
local WIN_FLAGS = ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_NoSavedSettings

local function Loop()
  ImGui.SetNextWindowSize(ctx, 460, 560, ImGui.Cond_FirstUseEver)
  local color_count, var_count = theme.Push(ctx)
  local visible, open = ImGui.Begin(ctx, 'Schapps ReaImGUI Theme Settings', true, WIN_FLAGS)

  if visible then
    -- ============================================================
    -- Accent colors
    -- ============================================================
    ImGui.Text(ctx, "Accent Colors")
    ImGui.Spacing(ctx)

    ImGui.TextDisabled(ctx, "Primary -- checkboxes, sliders, primary action buttons")
    local accent = theme.GetAccentColor()
    local accent_changed, new_accent = ImGui.ColorEdit4(ctx, "##accent_color", accent, ImGui.ColorEditFlags_AlphaBar)
    if accent_changed then theme.SetAccentColor(new_accent) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reset##accent") then theme.ResetAccentColor() end

    ImGui.TextDisabled(ctx, "Secondary -- secondary action buttons")
    local secondary = theme.GetSecondaryAccentColor()
    local secondary_changed, new_secondary = ImGui.ColorEdit4(ctx, "##secondary_accent_color", secondary, ImGui.ColorEditFlags_AlphaBar)
    if secondary_changed then theme.SetSecondaryAccentColor(new_secondary) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reset##secondary") then theme.ResetSecondaryAccentColor() end

    ImGui.TextDisabled(ctx, "Table Row Stripe -- every other row in a TableFlags_RowBg table")
    local row_alt = theme.GetTableRowAltColor()
    local row_alt_changed, new_row_alt = ImGui.ColorEdit4(ctx, "##table_row_alt_color", row_alt, ImGui.ColorEditFlags_AlphaBar)
    if row_alt_changed then theme.SetTableRowAltColor(new_row_alt) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reset##table_row_alt") then theme.ResetTableRowAltColor() end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- ============================================================
    -- Fonts
    -- ============================================================
    ImGui.Text(ctx, "Fonts")
    ImGui.Spacing(ctx)

    ImGui.SetNextItemWidth(ctx, 130)
    local body_idx_changed, new_body_idx = ImGui.Combo(ctx, "Body Font", font_option_index(theme.GetBodyFontName()), FONT_OPTIONS_STR)
    if body_idx_changed then theme.SetBodyFontName(FONT_OPTIONS[new_body_idx + 1]) end
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 80)
    local body_size_changed, new_body_size = ImGui.SliderInt(ctx, "Size##body_size", theme.GetBodyFontSize(), 8, 32)
    if body_size_changed then theme.SetBodyFontSize(new_body_size) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reset##body_font") then
      theme.ResetBodyFontName()
      theme.ResetBodyFontSize()
    end

    ImGui.SetNextItemWidth(ctx, 130)
    local mono_idx_changed, new_mono_idx = ImGui.Combo(ctx, "Mono Font", font_option_index(theme.GetMonoFontName()), FONT_OPTIONS_STR)
    if mono_idx_changed then theme.SetMonoFontName(FONT_OPTIONS[new_mono_idx + 1]) end
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 80)
    local mono_size_changed, new_mono_size = ImGui.SliderInt(ctx, "Size##mono_size", theme.GetMonoFontSize(), 8, 32)
    if mono_size_changed then theme.SetMonoFontSize(new_mono_size) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reset##mono_font") then
      theme.ResetMonoFontName()
      theme.ResetMonoFontSize()
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- ============================================================
    -- Preview
    -- ============================================================
    ImGui.TextDisabled(ctx, "Preview")
    ImGui.Spacing(ctx)

    _, preview_checked = ImGui.Checkbox(ctx, "Checkbox", preview_checked)
    _, preview_slider = ImGui.SliderDouble(ctx, "Slider", preview_slider, 0, 1)

    preview_active_idx = theme.TabBar(ctx, "##preview_tabs", preview_tabs, preview_active_idx, PREVIEW_TAB_BAR_OPTS)
    ImGui.TextDisabled(ctx, "Right-click a tab for color/rename/delete, or + to add one")

    if ImGui.BeginTable(ctx, "##preview_table", 2, ImGui.TableFlags_RowBg) then
      for i = 1, 4 do
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        ImGui.Text(ctx, "Row " .. i)
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.Text(ctx, "Value " .. i)
      end
      ImGui.EndTable(ctx)
    end

    theme.PushMonoFont(ctx)
    ImGui.Text(ctx, "Monospace 0123456789")
    theme.PopMonoFont(ctx)

    ImGui.Spacing(ctx)
    local avail_w = select(1, ImGui.GetContentRegionAvail(ctx))
    local sp_x = select(1, ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing))
    local half_w = (avail_w - sp_x) / 2
    theme.PrimaryButton(ctx, "Primary Button", half_w)
    ImGui.SameLine(ctx)
    theme.SecondaryButton(ctx, "Secondary Button", half_w)

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- ============================================================
    -- Export / Import
    -- ============================================================
    ImGui.Text(ctx, "Export / Import")
    ImGui.Spacing(ctx)

    if ImGui.Button(ctx, "Export...") then
      local path = browse_for_save_path("MyTheme.spstheme")
      if path then
        local ok, err = theme.ExportSettings(path)
        status_text, status_is_error = ok and ("Exported to " .. path) or ("Export failed: " .. tostring(err)), not ok
      end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Import...") then
      local path = browse_for_open_path()
      if path then
        local ok, err = theme.ImportSettings(path)
        if ok then
          status_text, status_is_error = "Imported " .. path, false
        else
          status_text, status_is_error = "Import failed: " .. tostring(err), true
        end
      end
    end

    if status_text then
      ImGui.Spacing(ctx)
      if status_is_error then
        ImGui.TextColored(ctx, 0xFF6B6BFF, status_text)
      else
        ImGui.TextDisabled(ctx, status_text)
      end
    end
  end

  ImGui.End(ctx)
  theme.Pop(ctx, color_count, var_count)

  if open then
    reaper.defer(Loop)
  end
end

reaper.defer(Loop)
