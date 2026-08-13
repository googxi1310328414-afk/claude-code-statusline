' statusline-watchdog.vbs — 计划任务 claude-statusline-watchdog 的零窗口启动垫片。
' wscript 属 GUI 子系统，不分配控制台；计划任务直接跑 powershell.exe 会在
' -WindowStyle Hidden 生效前闪现 <1 秒的控制台窗口（用户 2026-08-13 报告的秒闪 cmd 框）。
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\Users\Administrator\.claude\statusline-watchdog.ps1""", 0, False
