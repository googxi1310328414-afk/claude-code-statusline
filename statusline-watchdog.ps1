# statusline-watchdog.ps1 — 清理挂死的状态栏 bash（cygwin fork 竞争偶发挂起的自愈层）
# 计划任务每分钟经 statusline-watchdog.vbs（wscript，GUI 子系统）零窗口拉起——
# 直接由计划任务跑 powershell 会在 -WindowStyle Hidden 生效前闪一下控制台窗口。
# 只动命令行含两个渲染脚本文件名的 bash（宽泛的 '*statusline*' 会误杀碰巧提及
# statusline 的诊断/测试命令，2026-08-13 实际发生过），且存活 >30 秒才算挂死
# （正常渲染 0.4–1.3s）。
$cutoff = (Get-Date).AddSeconds(-30)
Get-CimInstance Win32_Process -Filter "Name='bash.exe'" |
  Where-Object { ($_.CommandLine -like '*statusline-command.sh*' -or $_.CommandLine -like '*subagent-statusline.sh*') -and $_.CreationDate -lt $cutoff } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
