-- @description Schapps ReaImGUI Theme
-- @author Stephen Schappler
-- @version 1.7
-- @about
--   ReaImGUI Theme file for my scripts
-- @link https://www.stephenschappler.com
-- @provides
--   line-md--play-filled.png > line-md--play-filled.png
-- @changelog
--   08/22/26 - v1.7 Added theme.PrimaryButton(ctx, label, width, height): the
--                   purple/bold/1.3x-size "main action" button style (e.g. a
--                   Render or Rename button), lazily creating and caching one
--                   bold font per ctx since fonts must be created once, not
--                   per-frame

local ImGui = require "imgui" "0.10"

local theme = {}

function theme.Push(ctx)
  local colors = {
    {ImGui.Col_Text, 0xE6E6E6FF},
    {ImGui.Col_TextDisabled, 0xA0A0A0FF},
    {ImGui.Col_WindowBg, 0x28282828FF},
    {ImGui.Col_ChildBg, 0x222222FF},
    {ImGui.Col_PopupBg, 0x202225FF},
    {ImGui.Col_Border, 0x3A3F45FF},
    {ImGui.Col_FrameBg, 0x333333FF},
    {ImGui.Col_FrameBgHovered, 0x343A40FF},
    {ImGui.Col_FrameBgActive, 0x3C434AFF},
    {ImGui.Col_TitleBg, 0x222222FF},
    {ImGui.Col_TitleBgActive, 0x333333FF},
    {ImGui.Col_TitleBgCollapsed, 0x15181BFF},
    {ImGui.Col_ScrollbarBg, 0x1A1C1FFF},
    {ImGui.Col_ScrollbarGrab, 0x3A4046FF},
    {ImGui.Col_ScrollbarGrabHovered, 0x4A545CFF},
    {ImGui.Col_ScrollbarGrabActive, 0x5A6771FF},
    {ImGui.Col_CheckMark, 0xa08fe2FF},
    {ImGui.Col_SliderGrab, 0xa08fe2FF},
    {ImGui.Col_SliderGrabActive, 0xa08fe2FF},
    {ImGui.Col_Button, 0x60606066},
    {ImGui.Col_ButtonHovered, 0x606060FF},
    {ImGui.Col_ButtonActive, 0x808080FF},
    {ImGui.Col_Header, 0x60606066},
    {ImGui.Col_HeaderHovered, 0x606060FF},
    {ImGui.Col_HeaderActive, 0x808080FF},
    {ImGui.Col_Separator, 0x80808080},
    {ImGui.Col_SeparatorHovered, 0x808080C7},
    {ImGui.Col_SeparatorActive, 0x808080FF},
    {ImGui.Col_ResizeGrip, 0x60606066},
    {ImGui.Col_ResizeGripHovered, 0x606060FF},
    {ImGui.Col_ResizeGripActive, 0x808080FF},
  }

  local function add_color_name(enum_name, color)
    local enum_value = rawget(ImGui, enum_name)
    if enum_value ~= nil then
      colors[#colors + 1] = {enum_value, color}
    end
  end

  add_color_name("Col_Tab", 0x23282DFF)
  add_color_name("Col_TabHovered", 0x333333FF)
  -- Newer ReaImGui builds renamed these (Col_TabActive -> Col_TabSelected,
  -- Col_TabUnfocused -> Col_TabDimmed, Col_TabUnfocusedActive ->
  -- Col_TabDimmedSelected). add_color_name's rawget guard means only the
  -- name that actually exists on the running build gets pushed, so both the
  -- new and old name are listed here for compatibility -- without this,
  -- these three were silently no-op'ing on newer builds and every active
  -- tab fell back to Dear ImGui's default blue.
  add_color_name("Col_TabSelected", 0x2C6B64FF)
  add_color_name("Col_TabActive", 0x2C6B64FF)
  add_color_name("Col_TabDimmed", 0x1E2226FF)
  add_color_name("Col_TabUnfocused", 0x1E2226FF)
  add_color_name("Col_TabDimmedSelected", 0x273035FF)
  add_color_name("Col_TabUnfocusedActive", 0x273035FF)

  local vars = {
    {ImGui.StyleVar_WindowRounding, 6},
    {ImGui.StyleVar_FrameRounding, 4},
    {ImGui.StyleVar_GrabRounding, 4},
    {ImGui.StyleVar_ScrollbarRounding, 6},
    {ImGui.StyleVar_FramePadding, 10, 6},
    {ImGui.StyleVar_WindowPadding, 12, 10},
    {ImGui.StyleVar_ItemSpacing, 10, 8},
  }

  for _, c in ipairs(colors) do
    ImGui.PushStyleColor(ctx, c[1], c[2])
  end
  for _, v in ipairs(vars) do
    ImGui.PushStyleVar(ctx, v[1], v[2], v[3])
  end

  return #colors, #vars
end

function theme.Pop(ctx, color_count, var_count)
  if var_count and var_count > 0 then
    ImGui.PopStyleVar(ctx, var_count)
  end
  if color_count and color_count > 0 then
    ImGui.PopStyleColor(ctx, color_count)
  end
end

-- ============================================================
-- Chip: small bordered, rounded label -- e.g. a status/category tag on a
-- list row. Not a native ImGui widget, so it's drawn directly on the
-- window's draw list at the current cursor position, then an invisible
-- Dummy of the same size is placed to advance the cursor -- so it composes
-- with SameLine()/etc. like any other small widget.
-- ============================================================
function theme.Chip(ctx, label, text_color, border_color)
  local PAD_X, PAD_Y = 5, 2
  local text_w, text_h = ImGui.CalcTextSize(ctx, label)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local x1, y1 = x0 + text_w + PAD_X * 2, y0 + text_h + PAD_Y * 2

  local draw_list = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRect(draw_list, x0, y0, x1, y1, border_color, 3)
  ImGui.DrawList_AddText(draw_list, x0 + PAD_X, y0 + PAD_Y, text_color, label)

  ImGui.Dummy(ctx, x1 - x0, y1 - y0)
end

-- ============================================================
-- PrimaryButton: the accent-colored, bold, oversized button style used for
-- a screen's main action (Render, Rename, etc.) -- purple fill with dark
-- text, at 1.3x the current font size.
--
-- Needs a bold font object, which (unlike colors/vars) must be created
-- once per ImGui context rather than every frame, so one is lazily created
-- and cached here per-ctx on first use. Keyed with weak references so the
-- cache doesn't keep a closed script's context (and its font) alive.
-- ============================================================
local bold_font_cache = setmetatable({}, {__mode = "k"})

local function get_bold_font(ctx)
  local font = bold_font_cache[ctx]
  if not font then
    font = ImGui.CreateFont("sans-serif", ImGui.FontFlags_Bold)
    ImGui.Attach(ctx, font)
    bold_font_cache[ctx] = font
  end
  return font
end

function theme.PrimaryButton(ctx, label, width, height)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0xA08FE2FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,  0xB3A6E8FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,   0x8D7ACCFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text,           0x222222FF)
  ImGui.PushFont(ctx, get_bold_font(ctx), ImGui.GetFontSize(ctx) * 1.3)

  local clicked = ImGui.Button(ctx, label, width or 0, height or 0)

  ImGui.PopFont(ctx)
  ImGui.PopStyleColor(ctx, 4)

  return clicked
end

return theme
