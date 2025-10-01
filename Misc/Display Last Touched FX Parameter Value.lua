-- @description Display Last Touched FX Parameter Value and Info
-- @author Edgemeal, modified by Stephen Schappler
-- @version 1.3
-- @about
--   Display last touched fx parameter info and value in a window
-- @link https://www.stephenschappler.com
-- @changelog 
--   10/1/25 v1.3 - Another attempt at scaling based on monitor resolution
--   8/29/24 v1.2 - Scale UI elements based on monitor resolution
--   8/27/24 v1.1 - Adding buttons for Modulation and Toggle Envelope
--   8/25/24 v1.0 - Adding the script

-- Function to save the dock state
function SaveDockState()
  local dockstate = gfx.dock(-1) -- Get the current dock state
  reaper.SetExtState("LastTouchedParameterScript", "DockState", tostring(dockstate), true)
end

-- Function to load the dock state
function LoadDockState()
  local dockstate = reaper.GetExtState("LastTouchedParameterScript", "DockState")
  if dockstate ~= "" then
    gfx.dock(tonumber(dockstate))
  end
end

-- Variables to keep track of mouse state
local last_mouse_state = 0

local BASE_SCREEN_W, BASE_SCREEN_H = 3840, 2160
local MIN_SCALE, MAX_SCALE = 0.4, 1.5
local BASE_FONT_INFO = 30
local BASE_FONT_VALUE = 100
local BASE_FONT_BUTTON = 20
local BASE_MARGIN_X = 30
local BASE_MARGIN_TOP = 10
local BASE_MARGIN_BOTTOM = 20
local BASE_BTN_W = 100
local BASE_BTN_H = 40
local BASE_BTN_MARGIN_BOTTOM = 10
local BASE_BTN_MARGIN_RIGHT = 10
local BASE_BTN_SPACING = 10

local function ClampScale(scale)
  if scale < MIN_SCALE then return MIN_SCALE end
  if scale > MAX_SCALE then return MAX_SCALE end
  return scale
end

-- Determine a scale factor for UI elements based on the monitor resolution
local function GetMonitorScale()
  local win_l, win_t = gfx.clienttoscreen(0, 0)
  local win_r, win_b = gfx.clienttoscreen(gfx.w, gfx.h)

  local viewport_l, viewport_t, viewport_r, viewport_b
  if win_l and win_t and win_r and win_b then
    viewport_l, viewport_t, viewport_r, viewport_b = reaper.my_getViewport(0, 0, 0, 0, win_l, win_t, win_r, win_b, true)
  else
    viewport_l, viewport_t, viewport_r, viewport_b = reaper.my_getViewport(0, 0, 0, 0, 0, 0, 0, 0, true)
  end

  local screen_w = (viewport_r or 0) - (viewport_l or 0)
  local screen_h = (viewport_b or 0) - (viewport_t or 0)

  if screen_w <= 0 or screen_h <= 0 then
    screen_w = BASE_SCREEN_W
    screen_h = BASE_SCREEN_H
  end

  local scale = math.min(screen_w / BASE_SCREEN_W, screen_h / BASE_SCREEN_H)
  if scale <= 0 then
    scale = 1
  end

  return ClampScale(scale)
end


-- Function to check if the button is clicked
function IsButtonClicked(x, y, w, h)
  local mouse_down = gfx.mouse_cap & 1 == 1
  local inside_button = gfx.mouse_x >= x and gfx.mouse_x <= x + w and gfx.mouse_y >= y and gfx.mouse_y <= y + h

  -- Check for mouse button press (transition from up to down)
  if mouse_down and last_mouse_state == 0 and inside_button then
    last_mouse_state = 1
    return true
  end

  -- Update mouse state
  if not mouse_down then
    last_mouse_state = 0
  end

  return false
end

