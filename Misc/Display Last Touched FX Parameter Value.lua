-- @description Display Last Touched FX Parameter Value and Info
-- @author Edgemeal, modified slightly by Stephen Schappler
-- @version 1.0
-- @about
--   Display last touched fx parameter info and value in a window
-- @link https://www.stephenschappler.com
-- @changelog 
--   8/25/24 v1.0 - Adding the script

function Loop()
    local txt1 = " "
    local txt2 = " "
    local retval, tracknumber, fxnumber, paramnumber = reaper.GetLastTouchedFX()
    if retval then
      if (tracknumber >> 16) == 0 then -- Track FX or Input FX
        local track = reaper.CSurf_TrackFromID(tracknumber, false)
        local _, track_name = reaper.GetTrackName(track)
        if tracknumber == 0 then track_name = 'Master Track' else track_name = track_name end
        local _, fx_name = reaper.TrackFX_GetFXName(track, fxnumber, "")
        local _, param_name = reaper.TrackFX_GetParamName(track, fxnumber, paramnumber, "")
        local fx_id = "" if (fxnumber >> 24) == 1 then fx_id = "" end
        local _, f_value = reaper.TrackFX_GetFormattedParamValue(track, fxnumber, paramnumber,'')
        txt1 = track_name..'\n'..fx_id..fx_name..'\n'..param_name
        txt2 = ' \n'..f_value
      else -- ITEM FX >>>>>
        local track = reaper.CSurf_TrackFromID((tracknumber & 0xFFFF), false)
        local _, track_name = reaper.GetTrackName(track)
        track_name = 'Track '..tostring(tracknumber & 0xFFFF) ..' - ' ..track_name
        local takenumber = (fxnumber >> 16)
        fxnumber = (fxnumber & 0xFFFF)
        local item_index = (tracknumber >> 16)-1
        local item = reaper.GetTrackMediaItem(track, item_index)
        local take = reaper.GetTake(item, takenumber)
        local _, fx_name = reaper.TakeFX_GetFXName(take, fxnumber, "")
        local _, take_param_name = reaper.TakeFX_GetParamName(take, fxnumber, paramnumber, "")
        local _, f_value = reaper.TakeFX_GetFormattedParamValue(take, fxnumber, paramnumber,'')
        txt1 = track_name..'\nItem '..tostring(item_index+1).."  Take "..tostring(takenumber+1)..'\nFX: '..fx_name..'\n'..take_param_name
        txt2 = ' \n'..f_value
      end
    end
  
    -- Set the background color to RGB(40, 40, 40)
    gfx.clear = 40 + 40 * 256 + 40 * 65536
  
    -- Set color to white for the general text
    gfx.set(1, 1, 1) 
    gfx.setfont(1,"Arial", 25)
    local str_w, str_h = gfx.measurestr(txt1)
    gfx.x, gfx.y = (gfx.w - str_w) / 20, (gfx.h - str_h) / 20
    gfx.drawstr(txt1)
  
    -- Set the color to RGB(142, 188, 247) for the parameter value readout
    gfx.set(142/255, 188/255, 247/255) 
    gfx.setfont(1,"Arial", 80)
    local str_w, str_h = gfx.measurestr(txt2)
    gfx.x, gfx.y = (gfx.w - str_w) / 10, (gfx.h - str_h) / 10
    gfx.drawstr(txt2)
  
    gfx.update()
    if gfx.getchar() >= 0 then reaper.defer(Loop) end
  end
  
  local title = 'Last Touched Parameter'
  local wnd_w, wnd_h = 350,230
  local __, __, scr_w, scr_h = reaper.my_getViewport(0, 0, 0, 0, 0, 0, 0, 0, 1)
  gfx.init(title, wnd_w, wnd_h, 0, (scr_w - wnd_w) / 1, (scr_h - wnd_h) / 1)
  gfx.setfont(1,"Arial", 36)
  
  -- Optional: set window topmost
  if reaper.APIExists('JS_Window_FindTop') then
    local hwnd = reaper.JS_Window_FindTop(title, true)
    if hwnd then reaper.JS_Window_SetZOrder(hwnd, "TOPMOST", hwnd) end
  end
  
  Loop()
  