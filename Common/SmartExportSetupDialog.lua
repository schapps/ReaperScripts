-- Shared ReaImGui "export destination" dialog for the Smart Export Selected Items
-- scripts (Items/Smart Export Selected Items.lua and its companion Configure action).
-- Not a standalone script -- dofile() this and call the returned .Show(opts).

local M = {}

-- opts = {
--   script_dir        = string  -- trailing-slash dir of the calling script
--   initial_dir       = string
--   initial_pattern   = string
--   save_config       = function(dir, pattern)  -- persists the chosen values
--   save_button_label = string  -- optional, defaults to "Save"
--   on_saved          = function(dir, pattern)  -- optional, called after saving
-- }
function M.Show(opts)
  if not reaper.ImGui_GetBuiltinPath then
    reaper.ShowMessageBox("ReaImGUI is required for this setup dialog.\nInstall it via ReaPack.", "Missing dependency", 0)
    return
  end

  package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
  local ImGui = require 'imgui' '0.10'

  local theme_path = opts.script_dir .. "Common/ReaImGuiTheme.lua"
  if not reaper.file_exists(theme_path) then
    theme_path = opts.script_dir .. "../Common/ReaImGuiTheme.lua"
  end
  local theme = dofile(theme_path)

  local script_title = "SMART EXPORT SETUP"
  local ctx = ImGui.CreateContext(script_title)

  local WIN_FLAGS = ImGui.WindowFlags_NoScrollbar
                 | ImGui.WindowFlags_NoCollapse
                 | ImGui.WindowFlags_AlwaysAutoResize
                 | ImGui.WindowFlags_NoScrollWithMouse

  local dir_buf     = opts.initial_dir
  local pattern_buf = opts.initial_pattern
  local open        = true
  local saved       = false

  local function loop()
    local color_count, var_count = theme.Push(ctx)

    ImGui.SetNextWindowSize(ctx, 480, 0, ImGui.Cond_FirstUseEver)
    local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

    if visible then
      if ImGui.BeginTable(ctx, "##fields", 2) then
        ImGui.TableSetupColumn(ctx, "##input", ImGui.TableColumnFlags_WidthStretch)
        ImGui.TableSetupColumn(ctx, "##label", ImGui.TableColumnFlags_WidthFixed, 100)

        -- Output directory
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        ImGui.SetNextItemWidth(ctx, -1)
        local _, new_dir = ImGui.InputText(ctx, "##dir", dir_buf)
        dir_buf = new_dir
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.Text(ctx, "Output Dir")

        -- Filename pattern
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        ImGui.SetNextItemWidth(ctx, -1)
        local _, new_pattern = ImGui.InputText(ctx, "##pattern", pattern_buf)
        pattern_buf = new_pattern
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.Text(ctx, "Filename")

        ImGui.EndTable(ctx)
      end

      ImGui.Spacing(ctx)

      -- Browse button (requires js_ReaScriptAPI)
      if reaper.JS_Dialog_BrowseForFolder then
        if ImGui.Button(ctx, "Browse...", 0, 0) then
          local retval, folder = reaper.JS_Dialog_BrowseForFolder("Select Export Folder", dir_buf)
          if retval == 1 then dir_buf = folder end
        end
        ImGui.SameLine(ctx)
      end

      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
      ImGui.Text(ctx, "Tokens: $item  $project  $projectpath  $user  $date")
      ImGui.PopStyleColor(ctx)

      ImGui.Spacing(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)

      local function do_save()
        open  = false
        saved = true
        opts.save_config(dir_buf, pattern_buf)
      end

      if ImGui.Button(ctx, opts.save_button_label or "Save", -1, 0) then
        do_save()
      end

      if ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter) then
        do_save()
      end

      ImGui.End(ctx)
    else
      open = false
    end

    theme.Pop(ctx, color_count, var_count)

    if still_open and open then
      reaper.defer(loop)
    elseif saved and opts.on_saved then
      opts.on_saved(dir_buf, pattern_buf)
    end
  end

  reaper.defer(loop)
end

return M
