local ImGui = require "imgui" "0.10"

local theme = {}

function theme.Push(ctx)
  local colors = {
    {ImGui.Col_Text, 0xE6E6E6FF},
    {ImGui.Col_TextDisabled, 0xA0A0A0FF},
    {ImGui.Col_WindowBg, 0x1B1D1FFF},
    {ImGui.Col_ChildBg, 0x1B1D1FFF},
    {ImGui.Col_PopupBg, 0x202225FF},
    {ImGui.Col_Border, 0x3A3F45FF},
    {ImGui.Col_FrameBg, 0x2A2D31FF},
    {ImGui.Col_FrameBgHovered, 0x343A40FF},
    {ImGui.Col_FrameBgActive, 0x3C434AFF},
    {ImGui.Col_TitleBg, 0x15181BFF},
    {ImGui.Col_TitleBgActive, 0x1E2328FF},
    {ImGui.Col_TitleBgCollapsed, 0x15181BFF},
    {ImGui.Col_ScrollbarBg, 0x1A1C1FFF},
    {ImGui.Col_ScrollbarGrab, 0x3A4046FF},
    {ImGui.Col_ScrollbarGrabHovered, 0x4A545CFF},
    {ImGui.Col_ScrollbarGrabActive, 0x5A6771FF},
    {ImGui.Col_CheckMark, 0x7AD9C4FF},
    {ImGui.Col_SliderGrab, 0x7AD9C4FF},
    {ImGui.Col_SliderGrabActive, 0xA0E6D8FF},
    {ImGui.Col_Button, 0x2C6B64FF},
    {ImGui.Col_ButtonHovered, 0x338077FF},
    {ImGui.Col_ButtonActive, 0x2A5C56FF},
    {ImGui.Col_Header, 0x2C6B64FF},
    {ImGui.Col_HeaderHovered, 0x3A8A81FF},
    {ImGui.Col_HeaderActive, 0x2B6A63FF},
    {ImGui.Col_Separator, 0x3A3F45FF},
    {ImGui.Col_SeparatorHovered, 0x5A7A77FF},
    {ImGui.Col_SeparatorActive, 0x6FA39EFF},
    {ImGui.Col_ResizeGrip, 0x2C6B6499},
    {ImGui.Col_ResizeGripHovered, 0x3A8A81CC},
    {ImGui.Col_ResizeGripActive, 0x2B6A63FF},
  }

  local function add_color_name(enum_name, color)
    local enum_value = rawget(ImGui, enum_name)
    if enum_value ~= nil then
      colors[#colors + 1] = {enum_value, color}
    end
  end

  add_color_name("Col_Tab", 0x23282DFF)
  add_color_name("Col_TabHovered", 0x2F7870FF)
  add_color_name("Col_TabActive", 0x2C6B64FF)
  add_color_name("Col_TabUnfocused", 0x1E2226FF)
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

return theme
