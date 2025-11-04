#SingleInstance Ignore

;----------------------------------------
;----------------------------------------
;----------------Reaper-------------------
;----------------MACROS------------------
;----------------------------------------
;----------Stephen Schappler-------------
;----------------------------------------

;!^f::
;if WinExist("ahk_class REAPERVideoMainwnd")
;{
;	WinActivate
;	Sleep 100
;	Send !{PrintScreen}
;}
;
;	return

;Remapping Middle Mouse Button for Contextual Toolbars in Reaper
#IfWinActive ahk_class REAPERwnd
MButton::Send {;}
^MButton::Send ^{;}
!MButton::Send !{;}
+MButton::Send +{;}

;Remapping Side Mouse Buttons for Reaper
#IfWinActive ahk_class REAPERwnd
XButton1::Send {space};
^XButton1::Send ^{;}
!XButton1::Send !{;}



;---------MEDIA EXPLORER ---------------------------------------------------------
;Remapping ` for Media Explorer Focus and Search from the Main Window
/*
#IfWinActive ahk_class REAPERwnd
`::
Send, ^m
Sleep, 50
Send, ^f
return

;Remapping ` for Media Explorer Focus and Search from The Docker
#IfWinActive Docker
`::
WinActivate ahk_class REAPERwnd
Send, ^m
Sleep, 50
Send, ^f
return

;Remapping ` for Media Explorer Focus and Search from the Media Explorer Preview FX Chain Window
#IfWinActive FX: Track 1 "Media Explorer Preview"
`::
Send, ^m
Sleep, 50
Send, ^f
return
*/

;Remapping space bar to play Media Explorer when messing with Media Explorer Track FX
#IfWinActive FX: Track 1 "Media Explorer Preview"
Space::
WinActivate Docker
Send, {Space}
return

;Remapping space bar to play Media Explorer when messing with Media Explorer Bypass FX Buttons
#IfWinActive Toolbar 5
Space::
WinActivate Docker
Send, {Space}
return

; Spot Item with FX straight from Docked Media Explorer
#IfWinActive Docker
+s::
Send, +S
Sleep 100
Send, ^r
return

; Spot Item with FX straight from Media Explorer FX Window
#IfWinActive FX: Track 1 "Media Explorer Preview"
+s::
WinActivate Docker
Send, +S
Sleep 100
Send, ^r
return

;Focus Arrange Window after hitting "enter" in Media Explorer Search
#IfWinActive Docker
enter::
Send, {enter}
SetTitleMatchMode 1
WinActivate ahk_class REAPERwnd
return

;Remapping space bar to play Media Explorer when messing with Media Explorer Bypass FX Buttons
#IfWinActive Toolbar 32
Space::
WinActivate Docker
Send, ^+{Space}
return




;---------SOUNDMINER ---------------------------------------------------------

#IfWinExists ahk_class REAPERwnd
`::
WinActivate Soundminer
Sleep, 100
Send, ^f
return


/*
;---------DISTORT-------------------------------------------------------------
;Remapping space bar to play Media Explorer when messing with Media Explorer Track FX
#IfWinActive "FX: Track 1 "Distort Output"
Space::
WinActivate Docker
Send, ^+{Space}
return


; Tilde is used to switch to Distort and send Ctrl+F when Reaper is active
#IfWinActive ahk_exe reaper.exe
`:: ; The backtick (`) represents the tilde key in AutoHotkey

    ; Try to activate the Distort window
    IfWinExist ahk_exe distort.exe
    {
        ; Activate Distort window
        WinActivate ahk_exe distort.exe
        
        ; Wait for the window to become active
        WinWaitActive ahk_exe distort.exe
        
        ; Send Ctrl+F to Distort (search)
        Send, ^f
    }
    else
    {
        ; If Distort isn't running, you can choose to add an error message or other behavior here
        MsgBox, Distort is not running. Please launch it first.
    }

return

; Tilde is used to switch to Distort and send Ctrl+F when Reaper is active
#IfWinActive ahk_exe reaper.exe
~:: 
    ; Reaper shortcut action to copy file name of selected item
    Send, ^!+r

    ; Try to activate the Distort window
    IfWinExist, ahk_exe distort.exe
    {
        ; Activate Distort window
        WinActivate, ahk_exe distort.exe
        
        ; Wait for the window to become active
        WinWaitActive, ahk_exe distort.exe
        
        ; Send Ctrl+F to Distort (search)
        Send, ^f ; Focus the Distort search box
        Send, ^v ; Paste in the copied string
        Send, {enter} ; Close the search box
        Sleep 100
        Send, {down} ; Down arrow to select the first result automatically
    }
    else
    {
        ; If Distort isn't running, show an error message
        MsgBox, Distort is not running. Please launch it first.
    }
return

*/
