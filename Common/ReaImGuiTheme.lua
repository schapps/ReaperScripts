-- @description Schapps ReaImGUI Theme
-- @author Stephen Schappler
-- @version 1.30
-- @about
--   ReaImGUI Theme file for my scripts
-- @link https://www.stephenschappler.com
-- @provides
--   line-md--play-filled.png > line-md--play-filled.png
--   Fonts/fa-solid-900.ttf > Fonts/fa-solid-900.ttf
--   Fonts/LICENSE.txt > Fonts/LICENSE.txt
-- @changelog
--   08/29/26 - v1.30 Secondary accent's purpose changed from "active tab"
--                   to "secondary action buttons" -- added
--                   theme.SecondaryButton (same shape as PrimaryButton,
--                   Secondary-accent fill). Tabs (theme.Push and
--                   theme.TabBar's overline) now use the Primary accent
--                   instead. Default Secondary color changed to match
--                   Renamer's Export button blue.
--   08/29/26 - v1.29 Added theme.DrawTabAccent and theme.TabBar, the
--                   closable/colorable/addable tab bar previously
--                   duplicated in Smart Export, Export Video, and Text
--                   Overlay. Tab overline now uses the Secondary accent
--                   color instead of a hardcoded purple.
--   08/29/26 - v1.28 Default Body Font Size changed from 15 to 13.
--   08/29/26 - v1.27 theme.Push now also pushes the configured Body Font
--                   as the window's default font (theme.Pop pops it), so
--                   it applies to all text, not just PrimaryButton.
--   08/29/26 - v1.26 Fixed theme.IconButton drawing its glyph off-center
--                   (relying on Button()'s own label centering). Now
--                   draws a blank button and overlays the glyph manually.
--   08/28/26 - v1.25 Added a second customizable color (theme.Get/Set/
--                   ResetSecondaryAccentColor, the teal used on the
--                   active/selected tab) and customizable body/mono font
--                   name + size (theme.Get/Set/ResetBodyFontName/Size and
--                   the Mono equivalents), plus theme.PushBodyFont/
--                   PushMonoFont to actually use them -- consolidating
--                   what Export Video and Text Overlay each did with
--                   their own local CreateFont calls. The bold font used
--                   by PrimaryButton now tracks the configured body font
--                   name too, instead of being hardcoded to "sans-serif".
--                   Also added theme.ExportSettings/ImportSettings,
--                   reading/writing all of the above as one ".spstheme"
--                   Lua-table file, for the new Settings script's
--                   Export/Import buttons.
--   08/28/26 - v1.24 Added theme.GetAccentColor/SetAccentColor/
--                   ResetAccentColor, backed by ExtState so the choice
--                   persists across sessions and is shared live by every
--                   script that pushes this theme (each reads ExtState
--                   fresh, not a load-time cache, so a change made in the
--                   new "Schapps ReaImGUI Theme Settings" script takes
--                   effect in any other theme-using window already open,
--                   next frame). Col_CheckMark/SliderGrab/SliderGrabActive
--                   and PrimaryButton's default fill now read this instead
--                   of the old hardcoded 0xA08FE2FF, and PrimaryButton's
--                   default-color branch was folded into the custom-color
--                   one (both now derive hover/active via scale_rgb), so
--                   the default accent behaves exactly like any other
--                   PrimaryButton color.
--   08/28/26 - v1.23 Added theme.PrimaryButtonHeight, so callers can
--                   pre-measure a PrimaryButton row's height (bold,
--                   1.3x font + frame padding) to size layout space above
--                   it -- e.g. Subproject Manager's table/child region,
--                   which was sized assuming the plain-Button-height bottom
--                   row it had before switching to PrimaryButton, leaving
--                   the window permanently a scrollbar's worth too short.
--   08/23/26 - v1.22 Fixed theme.PrimaryButton's icon path: passing the
--                   standard `-1` (fill available width) for `width` was
--                   silently treated as "auto-size to content" instead,
--                   since the check was `width > 0` -- any icon
--                   PrimaryButton passing -1 (Create, Reposition) came
--                   out narrower than intended. Now matches native
--                   ImGui.Button's width semantics: nil/0 = auto, < 0 =
--                   fill available width, > 0 = fixed width.
--   08/23/26 - v1.21 Added theme.Icons.LEFT_RIGHT (fa-left-right).
--   08/23/26 - v1.20 Added theme.Icons.SQUARE_PLUS (fa-square-plus).
--   08/23/26 - v1.19 Added theme.Icons.FILE_WAVEFORM (fa-file-waveform).
--   08/23/26 - v1.18 theme.PrimaryButton takes an optional 6th `icon`
--                   arg (one of theme.Icons.*), drawn before the label.
--                   Since there's no font-merge, this draws a blank-label
--                   Button() for native hover/press + click behavior and
--                   overlays the icon glyph + bold label text on top via
--                   the draw list. Also added theme.Icons.PENCIL.
--   08/23/26 - v1.17 Added theme.Icons.DOLLAR_SIGN (fa-dollar-sign).
--   08/22/26 - v1.16 theme.PrimaryButton now takes an optional 5th `color`
--                   arg to reuse the exact same bold/1.3x/dark-text style
--                   in a different hue (hover/active shades auto-derived
--                   via the new scale_rgb helper) -- e.g. Renamer's
--                   Export button, which needed the same look as Rename
--                   but a distinct color.
--   08/22/26 - v1.15 Col_PopupBg (dropdown/combo popup background) was
--                   0x202225FF -- same blue-tint pattern as the other
--                   fixes here. Flattened to neutral 0x202020FF.
--   08/22/26 - v1.14 Added theme.Icons.FILE_LINES (fa-file-lines) and
--                   theme.Icons.CLOCK (fa-clock).
--   08/22/26 - v1.13 Col_ScrollbarBg/Grab/Hovered/Active had the same
--                   blue-tint pattern as the other fixes here (confirmed
--                   by pixel-sampling a screenshot: the grab handle
--                   rendered as (58,64,70), exactly the old
--                   Col_ScrollbarGrab value). Flattened all four to
--                   neutral greys, same relative brightness as before.
--   08/22/26 - v1.12 Col_Border (the line ImGui draws under a tab bar,
--                   among other places) was 0x3A3F45FF -- same blue-tint
--                   pattern as the other fixes here. Flattened to neutral
--                   0x3F3F3FFF.
--   08/22/26 - v1.11 Col_Tab (base/inactive tab) was 0x23282DFF -- reads
--                   as clearly blue in practice despite looking like a
--                   plausible dark grey in hex (only a 10/255 R-to-B
--                   spread, but very visible at this low a brightness).
--                   Flattened to neutral 0x232323FF, matching the
--                   Col_TabDimmed*/Col_FrameBg* fixes below.
--   08/22/26 - v1.10 Col_TabDimmed/Unfocused and Col_TabDimmedSelected/
--                   UnfocusedActive (tabs shown when the script's window
--                   itself isn't focused) had the same blue-tint issue as
--                   Col_FrameBg* below -- flattened to neutral greys.
--   08/22/26 - v1.9 Col_FrameBgHovered/Active were slightly blue-tinted
--                   (unequal R/G/B) -- changed to neutral greys, lighter
--                   than Col_FrameBg, with no color cast.
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

-- ============================================================
-- User-customizable settings: accent colors and font choices, all backed
-- by ExtState (not a per-file/per-ctx cache) so every script sharing this
-- theme -- including ones already running -- reflects a change made in
-- the "Schapps ReaImGUI Theme Settings" script on its very next frame.
--
-- make_*_setting builds a Get/Set/Reset trio for one ExtState-backed value
-- rather than writing each trio out by hand -- there are six of these
-- (2 colors, 2 font names, 2 font sizes) and they'd otherwise be
-- eighteen near-identical functions differing only in parse/format.
-- ============================================================
local EXT_SECTION = "SchappsReaImGuiTheme"

local function make_string_setting(key, default)
  local function get()
    local str = reaper.GetExtState(EXT_SECTION, key)
    return str ~= "" and str or default
  end
  local function set(value) reaper.SetExtState(EXT_SECTION, key, value, true) end
  local function reset() reaper.DeleteExtState(EXT_SECTION, key, true) end
  return get, set, reset
end

local function make_number_setting(key, default)
  local function get()
    local str = reaper.GetExtState(EXT_SECTION, key)
    return (str ~= "" and tonumber(str)) or default
  end
  local function set(value) reaper.SetExtState(EXT_SECTION, key, tostring(value), true) end
  local function reset() reaper.DeleteExtState(EXT_SECTION, key, true) end
  return get, set, reset
end

local function make_color_setting(key, default)
  local function get()
    local str = reaper.GetExtState(EXT_SECTION, key)
    local color = str ~= "" and tonumber(str, 16)
    return color or default
  end
  local function set(color) reaper.SetExtState(EXT_SECTION, key, string.format("%08X", color & 0xFFFFFFFF), true) end
  local function reset() reaper.DeleteExtState(EXT_SECTION, key, true) end
  return get, set, reset
end

-- Accent color: the purple used on checkboxes, sliders, and
-- theme.PrimaryButton's default fill.
theme.DefaultAccentColor = 0xA08FE2FF
theme.GetAccentColor, theme.SetAccentColor, theme.ResetAccentColor =
  make_color_setting("AccentColor", theme.DefaultAccentColor)

-- Secondary accent color: theme.SecondaryButton's default fill -- an
-- alternate action button style next to a PrimaryButton (e.g. Export
-- beside Rename), same shape (bold, 1.3x, dark text) but a distinct
-- color. Default matches the blue Renamer's Export button already used
-- as a one-off custom color before it switched to this.
theme.DefaultSecondaryAccentColor = 0x94BAE3FF
theme.GetSecondaryAccentColor, theme.SetSecondaryAccentColor, theme.ResetSecondaryAccentColor =
  make_color_setting("SecondaryAccentColor", theme.DefaultSecondaryAccentColor)

-- Body font: family name (passed straight to ImGui.CreateFont, so a
-- generic alias like "sans-serif" or an installed font name both work)
-- and the size theme.PushBodyFont falls back to when not given one.
theme.DefaultBodyFontName = "sans-serif"
theme.GetBodyFontName, theme.SetBodyFontName, theme.ResetBodyFontName =
  make_string_setting("BodyFontName", theme.DefaultBodyFontName)
theme.DefaultBodyFontSize = 13
theme.GetBodyFontSize, theme.SetBodyFontSize, theme.ResetBodyFontSize =
  make_number_setting("BodyFontSize", theme.DefaultBodyFontSize)

-- Monospace font: same idea, defaulting to each OS's usual monospace face
-- (matches what Export Video / Renamer already hardcode independently).
theme.DefaultMonoFontName = reaper.GetOS():find("Win") and "Consolas" or "Menlo"
theme.GetMonoFontName, theme.SetMonoFontName, theme.ResetMonoFontName =
  make_string_setting("MonoFontName", theme.DefaultMonoFontName)
theme.DefaultMonoFontSize = 13
theme.GetMonoFontSize, theme.SetMonoFontSize, theme.ResetMonoFontSize =
  make_number_setting("MonoFontSize", theme.DefaultMonoFontSize)

function theme.Push(ctx)
  local accent = theme.GetAccentColor()
  local colors = {
    {ImGui.Col_Text, 0xE6E6E6FF},
    {ImGui.Col_TextDisabled, 0xA0A0A0FF},
    {ImGui.Col_WindowBg, 0x28282828FF},
    {ImGui.Col_ChildBg, 0x222222FF},
    {ImGui.Col_PopupBg, 0x202020FF},
    {ImGui.Col_Border, 0x3F3F3FFF},
    {ImGui.Col_FrameBg, 0x333333FF},
    {ImGui.Col_FrameBgHovered, 0x454545FF},
    {ImGui.Col_FrameBgActive, 0x505050FF},
    {ImGui.Col_TitleBg, 0x222222FF},
    {ImGui.Col_TitleBgActive, 0x333333FF},
    {ImGui.Col_TitleBgCollapsed, 0x15181BFF},
    {ImGui.Col_ScrollbarBg, 0x1C1C1CFF},
    {ImGui.Col_ScrollbarGrab, 0x404040FF},
    {ImGui.Col_ScrollbarGrabHovered, 0x535353FF},
    {ImGui.Col_ScrollbarGrabActive, 0x666666FF},
    {ImGui.Col_CheckMark, accent},
    {ImGui.Col_SliderGrab, accent},
    {ImGui.Col_SliderGrabActive, accent},
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

  add_color_name("Col_Tab", 0x232323FF)
  add_color_name("Col_TabHovered", 0x333333FF)
  -- Newer ReaImGui builds renamed these (Col_TabActive -> Col_TabSelected,
  -- Col_TabUnfocused -> Col_TabDimmed, Col_TabUnfocusedActive ->
  -- Col_TabDimmedSelected). add_color_name's rawget guard means only the
  -- name that actually exists on the running build gets pushed, so both the
  -- new and old name are listed here for compatibility -- without this,
  -- these three were silently no-op'ing on newer builds and every active
  -- tab fell back to Dear ImGui's default blue.
  add_color_name("Col_TabSelected", accent)
  add_color_name("Col_TabActive", accent)
  -- Dimmed/Unfocused tabs (shown when the script's window itself isn't
  -- the focused window) were blue-tinted (unequal R/G/B) like the
  -- Col_FrameBg* fix above -- flattened to neutral greys.
  add_color_name("Col_TabDimmed", 0x1E1E1EFF)
  add_color_name("Col_TabUnfocused", 0x1E1E1EFF)
  add_color_name("Col_TabDimmedSelected", 0x2A2A2AFF)
  add_color_name("Col_TabUnfocusedActive", 0x2A2A2AFF)

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

  -- Body Font previously only reached theme.PrimaryButton's bold label
  -- (the only thing that read theme.GetBodyFontName()) -- pushing it here
  -- makes it the window's actual default text font, matching every other
  -- Text/Checkbox/Button label too. Pushed/popped 1:1 with theme.Push/Pop
  -- so callers don't need a third count to track.
  theme.PushBodyFont(ctx)

  return #colors, #vars
end

function theme.Pop(ctx, color_count, var_count)
  theme.PopBodyFont(ctx)
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
-- Named fonts (body, bold, monospace): each needs a font object, which
-- (unlike colors/vars) must be created once per ImGui context rather than
-- every frame, so one is lazily created and cached here per-ctx on first
-- use. Keyed with weak references so the cache doesn't keep a closed
-- script's context (and its font) alive.
--
-- The cache entry also remembers which family name it was built from, so
-- if the user changes the configured body/mono font name mid-session, the
-- next request notices the mismatch and creates a fresh font instead of
-- serving the stale one -- ExtState-backed settings can change out from
-- under an already-running script this same way (see the section above).
-- ============================================================
local function get_cached_font(cache, ctx, name, flags)
  local entry = cache[ctx]
  if not entry or entry.name ~= name then
    local font = flags and ImGui.CreateFont(name, flags) or ImGui.CreateFont(name)
    ImGui.Attach(ctx, font)
    entry = {name = name, font = font}
    cache[ctx] = entry
  end
  return entry.font
end

local bold_font_cache = setmetatable({}, {__mode = "k"})
local body_font_cache = setmetatable({}, {__mode = "k"})
local mono_font_cache = setmetatable({}, {__mode = "k"})

local function get_bold_font(ctx)
  return get_cached_font(bold_font_cache, ctx, theme.GetBodyFontName(), ImGui.FontFlags_Bold)
end

local function get_body_font(ctx)
  return get_cached_font(body_font_cache, ctx, theme.GetBodyFontName())
end

local function get_mono_font(ctx)
  return get_cached_font(mono_font_cache, ctx, theme.GetMonoFontName())
end

-- Push/pop the user's configured body or monospace font. size defaults to
-- the matching theme.Get*FontSize() setting when omitted. Must be paired
-- with the matching Pop, same convention as theme.PushIconFont.
function theme.PushBodyFont(ctx, size)
  ImGui.PushFont(ctx, get_body_font(ctx), size or theme.GetBodyFontSize())
end

function theme.PopBodyFont(ctx)
  ImGui.PopFont(ctx)
end

function theme.PushMonoFont(ctx, size)
  ImGui.PushFont(ctx, get_mono_font(ctx), size or theme.GetMonoFontSize())
end

function theme.PopMonoFont(ctx)
  ImGui.PopFont(ctx)
end

-- Scales an 0xRRGGBBAA color's RGB channels by `factor` (alpha untouched),
-- clamped to 255. Used by PrimaryButton to derive hover/active shades for
-- a caller-supplied color, the same way the default purple's hover
-- (lighter) and active (darker) shades relate to its base color.
local function scale_rgb(color, factor)
  local r = math.min(255, math.floor(((color >> 24) & 0xFF) * factor))
  local g = math.min(255, math.floor(((color >> 16) & 0xFF) * factor))
  local b = math.min(255, math.floor(((color >> 8) & 0xFF) * factor))
  local a = color & 0xFF
  return (r << 24) | (g << 16) | (b << 8) | a
end

-- The height theme.PrimaryButton uses when its `height` arg is nil/0: the
-- bold, 1.3x-size label's line height plus frame padding. Exposed so
-- callers can reserve layout space for a PrimaryButton row before drawing
-- it (e.g. sizing a child/table above the row to fill exactly the
-- remaining space), the same way theme.IconButtonSize lets callers
-- pre-measure an IconButton.
function theme.PrimaryButtonHeight(ctx, size)
  local text_size = size or ImGui.GetFontSize(ctx) * 1.3
  local _, pad_y = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local bold_font = get_bold_font(ctx)
  ImGui.PushFont(ctx, bold_font, text_size)
  local _, label_h = ImGui.CalcTextSize(ctx, "Ag")
  ImGui.PopFont(ctx)
  return label_h + pad_y * 2
end

-- color (optional) overrides the button's fill (theme.GetAccentColor() by
-- default) with a different 0xRRGGBBAA hue -- hover/active shades are
-- derived automatically (lighter/darker) either way. Font, size, and dark
-- text stay identical either way, so a differently-colored PrimaryButton
-- still reads as "the same style, different color," not a different
-- button class.
--
-- icon (optional): one of theme.Icons.*, drawn before the label text,
-- inside the same button. ReaImGui has no font-merge mode, so a single
-- Button() label can't mix the icon font and the bold label font -- this
-- draws a real Button() with a blank label (native hover/press
-- background + click handling, sized to fit both pieces) and overlays
-- the icon glyph and bold label text on top of it via the draw list, in
-- their respective fonts. Omit icon for the plain text-only button
-- (unchanged from before).
function theme.PrimaryButton(ctx, label, width, height, color, icon)
  local fill = color or theme.GetAccentColor()
  local normal, hover, active = fill, scale_rgb(fill, 1.13), scale_rgb(fill, 0.85)

  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        normal)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,  hover)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,   active)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text,           0x222222FF)

  local text_size = ImGui.GetFontSize(ctx) * 1.3
  local bold_font = get_bold_font(ctx)
  local clicked

  if icon then
    ImGui.PushFont(ctx, bold_font, text_size)
    local label_w, label_h = ImGui.CalcTextSize(ctx, label)
    ImGui.PopFont(ctx)

    theme.PushIconFont(ctx, text_size)
    local icon_w, icon_h = ImGui.CalcTextSize(ctx, icon)
    theme.PopIconFont(ctx)

    local pad_x, pad_y = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
    local icon_gap = pad_x * 0.5
    local content_w = icon_w + icon_gap + label_w

    -- Matches native ImGui.Button's own width semantics: nil/0 auto-sizes
    -- to content, negative fills available width (e.g. -1, the "full
    -- width" convention used throughout this repo), positive is a fixed
    -- width. The auto-content case wasn't reachable before this fix --
    -- `width > 0` is false for -1, so a caller passing -1 (expecting
    -- full width, same as every other PrimaryButton call site) silently
    -- fell through to auto-sizing-to-content instead.
    local btn_w
    if width == nil or width == 0 then
      btn_w = content_w + pad_x * 2
    elseif width < 0 then
      local avail_w = select(1, ImGui.GetContentRegionAvail(ctx))
      btn_w = avail_w + width
    else
      btn_w = width
    end
    local btn_h = (height and height > 0) and height or (label_h + pad_y * 2)

    clicked = ImGui.Button(ctx, "##" .. label, btn_w, btn_h)

    local x0, y0 = ImGui.GetItemRectMin(ctx)
    local draw_list = ImGui.GetWindowDrawList(ctx)
    local content_x = x0 + (btn_w - content_w) * 0.5

    theme.PushIconFont(ctx, text_size)
    ImGui.DrawList_AddText(draw_list, content_x, y0 + (btn_h - icon_h) * 0.5, 0x222222FF, icon)
    theme.PopIconFont(ctx)

    ImGui.PushFont(ctx, bold_font, text_size)
    ImGui.DrawList_AddText(draw_list, content_x + icon_w + icon_gap, y0 + (btn_h - label_h) * 0.5, 0x222222FF, label)
    ImGui.PopFont(ctx)
  else
    ImGui.PushFont(ctx, bold_font, text_size)
    clicked = ImGui.Button(ctx, label, width or 0, height or 0)
    ImGui.PopFont(ctx)
  end

  ImGui.PopStyleColor(ctx, 4)

  return clicked
end

-- The alternate-action counterpart to theme.PrimaryButton -- same shape
-- (bold, 1.3x, dark text, optional icon), filled with the Secondary
-- accent color instead of the Primary one. For a second action sitting
-- next to a PrimaryButton that still needs equal visual weight but a
-- distinct identity (e.g. Export beside Rename), rather than reaching
-- for PrimaryButton's `color` override with a one-off hardcoded hex.
function theme.SecondaryButton(ctx, label, width, height, icon)
  return theme.PrimaryButton(ctx, label, width, height, theme.GetSecondaryAccentColor(), icon)
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
  DOLLAR_SIGN     = "\u{24}",   -- fa-dollar-sign
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
  PENCIL          = "\u{f303}", -- fa-pencil
  LOCK            = "\u{f023}", -- fa-lock
  UNLOCK          = "\u{f3c1}", -- fa-lock-open
  VIDEO           = "\u{f03d}", -- fa-video
  MUSIC           = "\u{f001}", -- fa-music
  EXPORT          = "\u{f56e}", -- fa-file-export
  FILE_WAVEFORM   = "\u{f478}", -- fa-file-waveform
  SQUARE_PLUS     = "\u{f0fe}", -- fa-square-plus
  LEFT_RIGHT      = "\u{f337}", -- fa-left-right
  IMPORT          = "\u{f56f}", -- fa-file-import
  FILE_LINES      = "\u{f15c}", -- fa-file-lines
  CLOCK           = "\u{f017}", -- fa-clock
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
-- icon is one of theme.Icons.*, optionally with a caller-appended "##id"
-- suffix for disambiguation (same convention as any other id string). size
-- is the icon glyph's draw size (default: current font size) -- pass a
-- larger value for a more prominent icon; the button square grows to
-- match via theme.IconButtonSize so the glyph is never clipped. Pass
-- explicit width/height to override the square.
--
-- Draws a blank-label Button() (native hover/press background + click
-- handling; icon/id still salts its ID) and overlays the glyph centered
-- on top via the draw list, rather than passing the glyph as Button()'s
-- own visible label -- letting Button() center it produced a visibly
-- off-center glyph (e.g. the Subproject Manager settings gear).
-- Pair with ImGui.SetTooltip / IsItemHovered for a label on hover since the
-- button itself has no room for text.
function theme.IconButton(ctx, icon, width, height, size)
  local square = theme.IconButtonSize(ctx, size)
  local btn_w, btn_h = width or square, height or square

  local hash_at = icon:find("##", 1, true)
  local glyph = hash_at and icon:sub(1, hash_at - 1) or icon

  theme.PushIconFont(ctx, size)
  local glyph_w, glyph_h = ImGui.CalcTextSize(ctx, glyph)
  local clicked = ImGui.Button(ctx, "##" .. icon, btn_w, btn_h)

  local x0, y0 = ImGui.GetItemRectMin(ctx)
  local draw_list = ImGui.GetWindowDrawList(ctx)
  local text_color = ImGui.GetStyleColor(ctx, ImGui.Col_Text)
  ImGui.DrawList_AddText(draw_list, x0 + (btn_w - glyph_w) * 0.5, y0 + (btn_h - glyph_h) * 0.5, text_color, glyph)
  theme.PopIconFont(ctx)

  return clicked
end

-- ============================================================
-- DrawTabAccent: a 3px colored bar along a tab item's left edge, showing
-- that tab's own identity color independent of whether it's selected.
-- Must be called immediately after BeginTabItem/TabItemButton (uses
-- GetItemRectMin/Max, which refer to whatever was last submitted).
-- color 0/nil draws nothing (the "no custom color" convention used
-- throughout theme.TabBar below).
-- ============================================================
function theme.DrawTabAccent(ctx, color)
  if not color or color == 0 then return end
  local x0, y0 = ImGui.GetItemRectMin(ctx)
  local _, y1 = ImGui.GetItemRectMax(ctx)
  local draw_list = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(draw_list, x0, y0, x0 + 3, y1, color)
end

-- ============================================================
-- TabBar: a dynamic, closable/colorable/addable tab bar -- "each tab is
-- a named, savable record" (Smart Export's templates, Export Video's
-- presets, Text Overlay's styles). Draws: one tab per tabs[i] with a 3px
-- left-edge accent bar in that tab's own .tab_color (theme.DrawTabAccent)
-- and a Secondary-accent top overline on the active tab (so a tab's own
-- color, not the active-tab fill, stays the primary way tabs read as
-- distinct); a right-click menu per tab (Rename..., Color picker + Clear
-- Color, Delete -- disabled when tabs has only one entry); the tab's
-- native x close button, routed through the same delete-confirm flow as
-- the menu's Delete item; a trailing "+" button that clones the active
-- tab via opts.on_create and opens the rename modal immediately,
-- focused; and the Rename/Delete confirmation UI itself.
--
-- tabs is a plain array of caller-owned tables -- theme.TabBar only ever
-- reads/writes two fields on each: .name (string) and .tab_color (packed
-- 0xRRGGBBAA, 0 = no custom color). Everything else is opaque payload
-- the caller renders below the bar itself.
--
-- active_idx is the tabs[] index the caller currently considers active
-- (e.g. restored from ExtState at startup). theme.TabBar returns the
-- (possibly changed, if a tab was clicked/created/deleted) index --
-- reassign your local from the return value every call.
--
-- opts (all required unless noted):
--   item_noun         string, e.g. "Template"/"Preset"/"Style" -- builds
--                     "Rename <noun>"/'Delete <noun> "%s"?' text.
--   app_name          string, e.g. "Smart Export" -- the delete-confirm
--                     ShowMessageBox's title.
--   new_name_base     string, e.g. "New Template" -- prefix for a
--                     freshly created tab's de-duplicated default name.
--   name_in_use(name, exclude_idx) -> bool -- used for both the new-tab
--                     default name and the rename modal's dup check.
--   on_create(active_tab) -> new_tab -- build/clone the new record (do
--                     any flush-edits-to-active-tab prep here first, if
--                     applicable); theme.TabBar sets new_tab.name itself.
--   on_click_select(new_tab, new_idx, old_tab, old_idx) -- the user
--                     clicked a different existing tab: full "make this
--                     tab live" side effects (flush/sync edit buffers,
--                     apply to a live selection + undo point, ExtState,
--                     whatever the caller's script needs).
--   on_after_create(new_tab, new_idx) -- a new tab was just created and
--                     is now active: local edit-state sync only (e.g.
--                     sync_buffers_from/deep_copy) -- NOT the same as
--                     on_click_select, since a just-cloned tab has
--                     nothing new to "apply"; don't create an undo point
--                     here even if on_click_select does.
--   on_after_delete(new_active_tab, new_idx) -- a tab was removed and
--                     new_active_tab is now active (which may be
--                     unchanged if an earlier/later tab was the one
--                     deleted): local edit-state sync only, same
--                     rationale as on_after_create.
--   on_delete(tab)    -- remove the tab's underlying storage (e.g.
--                     delete its file). theme.TabBar removes it from
--                     `tabs` itself.
--   on_rename(tab, old_name, new_name, was_active) -- rename the tab's
--                     underlying storage; update ExtState etc. if the
--                     caller keys anything off the name and was_active.
--   save(tab)         -- persist a tab record as-is (called after a
--                     color-picker change, and after on_create/rename
--                     set .name).
-- ============================================================
local tabbar_state = {}

