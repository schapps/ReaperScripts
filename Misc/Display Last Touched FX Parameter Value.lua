-- @description Display Last Touched FX Parameter Value and Info
-- @author Edgemeal, modified by Stephen Schappler
-- @version 1.1
-- @about
--   Display last touched fx parameter info and value in a window
-- @link https://www.stephenschappler.com
-- @changelog 
--   8/25/24 v1.0 - Adding the script
--   8/27/24 v1.1 - Adding buttons for Modulation and Toggle Envelope

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
  gfx.setfont(1,"SST", 30)
  local str_w, str_h = gfx.measurestr(txt1)
  gfx.x = 30
  gfx.y = 10
  gfx.drawstr(txt1)
  
  -- Draw txt2 (blue color)
  gfx.set(142/255, 188/255, 247/255)
  gfx.setfont(1,"SST", 100)
  local str_w2, str_h2 = gfx.measurestr(txt2)
  gfx.x = 30
  gfx.y = gfx.h - str_h2 - 20
  gfx.drawstr(txt2)


  -- Draw "MOD" button (white text, dark grey background)
  local btn_w, btn_h = 100, 40
  local btn_x_mod, btn_y = gfx.w - btn_w - 120, gfx.h - btn_h - 10 -- Anchored to the right
  gfx.set(0.2, 0.2, 0.2) --background color of button
  gfx.rect(btn_x_mod, btn_y, btn_w, btn_h, 1)
  gfx.set(.9, .9, .9) --text color
  gfx.setfont(1, "SST", 20)
  gfx.x = btn_x_mod + (btn_w - gfx.measurestr("MOD")) / 2
  gfx.y = btn_y + (btn_h - 20) / 2
  gfx.drawstr("MOD")

  -- Check if the "MOD" button is clicked
  if IsButtonClicked(btn_x_mod, btn_y, btn_w, btn_h) then
    reaper.Main_OnCommand(41143, 0) -- Run the action to open modulation editor
  end

  -- Draw "ENV" button (white text, dark grey background)
  local btn_x_env = gfx.w - btn_w - 10 -- Positioned to the right of the "MOD" button
  gfx.set(0.2, 0.2, 0.2) --background color of button
  gfx.rect(btn_x_env, btn_y, btn_w, btn_h, 1)
  gfx.set(.9, .9, .9) --text color
  gfx.setfont(1, "SST", 20)
  gfx.x = btn_x_env + (btn_w - gfx.measurestr("ENV")) / 2
  gfx.y = btn_y + (btn_h - 20) / 2
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