function Loop()
  local scale = GetMonitorScale()
  local font_info = math.max(14, math.floor(BASE_FONT_INFO * scale + 0.5))
  local font_value = math.max(28, math.floor(BASE_FONT_VALUE * scale + 0.5))
  local font_button = math.max(10, math.floor(BASE_FONT_BUTTON * scale + 0.5))
  local margin_x = math.max(10, math.floor(BASE_MARGIN_X * scale + 0.5))
  local margin_top = math.max(5, math.floor(BASE_MARGIN_TOP * scale + 0.5))
  local margin_bottom = math.max(10, math.floor(BASE_MARGIN_BOTTOM * scale + 0.5))
  local btn_w = math.max(60, math.floor(BASE_BTN_W * scale + 0.5))
  local btn_h = math.max(24, math.floor(BASE_BTN_H * scale + 0.5))
  local btn_margin_bottom = math.max(6, math.floor(BASE_BTN_MARGIN_BOTTOM * scale + 0.5))
  local btn_margin_right = math.max(6, math.floor(BASE_BTN_MARGIN_RIGHT * scale + 0.5))
  local btn_spacing = math.max(6, math.floor(BASE_BTN_SPACING * scale + 0.5))

  -- Set the background color to RGB(40, 40, 40)
  gfx.set(40/255, 40/255, 40/255)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)  -- Fill the entire window with the background color

  local txt1 = " "
  local txt2 = " "
  local retval, tracknumber, fxnumber, paramnumber = reaper.GetLastTouchedFX()
  if retval then
    if (tracknumber >> 16) == 0 then -- Track FX or Input FX
      local track = reaper.CSurf_TrackFromID(tracknumber, false)
      local _, track_name = reaper.GetTrackName(track)
      if tracknumber == 0 then track_name = 'Master Track' end
      local _, fx_name = reaper.TrackFX_GetFXName(track, fxnumber, "")
      local _, param_name = reaper.TrackFX_GetParamName(track, fxnumber, paramnumber, "")
      local _, f_value = reaper.TrackFX_GetFormattedParamValue(track, fxnumber, paramnumber,'')
      txt1 = track_name..'\n'..fx_name..'\n'..param_name
      txt2 = f_value
    else -- ITEM FX
      local track = reaper.CSurf_TrackFromID((tracknumber & 0xFFFF), false)
      local _, track_name = reaper.GetTrackName(track)
      track_name = 'Track '..tostring(tracknumber & 0xFFFF) ..' - ' ..track_name
      local takenumber = (fxnumber >> 16)
      fxnumber = (fxnumber & 0xFFFF)
      local item_index = (tracknumber >> 16)-1
      local item = reaper.GetTrackMediaItem(track, item_index)
      local take = reaper.GetTake(item, takenumber)
      local _, fx_name = reaper.TakeFX_GetFXName(take, fxnumber, "")
      local _, param_name = reaper.TakeFX_GetParamName(take, fxnumber, paramnumber, "")
      local _, f_value = reaper.TakeFX_GetFormattedParamValue(take, fxnumber, paramnumber,'')
      txt1 = track_name..'\nItem '..tostring(item_index+1).."  Take "..tostring(takenumber+1)..'\nFX: '..fx_name..'\n'..param_name
      txt2 = f_value
    end
  end

  -- Draw txt1 (white color)
  gfx.set(1, 1, 1)
  gfx.setfont(1,"SST", font_info)
  gfx.x = margin_x
  gfx.y = margin_top
  gfx.drawstr(txt1)
  
  -- Draw txt2 (blue color)
  gfx.set(142/255, 188/255, 247/255)
  gfx.setfont(1,"SST", font_value)
  local _, str_h2 = gfx.measurestr(txt2)
  gfx.x = margin_x
  gfx.y = gfx.h - str_h2 - margin_bottom
  gfx.drawstr(txt2)

  -- Draw "MOD" button (white text, dark grey background)
  local btn_y = gfx.h - btn_h - btn_margin_bottom
  local btn_x_env = gfx.w - btn_w - btn_margin_right
  local btn_x_mod = btn_x_env - btn_w - btn_spacing

  gfx.set(0.2, 0.2, 0.2)
  gfx.rect(btn_x_mod, btn_y, btn_w, btn_h, 1)
  gfx.set(.9, .9, .9)
  gfx.setfont(1, "SST", font_button)
  local mod_label_w = gfx.measurestr("MOD")
  gfx.x = btn_x_mod + (btn_w - mod_label_w) / 2
  gfx.y = btn_y + (btn_h - font_button) / 2
  gfx.drawstr("MOD")

  -- Check if the "MOD" button is clicked
  if IsButtonClicked(btn_x_mod, btn_y, btn_w, btn_h) then
    reaper.Main_OnCommand(41143, 0) -- Run the action to open modulation editor
  end

  -- Draw "ENV" button (white text, dark grey background)
  gfx.set(0.2, 0.2, 0.2)
  gfx.rect(btn_x_env, btn_y, btn_w, btn_h, 1)
  gfx.set(.9, .9, .9)
  gfx.setfont(1, "SST", font_button)
  local env_label_w = gfx.measurestr("ENV")
  gfx.x = btn_x_env + (btn_w - env_label_w) / 2
  gfx.y = btn_y + (btn_h - font_button) / 2
  gfx.drawstr("ENV")

  -- Check if the "ENV" button is clicked
  if IsButtonClicked(btn_x_env, btn_y, btn_w, btn_h) then
    reaper.Main_OnCommand(41142, 0) -- Run the action to toggle envelope
  end

  gfx.update()
  if gfx.getchar() >= 0 then 
    SaveDockState() -- Save the dock state before exiting
    reaper.defer(Loop) 
  else
    gfx.quit()
  end
end

local title = 'Last Touched Parameter'
local wnd_w, wnd_h = 400, 250
gfx.init(title, wnd_w, wnd_h, 0, 100, 100)

LoadDockState() -- Load the saved dock state

Loop()




