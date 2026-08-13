' statusline-watchdog.vbs — 计划任务 claude-statusline-watchdog 的零窗口启动垫片。
' wscript 属 GUI 子系统，不分配控制台；计划任务直接跑 powershell.exe 会在
' -WindowStyle Hidden 生效前闪现 <1 秒的控制台窗口（实测确认过的秒闪 cmd 框）。
' 路径经 %USERPROFILE% 运行时解析——任意用户开箱即用，安装时无需改内容。
Dim sh: Set sh = CreateObject("WScript.Shell")
Dim home: home = sh.ExpandEnvironmentStrings("%USERPROFILE%")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & home & "\.claude\statusline-watchdog.ps1""", 0, False
