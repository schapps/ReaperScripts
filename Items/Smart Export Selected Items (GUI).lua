-- @description Smart Export Selected Items (GUI)
-- @version 1.0
-- @about
--   ReaImGUI render-template dialog for Smart Export Selected Items.
--   Supports multiple named render templates (tabs), normalization controls,
--   and folder browsing. Run the companion headless script to re-export using
--   the last-active template without the GUI appearing.
--   SWS extension is required.
-- @author Stephen Schappler
-- @link https://www.stephenschappler.com
-- @changelog
--   05/28/26 v1.0 - Initial release

-- ============================================================
-- Dependency checks
-- ============================================================
if not reaper.SNM_SetIntConfigVar then
  reaper.ShowMessageBox(
    "The SWS extension is required but not installed.\nDownload it from https://www.sws-extension.org",
    "Missing dependency", 0)
  return
end

if not reaper.ImGui_GetBuiltinPath then
  reaper.ShowMessageBox("ReaImGui is required for this script.", "Missing Dependency", 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

-- ============================================================
-- Paths
-- ============================================================
local script_path = ({reaper.get_action_context()})[2]
local script_dir  = script_path:match("^(.*[/\\])")
local tpl_dir     = script_dir .. "Smart Export Templates" .. (reaper.GetOS():find("Win") and "\\" or "/")

local theme_path = script_dir .. "Common/ReaImGuiTheme.lua"
if not reaper.file_exists(theme_path) then
  theme_path = script_dir .. "../Common/ReaImGuiTheme.lua"
end
local theme = dofile(theme_path)

-- ============================================================
-- Template I/O
-- ============================================================
local DEFAULTS = {
  name                 = "Default",
  render_output_dir    = "",
  render_output_pattern= "$project\\$item",
  normalize_enabled    = false,
  normalize_mode       = "lufs_i",
  normalize_target_db  = -24.0,
  tail_ms              = 2000,
}

local function ensure_tpl_dir()
  reaper.RecursiveCreateDirectory(tpl_dir, 0)
end

local function save_template(t)
  ensure_tpl_dir()
  local path = tpl_dir .. t.name .. ".lua"
  local f = io.open(path, "w")
  if not f then
    reaper.ShowMessageBox("Could not write template:\n" .. path, "Smart Export", 0)
    return
  end
  f:write("-- Smart Export Template\n")
  f:write("name                  = " .. string.format("%q", t.name)                  .. "\n")
  f:write("render_output_dir     = " .. string.format("%q", t.render_output_dir)     .. "\n")
  f:write("render_output_pattern = " .. string.format("%q", t.render_output_pattern) .. "\n")
  f:write("normalize_enabled     = " .. tostring(t.normalize_enabled)                .. "\n")
  f:write("normalize_mode        = " .. string.format("%q", t.normalize_mode)        .. "\n")
  f:write("normalize_target_db   = " .. tostring(t.normalize_target_db)              .. "\n")
  f:write("tail_ms               = " .. tostring(t.tail_ms)                          .. "\n")
  f:close()
end

local function load_template_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*all")
  f:close()
  local t = {}
  local env = setmetatable({}, {
    __index    = _G,
    __newindex = function(_, k, v) t[k] = v end,
  })
  local chunk
  if _VERSION == "Lua 5.1" then
    chunk = loadstring(content) -- luacheck: ignore
    if chunk then setfenv(chunk, env) end -- luacheck: ignore
  else
    chunk = load(content, "template", "t", env)
  end
  if not chunk then return nil end
  pcall(chunk)
  for k, v in pairs(DEFAULTS) do
    if t[k] == nil then t[k] = v end
  end
  return t
end

local function list_templates()
  local list = {}
  local i = 0
  while true do
    local file = reaper.EnumerateFiles(tpl_dir, i)
    if not file then break end
    if file:match("%.lua$") and not file:match("^%.") then
      local name = file:gsub("%.lua$", "")
      local t = load_template_file(tpl_dir .. file)
      if t then
        t.name = name
        table.insert(list, t)
      end
    end
    i = i + 1
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

local function delete_template(name)
  os.remove(tpl_dir .. name .. ".lua")
end

local function rename_template_file(old_name, new_name)
  local t = load_template_file(tpl_dir .. old_name .. ".lua")
  if not t then return false end
  t.name = new_name
  save_template(t)
  delete_template(old_name)
  return true
end

-- ============================================================
-- Normalize helpers
-- ============================================================
local function db_to_linear(db) return 10 ^ (db / 20) end

local function normalize_bits(t)
  if not t.normalize_enabled then return 0 end
  local bits = 0x1  -- enable
  if t.normalize_mode == "lufs_m" then bits = bits | 0x8 end
  return bits
end

-- ============================================================
-- Bootstrap: seed a Default template on first run
-- ============================================================
local function bootstrap_default_template()
  ensure_tpl_dir()
  local t = {}
  for k, v in pairs(DEFAULTS) do t[k] = v end

  -- Seed from existing user config file if it exists
  local config_path = script_dir .. "Smart Export Selected Items - User Config.lua"
  if reaper.file_exists(config_path) then
    local cfg = load_template_file(config_path)
    if cfg then
      t.render_output_dir     = cfg.render_output_dir     or t.render_output_dir
      t.render_output_pattern = cfg.render_output_pattern or t.render_output_pattern
    end
  end

  save_template(t)
  return t
end

-- ============================================================
-- Render settings + export
-- ============================================================
local function apply_render_settings(t)
  local SETTINGS_MASK = 0x7FFF
  local render_settings = 596  -- selected items via master + embed metadata + mono→mono + multichannel

  reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT',  'ZXZhdxgGAA==', true)
  reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT2', '',             true)
  reaper.GetSetProjectInfo(0, 'RENDER_SRATE',    96000, true)
  reaper.GetSetProjectInfo(0, 'RENDER_CHANNELS', 2,     true)
  reaper.GetSetProjectInfo(0, 'RENDER_DITHER',   0,     true)

  local cur = reaper.GetSetProjectInfo(0, 'RENDER_SETTINGS', 0, false)
  reaper.GetSetProjectInfo(0, 'RENDER_SETTINGS',
    (render_settings & SETTINGS_MASK) | (cur & ~SETTINGS_MASK), true)

  reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 4,        true)
  reaper.GetSetProjectInfo(0, 'RENDER_STARTPOS',   0,        true)
  reaper.GetSetProjectInfo(0, 'RENDER_ENDPOS',     0,        true)
  reaper.GetSetProjectInfo(0, 'RENDER_TAILFLAG',   0,        true)
  reaper.GetSetProjectInfo(0, 'RENDER_TAILMS',     t.tail_ms, true)

  reaper.GetSetProjectInfo(0, 'RENDER_NORMALIZE',        normalize_bits(t),                  true)
  reaper.GetSetProjectInfo(0, 'RENDER_NORMALIZE_TARGET', db_to_linear(t.normalize_target_db), true)
  reaper.GetSetProjectInfo(0, 'RENDER_BRICKWALL', 1, true)

  reaper.GetSetProjectInfo(0, 'RENDER_FADEIN',       0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEOUT',      0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEINSHAPE',  1, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEOUTSHAPE', 1, true)
  reaper.GetSetProjectInfo(0, 'RENDER_TRIMSTART',    0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_TRIMEND',      0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_PADSTART',     0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_PADEND',       0, true)

  reaper.GetSetProjectInfo_String(0, 'RENDER_FILE',    t.render_output_dir,     true)
  reaper.GetSetProjectInfo_String(0, 'RENDER_PATTERN', t.render_output_pattern, true)

  reaper.SNM_SetIntConfigVar('projrenderlimit',        0)
  reaper.SNM_SetIntConfigVar('projrenderrateinternal', 1)
  reaper.SNM_SetIntConfigVar('projrenderresample',     10)
end

local function run_export(t)
  local num_selected = reaper.CountSelectedMediaItems(0)
  if num_selected == 0 then
    reaper.ShowMessageBox('No media items selected.', 'Error', 0)
    return
  end

  local selected_guids = {}
  for i = 0, num_selected - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    table.insert(selected_guids, reaper.BR_GetMediaItemGUID(item))
  end

  local item_list = {}
  local mismatches = {}
  for i = 0, num_selected - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local source = reaper.GetMediaItemTake_Source(take)
      local src_ch = reaper.GetMediaSourceNumChannels(source)
      local track = reaper.GetMediaItem_Track(item)
      local trk_ch = track and reaper.GetMediaTrackInfo_Value(track, "I_NCHAN") or 0
      if src_ch > 2 and trk_ch ~= src_ch then
        local _, trk_name = reaper.GetTrackName(track)
        trk_name = (trk_name ~= "" and trk_name) or "(unnamed track)"
        local _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        take_name = (take_name ~= "" and take_name) or "(untitled take)"
        table.insert(mismatches, ("Track '%s' has %d ch, item '%s' has %d ch."):format(
          trk_name, trk_ch, take_name, src_ch))
      end
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      table.insert(item_list, {
        item = item, take = take,
        start_pos = pos, end_pos = pos + len,
        name = name, source_num_channels = src_ch,
      })
    else
      reaper.ShowMessageBox(
        'No active take or take is MIDI for item at position '
          .. reaper.GetMediaItemInfo_Value(item, 'D_POSITION'), 'Error', 0)
    end
  end

  if #mismatches > 0 then
    reaper.ShowMessageBox(
      table.concat(mismatches, "\n")
        .. "\n\nSet the track channel count to match multichannel items before exporting.",
      "Item/Track Channel Mismatch", 0)
    return
  end

  reaper.Undo_BeginBlock()

  local by_name = {}
  for _, info in ipairs(item_list) do
    local n = info.name or ""
    if not by_name[n] then by_name[n] = {} end
    table.insert(by_name[n], info)
  end

  local overlap_groups, solo_items = {}, {}
  for _, items in pairs(by_name) do
    local checked = {}
    for i, a in ipairs(items) do
      if not checked[a] then
        local grp = {a}; checked[a] = true
        for j = i + 1, #items do
          local b = items[j]
          if not checked[b] and a.start_pos < b.end_pos and b.start_pos < a.end_pos then
            table.insert(grp, b); checked[b] = true
          end
        end
        if #grp > 1 then table.insert(overlap_groups, grp)
        else              table.insert(solo_items, a) end
      end
    end
  end

  for _, grp in ipairs(overlap_groups) do
    reaper.Main_OnCommand(40289, 0)
    for _, info in ipairs(grp) do reaper.SetMediaItemSelected(info.item, true) end
    reaper.Main_OnCommand(41588, 0)
    local glued = reaper.GetSelectedMediaItem(0, 0)
    if glued then
      local glued_take = reaper.GetActiveTake(glued)
      reaper.GetSetMediaItemTakeInfo_String(glued_take, "P_NAME", grp[1].name, true)
      apply_render_settings(t)
      reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 2, true)
      reaper.Main_OnCommand(41824, 0)
      reaper.Undo_DoUndo2(0)
    end
  end

  if #solo_items > 0 then
    apply_render_settings(t)
    reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 2, true)
    reaper.Main_OnCommand(40289, 0)
    for _, info in ipairs(solo_items) do reaper.SetMediaItemSelected(info.item, true) end
    reaper.Main_OnCommand(41824, 0)
  end

  reaper.Main_OnCommand(40289, 0)
  for _, guid in ipairs(selected_guids) do
    local item = reaper.BR_GetMediaItemByGUID(0, guid)
    if item then reaper.SetMediaItemSelected(item, true) end
  end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Smart Render Selected Items', -1)
