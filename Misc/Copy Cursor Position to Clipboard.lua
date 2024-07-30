-- @description Copy Cursor Position to Clipboard
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Copies cursor position to clipboard (follows main timeline format). 
--   Helpful for spotting/writing notes.
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/29/24 Creating the script

function copyCursorPositionToClipboard()
    local cursorPosition = reaper.GetCursorPosition()
    local timeStr = reaper.format_timestr(cursorPosition, "")
    
    reaper.CF_SetClipboard(timeStr)
end

copyCursorPositionToClipboard()
