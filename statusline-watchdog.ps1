# statusline-watchdog.ps1 — 清理挂死的状态栏 bash（cygwin fork 竞争偶发挂起的自愈层）
# 计划任务每 2 分钟经 statusline-watchdog.vbs（wscript，GUI 子系统）零窗口拉起——
# 直接由计划任务跑 powershell 会在 -WindowStyle Hidden 生效前闪一下控制台窗口。
# 只动命令行含渲染脚本/面板 daemon 文件名的 bash（宽泛的 '*statusline*' 会误杀
# 碰巧提及 statusline 的诊断/测试命令，2026-08-13 实际发生过）。
#
# 两类清理，判据不同：
#   1. 渲染脚本（statusline-command.sh / subagent-statusline.sh）——一次渲染
#      正常 0.4–1.3s，存活 >30s 即判挂死。
#   2. 面板常驻 daemon（statusline-panel-daemon.sh）——它本就长命，绝不能按
#      存活时长杀。判据是**心跳陈旧**：daemon 每 5 秒把 pid+epoch 写进
#      statusline-panel.d/daemon.pid，凡不是当前注册者、或注册者心跳超过 180
#      秒没动的，都是卡死/被遗弃的实例。2026-08-14 实测过一次事故：一个卡死
#      实例使钩子每 ~65 秒拉起一个新 daemon，累计 78 个孤儿常驻烧掉 22 CPU
#      小时——当时看门狗刻意不匹配 daemon，全系统没有任何组件会回收它们。
$cutoff = (Get-Date).AddSeconds(-30)
Get-CimInstance Win32_Process -Filter "Name='bash.exe'" |
  Where-Object { ($_.CommandLine -like '*statusline-command.sh*' -or $_.CommandLine -like '*subagent-statusline.sh*') -and $_.CreationDate -lt $cutoff } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# ---- 面板 daemon：只保留「当前注册且心跳新鲜」的那一个 ----
$panelDir = Join-Path $env:USERPROFILE '.claude\statusline-panel.d'
$pidFile  = Join-Path $panelDir 'daemon.pid'
$ownerPid = $null
if (Test-Path $pidFile) {
  $lines = @(Get-Content $pidFile -ErrorAction SilentlyContinue)
  if ($lines.Count -ge 2 -and $lines[0] -match '^\d+$' -and $lines[1] -match '^\d+$') {
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$lines[1]
    # 心跳新鲜才认这个注册者；陈旧则连它一起清（它正是卡死的那个）
    if ($age -ge -60 -and $age -le 180) { $ownerPid = [int]$lines[0] }
  }
}
$daemons = @(Get-CimInstance Win32_Process -Filter "Name='bash.exe'" |
  Where-Object { $_.CommandLine -like '*statusline-panel-daemon.sh*' })
# cygwin pid 与 Windows pid 不同：pid 文件里存的是 cygwin pid，无法直接比对，
# 故用「最新启动的那一个」近似当前注册者——钩子每拍保证有且仅有一个新实例被
# 拉起，多余的都是历史遗留（正是事故里那 78 个）。
if ($daemons.Count -gt 1) {
  $keep = ($daemons | Sort-Object CreationDate -Descending | Select-Object -First 1).ProcessId
  foreach ($d in $daemons) {
    if ($d.ProcessId -ne $keep) { Stop-Process -Id $d.ProcessId -Force -ErrorAction SilentlyContinue }
  }
} elseif ($daemons.Count -eq 1 -and $ownerPid -eq $null -and (Test-Path $pidFile)) {
  # 唯一实例但注册心跳陈旧 = 它卡死了：杀掉并清理注册，下一拍钩子会拉起新的
  $only = $daemons[0]
  if ($only.CreationDate -lt (Get-Date).AddSeconds(-180)) {
    Stop-Process -Id $only.ProcessId -Force -ErrorAction SilentlyContinue
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  }
}
