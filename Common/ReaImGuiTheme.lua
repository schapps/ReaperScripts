-- @description Schapps ReaImGUI Theme
-- @author Stephen Schappler
-- @version 1.8
-- @about
--   ReaImGUI Theme file for my scripts
-- @link https://www.stephenschappler.com
-- @provides
--   line-md--play-filled.png > line-md--play-filled.png
--   Fonts/fa-solid-900.ttf > Fonts/fa-solid-900.ttf
--   Fonts/LICENSE.txt > Fonts/LICENSE.txt
-- @changelog
--   08/22/26 - v1.8 Added Font Awesome icon support: theme.Icons (a curated
--                   table of glyph constants), theme.PushIconFont/PopIconFont,
--                   theme.IconText, and theme.IconButton. The icon font
--                   ships as Fonts/fa-solid-900.ttf alongside this file and
--                   is lazily created/cached per-ctx like the bold font
--                   below, since ReaImGui has no font-merge mode -- icon
--                   glyphs always come from a separate font pushed around
--                   the draw call, not blended into the body-text font.
--                   theme.IconButton/theme.IconButtonSize size the button
--                   square to the requested icon size (default: current
--                   font size) plus frame padding, so a larger icon grows
--                   its button instead of clipping, and callers can still
--                   align one (e.g. right-justify) without pre-measuring.
--   08/22/26 - v1.7 Added theme.PrimaryButton(ctx, label, width, height): the
--                   purple/bold/1.3x-size "main action" button style (e.g. a
--                   Render or Rename button), lazily creating and caching one
--                   bold font per ctx since fonts must be created once, not
--                   per-frame

local ImGui = require "imgui" "0.10"

local theme = {}

-- Directory this file lives in, so the icon font can be found regardless of
-- which script's directory dofile()'d this module.
local SELF_DIR = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"

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

-- ============================================================
-- Icons: Font Awesome 6 Free (solid) glyphs, for use with the icon font
-- helpers below. Add more by looking up the codepoint at
-- https://fontawesome.com/search?o=r&m=free&s=solid and confirming it's in
-- the "solid" style (this repo only ships the solid weight).
-- ============================================================
theme.Icons = {
  SAVE            = "\u{f0c7}", -- fa-floppy-disk
  TRASH           = "\u{f2ed}", -- fa-trash-can
  COPY            = "\u{f0c5}", -- fa-copy
  DUPLICATE       = "\u{f24d}", -- fa-clone
  FOLDER_OPEN     = "\u{f07c}", -- fa-folder-open
  FOLDER          = "\u{f07b}", -- fa-folder
  PLAY            = "\u{f04b}", -- fa-play
  STOP            = "\u{f04d}", -- fa-stop
  PAUSE           = "\u{f04c}", -- fa-pause
  SETTINGS        = "\u{f013}", -- fa-gear
  CLOSE           = "\u{f00d}", -- fa-xmark
  CHECK           = "\u{f00c}", -- fa-check
  CHECK_CIRCLE    = "\u{f058}", -- fa-circle-check
  CLOSE_CIRCLE    = "\u{f057}", -- fa-circle-xmark
  WARNING         = "\u{f071}", -- fa-triangle-exclamation
  INFO            = "\u{f05a}", -- fa-circle-info
  REFRESH         = "\u{f021}", -- fa-arrows-rotate
  SEARCH          = "\u{f002}", -- fa-magnifying-glass
  PLUS            = "\u{2b}",   -- fa-plus
  MINUS           = "\u{f068}", -- fa-minus
  EDIT            = "\u{f044}", -- fa-pen-to-square
  LOCK            = "\u{f023}", -- fa-lock
  UNLOCK          = "\u{f3c1}", -- fa-lock-open
  VIDEO           = "\u{f03d}", -- fa-video
  MUSIC           = "\u{f001}", -- fa-music
  EXPORT          = "\u{f56e}", -- fa-file-export
  IMPORT          = "\u{f56f}", -- fa-file-import
  LINK            = "\u{f0c1}", -- fa-link
  CHEVRON_DOWN    = "\u{f078}", -- fa-chevron-down
  CHEVRON_UP      = "\u{f077}", -- fa-chevron-up
  CHEVRON_LEFT    = "\u{f053}", -- fa-chevron-left
  CHEVRON_RIGHT   = "\u{f054}", -- fa-chevron-right
  STAR            = "\u{f005}", -- fa-star
  EYE             = "\u{f06e}", -- fa-eye
  EYE_SLASH       = "\u{f070}", -- fa-eye-slash
  LIST            = "\u{f03a}", -- fa-list
  MENU            = "\u{f0c9}", -- fa-bars
  ARROW_LEFT      = "\u{f060}", -- fa-arrow-left
  ARROW_RIGHT     = "\u{f061}", -- fa-arrow-right
  ARROW_UP        = "\u{f062}", -- fa-arrow-up
  ARROW_DOWN      = "\u{f063}", -- fa-arrow-down
  WRENCH          = "\u{f0ad}", -- fa-wrench
  FILTER          = "\u{f0b0}", -- fa-filter
  TRACKS          = "\u{f5fd}", -- fa-layer-group
  VOLUME          = "\u{f028}", -- fa-volume-high
  MUTE            = "\u{f6a9}", -- fa-volume-xmark
  MICROPHONE      = "\u{f130}", -- fa-microphone
  HEADPHONES      = "\u{f025}", -- fa-headphones
  SPLIT           = "\u{f0c4}", -- fa-scissors
  SHUFFLE         = "\u{f074}", -- fa-shuffle
  REPEAT          = "\u{f363}", -- fa-repeat
  STEP_FORWARD    = "\u{f051}", -- fa-forward-step
  STEP_BACKWARD   = "\u{f048}", -- fa-backward-step
  DOWNLOAD        = "\u{f019}", -- fa-download
  UPLOAD          = "\u{f093}", -- fa-upload
}