end

-- ============================================================
-- ImGui context
-- ============================================================
local script_title = "SMART EXPORT"
local ctx = ImGui.CreateContext(script_title)

local WIN_FLAGS = ImGui.WindowFlags_NoScrollbar
               | ImGui.WindowFlags_NoCollapse
               | ImGui.WindowFlags_AlwaysAutoResize
               | ImGui.WindowFlags_NoScrollWithMouse

-- ============================================================
-- Template state
-- ============================================================
local templates     = {}
local active_idx    = 1

-- Live edit buffers (synced from/to active template)
local dir_buf       = ""
local pattern_buf   = ""
local norm_en       = false
local norm_mode     = "lufs_i"
local norm_db_buf   = "-24.0"
local tail_buf      = "2000"

-- Rename modal state
local rename_pending    = false
local rename_focus_next = false  -- call SetKeyboardFocusHere exactly once when modal opens
local rename_idx        = 1
local rename_buf        = ""
local rename_dup_err    = false

-- Pending delete (deferred one frame to avoid mid-render table mutation)
local delete_pending = false
local delete_idx     = 1

local last_active_idx = 0  -- sentinel; forces first-frame buffer sync
local open = true

-- ============================================================
-- Buffer helpers
-- ============================================================
local function sync_buffers_from(t)
  dir_buf     = t.render_output_dir
  pattern_buf = t.render_output_pattern
  norm_en     = t.normalize_enabled
  norm_mode   = t.normalize_mode
  norm_db_buf = tostring(t.normalize_target_db)
  tail_buf    = tostring(t.tail_ms)
