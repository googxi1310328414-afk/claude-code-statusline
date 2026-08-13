' statusline-watchdog.vbs - zero-window launch shim for the scheduled task
' claude-statusline-watchdog. wscript runs in the GUI subsystem (no console),
' while launching powershell.exe directly from the task flashes a <1s console
' window before -WindowStyle Hidden takes effect (the reported 'flash cmd box').
' Path resolved via %USERPROFILE% at runtime - works for any user unedited.
'
' HARD RULE - ASCII ONLY IN THIS FILE: wscript parses .vbs as the system ANSI
' codepage (GBK here), NOT UTF-8. A line-final multibyte character whose last
' byte lands in the DBCS lead range (e.g. the UTF-8 bytes of a Chinese full
' stop) SWALLOWS the following newline during decode, merging the NEXT line
' into this comment - which once ate the Set line below and made every 2-min
' task run pop a 'missing object: sh' error dialog. CRLF endings are kept as
' a second belt (a swallowed CR still leaves the LF as a terminator).
Dim sh: Set sh = CreateObject("WScript.Shell")
Dim home: home = sh.ExpandEnvironmentStrings("%USERPROFILE%")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & home & "\.claude\statusline-watchdog.ps1""", 0, False