-- ============================================================
-- Icon font: Font Awesome has no text glyphs and ReaImGui has no font-merge
-- mode, so icon glyphs are always drawn with this font pushed on its own
-- (never mixed into the same Button/Text call as body text). Lazily
-- created and cached per-ctx, same rationale as the bold font above.
-- ============================================================
local icon_font_cache = setmetatable({}, {__mode = "k"})
local ICON_FONT_PATH = SELF_DIR .. "Fonts/fa-solid-900.ttf"

local function get_icon_font(ctx)
  local font = icon_font_cache[ctx]
  if not font then
    font = ImGui.CreateFontFromFile(ICON_FONT_PATH)
    ImGui.Attach(ctx, font)
    icon_font_cache[ctx] = font
  end
  return font
end

-- Push the icon font. size defaults to the current font size. Must be
-- paired with theme.PopIconFont.
function theme.PushIconFont(ctx, size)
  ImGui.PushFont(ctx, get_icon_font(ctx), size or ImGui.GetFontSize(ctx))
end

function theme.PopIconFont(ctx)
  ImGui.PopFont(ctx)
end

-- Draw a single icon glyph inline (e.g. next to a Text() via SameLine()).
-- icon is one of theme.Icons.*.
function theme.IconText(ctx, icon, size)
  theme.PushIconFont(ctx, size)
  ImGui.Text(ctx, icon)
  theme.PopIconFont(ctx)
end

-- The size theme.IconButton uses by default when width/height aren't given:
-- enough to fit an icon glyph of `size` (default: current font size) plus
-- frame padding on every side, so a larger icon always gets a larger
-- button instead of clipping inside a box sized for body text. Exposed so
-- callers can lay out/align an IconButton before drawing it, e.g. to
-- right-justify one:
--   local btn_w = theme.IconButtonSize(ctx, icon_size)
--   ImGui.SetCursorPosX(ctx, right_edge_x - btn_w)
function theme.IconButtonSize(ctx, size)
  local icon_size = size or ImGui.GetFontSize(ctx)
  local pad_x, pad_y = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  return icon_size + math.max(pad_x, pad_y) * 2
end

-- An icon-only button (e.g. a toolbar action, a settings gear in a header).
-- icon is one of theme.Icons.*. size is the icon glyph's draw size (default:
-- current font size) -- pass a larger value for a more prominent icon; the
-- button square grows to match via theme.IconButtonSize so the glyph is
-- never clipped. Pass explicit width/height to override the square.
-- Pair with ImGui.SetTooltip / IsItemHovered for a label on hover since the
-- button itself has no room for text.
function theme.IconButton(ctx, icon, width, height, size)
  local square = theme.IconButtonSize(ctx, size)
  theme.PushIconFont(ctx, size)
  local clicked = ImGui.Button(ctx, icon, width or square, height or square)
  theme.PopIconFont(ctx)
  return clicked
end

return theme