end

local function flush_buffers_to(t)
  t.render_output_dir     = dir_buf
  t.render_output_pattern = pattern_buf
  t.normalize_enabled     = norm_en
  t.normalize_mode        = norm_mode
  t.normalize_target_db   = tonumber(norm_db_buf) or t.normalize_target_db
  t.tail_ms               = tonumber(tail_buf)    or t.tail_ms
end

-- ============================================================
-- Init templates
-- ============================================================
local function name_in_use(name, exclude_idx)
  for i, t in ipairs(templates) do
    if t.name == name and i ~= (exclude_idx or -1) then return true end
  end
  return false
end

local function init_templates()
  ensure_tpl_dir()
  templates = list_templates()
  if #templates == 0 then
    table.insert(templates, bootstrap_default_template())
  end

  local saved_name = reaper.GetExtState("SmartExport", "active_template")
  active_idx = 1
  if saved_name ~= "" then
    for i, t in ipairs(templates) do
      if t.name == saved_name then active_idx = i; break end
    end
  end

  sync_buffers_from(templates[active_idx])
  last_active_idx = active_idx
end

init_templates()

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  local color_count, var_count = theme.Push(ctx)

  local WIN_W = 500
  ImGui.SetNextWindowSizeConstraints(ctx, WIN_W, 0, WIN_W, 10000)
  ImGui.SetNextWindowSize(ctx, WIN_W, 0, ImGui.Cond_FirstUseEver)
  local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then

    -- ── Tab bar ─────────────────────────────────────────────
    if ImGui.BeginTabBar(ctx, "##templates", ImGui.TabBarFlags_AutoSelectNewTabs) then

      for i, t in ipairs(templates) do
        -- tab_visible = this tab's content should be drawn this frame
        -- new_open    = false when the user clicks the × close button
        local tab_visible, new_open = ImGui.BeginTabItem(ctx, t.name, true, 0)

        -- Right-click → context menu (must be called right after BeginTabItem)
        if ImGui.BeginPopupContextItem(ctx, "##ctx_" .. i) then
          if ImGui.MenuItem(ctx, "Rename\u{2026}") then
            rename_pending  = true
            rename_idx      = i
            rename_buf      = t.name
            rename_dup_err  = false
          end
          local can_delete = #templates > 1
          if not can_delete then ImGui.BeginDisabled(ctx, true) end
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF5555FF)
          if ImGui.MenuItem(ctx, "Delete") then
            delete_pending = true
            delete_idx     = i
          end
          ImGui.PopStyleColor(ctx)
          if not can_delete then ImGui.EndDisabled(ctx) end
          ImGui.EndPopup(ctx)
        end

        -- Handle close-button click (× on the tab)
        if not new_open and #templates > 1 then
          delete_pending = true
          delete_idx     = i
        end

        if tab_visible then
          -- Switching tabs: flush old, sync new
          if i ~= last_active_idx then
            if last_active_idx >= 1 and last_active_idx <= #templates then
              flush_buffers_to(templates[last_active_idx])
            end
            active_idx      = i
            last_active_idx = i
            sync_buffers_from(t)
          end
          ImGui.EndTabItem(ctx)
        end
      end

      -- "+" button: create a new template (TabItemButton = clickable, doesn't steal content area)
      if ImGui.TabItemButton(ctx, "+", ImGui.TabItemFlags_Trailing) then
        flush_buffers_to(templates[active_idx])

        local base = "New Template"
        local new_name = base
        local suffix = 2
        while name_in_use(new_name) do
          new_name = base .. " " .. suffix; suffix = suffix + 1
        end

        local src = templates[active_idx]
        local new_t = {}
        for k, v in pairs(src) do new_t[k] = v end
        new_t.name = new_name
        save_template(new_t)
        table.insert(templates, new_t)

        active_idx      = #templates
        last_active_idx = #templates
        sync_buffers_from(new_t)

        -- Open rename modal immediately so the user can name it
        rename_pending    = true
        rename_focus_next = true
        rename_idx        = active_idx
        rename_buf        = new_name
        rename_dup_err    = false
      end

      ImGui.EndTabBar(ctx)
    end

    -- ── Settings fields ──────────────────────────────────────
    if ImGui.BeginTable(ctx, "##fields", 2) then
      ImGui.TableSetupColumn(ctx, "##input", ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableSetupColumn(ctx, "##label", ImGui.TableColumnFlags_WidthFixed, 110)

      -- Output Dir
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local has_browse = reaper.JS_Dialog_BrowseForFolder ~= nil
      local browse_w = has_browse and 80 or 0
      ImGui.SetNextItemWidth(ctx, browse_w > 0 and -(browse_w + 6) or -1)
      local _, new_dir = ImGui.InputText(ctx, "##dir", dir_buf)
      dir_buf = new_dir
      if has_browse then
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Browse\u{2026}", browse_w, 0) then
          local ok, folder = reaper.JS_Dialog_BrowseForFolder("Select Export Folder", dir_buf)
          if ok == 1 then dir_buf = folder end
        end
      end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Output Dir")

      -- Filename pattern
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, new_pat = ImGui.InputText(ctx, "##pattern", pattern_buf)
      pattern_buf = new_pat
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Filename")

      -- Normalize
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local _, new_norm_en = ImGui.Checkbox(ctx, "##norm_en", norm_en)
      norm_en = new_norm_en
      ImGui.SameLine(ctx)
      if not norm_en then ImGui.BeginDisabled(ctx, true) end
      local mode_label = norm_mode == "lufs_m" and "LUFS-M" or "LUFS-I"
      ImGui.SetNextItemWidth(ctx, 78)
      if ImGui.BeginCombo(ctx, "##norm_mode", mode_label, 0) then
        if ImGui.Selectable(ctx, "LUFS-I", norm_mode == "lufs_i", 0) then norm_mode = "lufs_i" end
        if ImGui.Selectable(ctx, "LUFS-M", norm_mode == "lufs_m", 0) then norm_mode = "lufs_m" end
        ImGui.EndCombo(ctx)
      end
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 58)
      local _, new_db = ImGui.InputText(ctx, "##norm_db", norm_db_buf,
        ImGui.InputTextFlags_CharsDecimal)
      norm_db_buf = new_db
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, "dB")
      if not norm_en then ImGui.EndDisabled(ctx) end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Normalize")

      -- Tail
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, new_tail = ImGui.InputText(ctx, "##tail", tail_buf,
        ImGui.InputTextFlags_CharsDecimal)
      tail_buf = new_tail
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Tail (ms)")

      ImGui.EndTable(ctx)
    end

    -- Token hint
    ImGui.Spacing(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, "Tokens: $item  $project  $projectpath  $user  $date")
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Status
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    local n_items = reaper.CountSelectedMediaItems(0)
    ImGui.Text(ctx, ("%d %s selected for export"):format(
      n_items, n_items == 1 and "item" or "items"))
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)

    -- Render button
    local no_items = n_items == 0
    if no_items then ImGui.BeginDisabled(ctx, true) end

    local do_render = ImGui.Button(ctx, "Render", -1, 0)
      or (not no_items and (
            ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
            or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)))

    if no_items then ImGui.EndDisabled(ctx) end

    if do_render then
      flush_buffers_to(templates[active_idx])
      local t = templates[active_idx]
      save_template(t)
      reaper.SetExtState("SmartExport", "active_template", t.name, true)
      open = false
      run_export(t)
    end

    ImGui.End(ctx)
  end

  -- ── Rename modal ─────────────────────────────────────────
  if rename_pending then
    ImGui.OpenPopup(ctx, "Rename Template##modal")
    rename_pending    = false
    rename_focus_next = true
  end

  if ImGui.BeginPopupModal(ctx, "Rename Template##modal", nil,
      ImGui.WindowFlags_AlwaysAutoResize) then
    ImGui.Text(ctx, "Template name:")
    ImGui.SetNextItemWidth(ctx, 280)
    if rename_focus_next then
      ImGui.SetKeyboardFocusHere(ctx)
      rename_focus_next = false
    end
    local _, new_rb = ImGui.InputText(ctx, "##rename_val", rename_buf,
      ImGui.InputTextFlags_AutoSelectAll)
    rename_buf = new_rb

    if rename_dup_err then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF5555FF)
      ImGui.Text(ctx, "Name already in use.")
      ImGui.PopStyleColor(ctx)
    end

    ImGui.Spacing(ctx)

    local confirm = ImGui.Button(ctx, "OK", 130, 0)
      or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
      or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)

    ImGui.SameLine(ctx)

    if ImGui.Button(ctx, "Cancel", 130, 0) or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      ImGui.CloseCurrentPopup(ctx)
      rename_dup_err = false
    elseif confirm and rename_buf ~= "" then
      if name_in_use(rename_buf, rename_idx) then
        rename_dup_err = true
      else
        local old_name = templates[rename_idx].name
        if old_name ~= rename_buf then
          rename_template_file(old_name, rename_buf)
          -- If this was the active template, update ExtState
          if rename_idx == active_idx then
            reaper.SetExtState("SmartExport", "active_template", rename_buf, true)
          end
        end
        templates[rename_idx].name = rename_buf
        ImGui.CloseCurrentPopup(ctx)
        rename_dup_err = false
      end
    end

    ImGui.EndPopup(ctx)
  end

  -- ── Pending delete ────────────────────────────────────────
  if delete_pending then
    delete_pending = false
    local name = templates[delete_idx] and templates[delete_idx].name or "?"
    local answer = reaper.ShowMessageBox(
      ('Delete template "%s"? This cannot be undone.'):format(name),
      "Smart Export", 4)  -- 4 = Yes/No buttons
    if answer == 6 then   -- 6 = Yes
      delete_template(name)
      table.remove(templates, delete_idx)
      if active_idx > delete_idx then
        active_idx = active_idx - 1
      end
      active_idx      = math.max(1, math.min(active_idx, #templates))
      last_active_idx = 0  -- force buffer resync next frame
    end
  end

  theme.Pop(ctx, color_count, var_count)

  if still_open and open then
    reaper.defer(loop)
  end
end

-- ============================================================
-- Entry point
-- ============================================================
reaper.defer(loop)