local function get_tabbar_state(str_id)
  local st = tabbar_state[str_id]
  if not st then
    st = {
      rename_pending = false, rename_focus_next = false,
      rename_idx = 1, rename_buf = "", rename_dup_err = false,
      delete_pending = false, delete_idx = 1,
    }
    tabbar_state[str_id] = st
  end
  return st
end

function theme.TabBar(ctx, str_id, tabs, active_idx, opts)
  local st = get_tabbar_state(str_id)

  local color_n = 0
  local col_tab_selected = rawget(ImGui, "Col_TabSelected") or rawget(ImGui, "Col_TabActive")
  if col_tab_selected then
    ImGui.PushStyleColor(ctx, col_tab_selected, 0x282828FF)
    color_n = color_n + 1
  end
  local col_tab_overline = rawget(ImGui, "Col_TabSelectedOverline")
  if col_tab_overline then
    ImGui.PushStyleColor(ctx, col_tab_overline, theme.GetAccentColor())
    color_n = color_n + 1
  end

  if ImGui.BeginTabBar(ctx, str_id, ImGui.TabBarFlags_AutoSelectNewTabs) then
    for i, t in ipairs(tabs) do
      local tab_visible, new_open = ImGui.BeginTabItem(ctx, t.name, true, 0)

      theme.DrawTabAccent(ctx, t.tab_color)
      if tab_visible and not col_tab_overline then
        local x0, y0 = ImGui.GetItemRectMin(ctx)
        local x1 = select(1, ImGui.GetItemRectMax(ctx))
        local draw_list = ImGui.GetWindowDrawList(ctx)
        ImGui.DrawList_AddRectFilled(draw_list, x0, y0, x1, y0 + 2, theme.GetAccentColor())
      end

      if ImGui.BeginPopupContextItem(ctx, "##ctx_" .. i) then
        if ImGui.MenuItem(ctx, "Rename\u{2026}") then
          st.rename_pending = true
          st.rename_idx     = i
          st.rename_buf     = t.name
          st.rename_dup_err = false
        end
        if ImGui.BeginMenu(ctx, "Color") then
          local rgb = (t.tab_color >> 8) & 0xFFFFFF
          local color_changed, new_rgb = ImGui.ColorPicker3(ctx, "##tab_color_picker", rgb)
          if color_changed then
            t.tab_color = (new_rgb << 8) | 0xFF
            opts.save(t)
          end
          ImGui.Separator(ctx)
          if ImGui.MenuItem(ctx, "Clear Color", nil, false, t.tab_color ~= 0) then
            t.tab_color = 0
            opts.save(t)
          end
          ImGui.EndMenu(ctx)
        end
        local can_delete = #tabs > 1
        if not can_delete then ImGui.BeginDisabled(ctx, true) end
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF5555FF)
        if ImGui.MenuItem(ctx, "Delete") then
          st.delete_pending = true
          st.delete_idx     = i
        end
        ImGui.PopStyleColor(ctx)
        if not can_delete then ImGui.EndDisabled(ctx) end
        ImGui.EndPopup(ctx)
      end

      if not new_open and #tabs > 1 then
        st.delete_pending = true
        st.delete_idx     = i
      end

      if tab_visible then
        if i ~= active_idx then
          local old_idx, old_tab = active_idx, tabs[active_idx]
          active_idx = i
          opts.on_click_select(t, i, old_tab, old_idx)
        end
        ImGui.EndTabItem(ctx)
      end
    end

    if ImGui.TabItemButton(ctx, "+", ImGui.TabItemFlags_Trailing) then
      local new_t = opts.on_create(tabs[active_idx])

      local base = opts.new_name_base
      local new_name = base
      local suffix = 2
      while opts.name_in_use(new_name) do
        new_name = base .. " " .. suffix
        suffix = suffix + 1
      end
      new_t.name = new_name

      opts.save(new_t)
      table.insert(tabs, new_t)
      active_idx = #tabs
      opts.on_after_create(new_t, active_idx)

      st.rename_pending    = true
      st.rename_focus_next = true
      st.rename_idx        = active_idx
      st.rename_buf        = new_name
      st.rename_dup_err    = false
    end

    ImGui.EndTabBar(ctx)
  end

  if color_n > 0 then
    ImGui.PopStyleColor(ctx, color_n)
  end

  -- ── Rename modal ─────────────────────────────────────────
  local rename_title = "Rename " .. opts.item_noun .. "##modal"
  if st.rename_pending then
    ImGui.OpenPopup(ctx, rename_title)
    st.rename_pending    = false
    st.rename_focus_next = true
  end

  if ImGui.BeginPopupModal(ctx, rename_title, nil, ImGui.WindowFlags_AlwaysAutoResize) then
    ImGui.Text(ctx, opts.item_noun .. " name:")
    ImGui.SetNextItemWidth(ctx, 280)
    if st.rename_focus_next then
      ImGui.SetKeyboardFocusHere(ctx)
      st.rename_focus_next = false
    end
    local _, new_rb = ImGui.InputText(ctx, "##rename_val", st.rename_buf, ImGui.InputTextFlags_AutoSelectAll)
    st.rename_buf = new_rb

    if st.rename_dup_err then
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
      st.rename_dup_err = false
    elseif confirm and st.rename_buf ~= "" then
      if opts.name_in_use(st.rename_buf, st.rename_idx) then
        st.rename_dup_err = true
      else
        local tab = tabs[st.rename_idx]
        local old_name = tab.name
        if old_name ~= st.rename_buf then
          opts.on_rename(tab, old_name, st.rename_buf, st.rename_idx == active_idx)
        end
        tab.name = st.rename_buf
        ImGui.CloseCurrentPopup(ctx)
        st.rename_dup_err = false
      end
    end

    ImGui.EndPopup(ctx)
  end

  -- ── Pending delete ────────────────────────────────────────
  if st.delete_pending then
    st.delete_pending = false
    local tab = tabs[st.delete_idx]
    local name = tab and tab.name or "?"
    local answer = reaper.ShowMessageBox(
      ('Delete %s "%s"? This cannot be undone.'):format(opts.item_noun:lower(), name),
      opts.app_name, 4)  -- 4 = Yes/No buttons
    if answer == 6 and tab then  -- 6 = Yes
      opts.on_delete(tab)
      table.remove(tabs, st.delete_idx)
      if active_idx > st.delete_idx then
        active_idx = active_idx - 1
      end
      active_idx = math.max(1, math.min(active_idx, #tabs))
      opts.on_after_delete(tabs[active_idx], active_idx)
    end
  end

  return active_idx
end

-- ============================================================
-- Export/Import: dump/restore the user-customizable settings above as a
-- ".spstheme" file (a plain `return { ... }` Lua table, dofile-able like
-- REAPER's own RTrackTemplate-adjacent formats) so a theme can be shared
-- or backed up, the same idea as NVK's theme editor's Export/Import.
--
-- File I/O only -- picking *where* the file goes is a UI concern, left to
-- the caller (the Settings script), not this module.
-- ============================================================
local EXPORTABLE_SETTINGS = {
  {key = "AccentColor",          get = function() return theme.GetAccentColor() end,          set = theme.SetAccentColor,          kind = "color"},
  {key = "SecondaryAccentColor", get = function() return theme.GetSecondaryAccentColor() end,  set = theme.SetSecondaryAccentColor, kind = "color"},
  {key = "BodyFontName",         get = function() return theme.GetBodyFontName() end,          set = theme.SetBodyFontName,         kind = "string"},
  {key = "BodyFontSize",         get = function() return theme.GetBodyFontSize() end,          set = theme.SetBodyFontSize,         kind = "number"},
  {key = "MonoFontName",         get = function() return theme.GetMonoFontName() end,          set = theme.SetMonoFontName,         kind = "string"},
  {key = "MonoFontSize",         get = function() return theme.GetMonoFontSize() end,          set = theme.SetMonoFontSize,         kind = "number"},
}

-- Writes the current settings to `path`. Returns true, or false + an error
-- message (e.g. the folder doesn't exist or isn't writable).
function theme.ExportSettings(path)
  local file, err = io.open(path, "w")
  if not file then return false, err end

  file:write("-- Schapps ReaImGUI Theme settings\nreturn {\n")
  for _, setting in ipairs(EXPORTABLE_SETTINGS) do
    local value = setting.get()
    if setting.kind == "color" then
      file:write(string.format('  %s = %q,\n', setting.key, string.format("%08X", value)))
    elseif setting.kind == "string" then
      file:write(string.format('  %s = %q,\n', setting.key, value))
    else
      file:write(string.format('  %s = %s,\n', setting.key, tostring(value)))
    end
  end
  file:write("}\n")
  file:close()
  return true
end

-- Reads `path` (as written by theme.ExportSettings) and applies whichever
-- settings it contains -- a file missing a key leaves that setting
-- untouched, so a hand-edited partial file (e.g. just AccentColor) works
-- too. Returns true, or false + an error message (invalid/unreadable file).
function theme.ImportSettings(path)
  local chunk, load_err = loadfile(path)
  if not chunk then return false, load_err end

  local ok, data = pcall(chunk)
  if not ok then return false, data end
  if type(data) ~= "table" then return false, "File did not return a settings table" end

  for _, setting in ipairs(EXPORTABLE_SETTINGS) do
    local raw = data[setting.key]
    if raw ~= nil then
      if setting.kind == "color" then
        setting.set(tonumber(raw, 16))
      else
        setting.set(raw)
      end
    end
  end
  return true
end

return theme
