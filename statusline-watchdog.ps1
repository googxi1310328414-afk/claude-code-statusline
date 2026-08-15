# statusline-watchdog.ps1 — 清理挂死的状态栏 bash（cygwin fork 竞争偶发挂起的自愈层）
# 计划任务每 2 分钟经 statusline-watchdog.vbs（wscript，GUI 子系统）零窗口拉起——
# 直接由计划任务跑 powershell 会在 -WindowStyle Hidden 生效前闪一下控制台窗口。
#
# 渲染脚本（statusline-command.sh / subagent-statusline.sh）：一次渲染正常
# 0.4–1.3s，>90s 才判挂死（见下方门槛说明）。匹配面刻意收窄到两个文件名——宽泛的
# '*statusline*' 会误杀碰巧提及 statusline 的诊断/测试命令（2026-08-13 实际发生过）。
#
# 面板常驻 daemon：**只按 pid 文件第 3 行记录的 Windows pid 精确清理**，绝不按
# 「命令行提及 statusline-panel-daemon.sh」匹配——那种模糊判据会把任何谈到该文件
# 名的外壳（诊断命令、测试脚本、AI 代理自己的 bash）算作 daemon，实测会 -Force
# 杀掉无关进程，甚至因「保留最新启动的那个」而杀掉真正注册且心跳新鲜的 daemon
# （2026-08-14 第 10 轮审查实锤，与 2026-08-13 的误杀事故同型）。
# 判据：pid 文件第 2 行心跳陈旧（>180s）→ 说明注册者卡死 → 杀掉第 3 行那个
# Windows pid 并清掉注册，下一拍钩子会拉起新实例。心跳新鲜则一律不动。
# 没有 pid 文件、格式不对、或第 3 行缺失（非 MSYS 环境无 /proc）→ 什么都不做，
# 失败方向永远是「少管闲事」而不是「乱杀」。
# 30s 门（渲染脚本）：一次渲染实测 0.4–1.3s，>30s 即判挂死。注意
# **后台脱离式**的 usage/CI 刷新子壳也是 bash，但它们的命令行是
# `bash <脚本>` 的子壳形态（cmdline 仍是父脚本名），curl -m 5 / gh 网络
# 调用可能合法地跑到 30s 以上——为避免误杀这类正常后台任务，判据除
# 存活时长外还要求命令行**参数位**就是渲染脚本本身（子壳继承的是
# 同一 cmdline，故无法只靠这一点区分；因此把门槛提到 90s：远超正常
# 渲染，也超过 curl 5s / gh 的常见耗时，只有真正挂死才会命中）。
$cutoff = (Get-Date).AddSeconds(-90)
# 判据锚在「bash 之后的第一个 argv」（round-20 订正）：原先锚的是「命令行
# 以脚本名结尾」，于是**任何带参数启动的实例一律隐身**——而 daemon 自己就带
# 一个 `--once` 开关，且 `--once` 实例按构造永不注册（pid 声明整块被
# `[ "$once" -eq 0 ]` 包住），它唯一可能的回收人正是下面那条「不在注册中且
# 活过 5 分钟」的兜底，却又正好被尾锚挡在门外。现场实测：两个卡死的带参实例
# （一个 `--once`、一个 e2e 拷贝带目录参）在本机烧掉 **14 CPU 小时**、挺过
# 150+ 次两分钟节拍，把原过滤器原样跑一遍选中集为空。新锚点比旧的更严（要求
# 脚本必须是 bash 的第一个参数，而不只是命令行末尾出现过），仍配合下面的
# 「排除含裸 -c 的外壳」共同挡住提及型误杀。
# ARGV-POSITION ONLY（round-10 实锤）：`-like '*name*'` 只要求命令行里
# 出现该文件名，于是 `bash -c "... # subagent-statusline.sh"` 这类**提及型**
# 外壳（诊断命令、测试脚本、AI 代理自己的 bash）同样命中并被 -Force 杀掉。
# 判据收窄为「bash 的参数位就是该脚本」：命令行以脚本名（可带引号）结尾，
# 且不含 ` -c `（-c 形态一律是外壳，真渲染永远是 `bash <script>`）。
Get-CimInstance Win32_Process -Filter "Name='bash.exe'" |
  Where-Object {
    $_.CommandLine -notmatch '\s-c\s' -and
    $_.CommandLine -match 'bash(\.exe)?"?\s+"?[^"]*(statusline-command|subagent-statusline)\.sh(\s|"|$)' -and
    $_.CreationDate -lt $cutoff
  } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# ---- 面板 daemon：仅在「注册者心跳陈旧」时，按记录的 Windows pid 精确回收 ----
$pidFile = Join-Path $env:USERPROFILE '.claude\statusline-panel.d\daemon.pid'
$regWpid = -1
if (Test-Path $pidFile) {
  $lines = @(Get-Content $pidFile -ErrorAction SilentlyContinue)
  if ($lines.Count -ge 3 -and $lines[1] -match '^\d+$' -and $lines[2] -match '^\d+$') {
    $regWpid = [int]$lines[2]
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$lines[1]
    if ($age -gt 180) {
      $wpid = [int]$lines[2]
      # 二次确认：该 Windows pid 现在确实是一个执行 daemon 脚本的 bash
      # （pid 可能已被系统回收给别的进程）——参数位匹配，排除 `-c` 外壳。
      $p = Get-CimInstance Win32_Process -Filter "ProcessId=$wpid" -ErrorAction SilentlyContinue
      if ($p -and $p.Name -eq 'bash.exe' -and $p.CommandLine -notmatch '\s-c\s' -and $p.CommandLine -match 'bash(\.exe)?"?\s+"?[^"]*statusline-panel-daemon\.sh(\s|"|$)') {
        Stop-Process -Id $wpid -Force -ErrorAction SilentlyContinue
      }
      # 注册已确认陈旧：无论进程是否还在，都清掉它，下一拍钩子会重建
      Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
  }
}

# ---- 未注册的孤儿 daemon：唯一没有回收人的那一类 ----
# 2026-08-15 第 13 轮现场实锤：本机同时跑着 **38 个** 面板 daemon，累计烧掉
# **3.03 CPU 小时**（每个都在空转节拍上转，合计吃掉 8 核里的 4.5 核）。放大器
# 是钩子那条「先回收再拉起」的身份确认用了 `$(tr ... < cmdline)`——命令替换要
# fork，而它恰恰只在 fork 枯竭时才被走到：捕获为空、模式不匹配、于是什么都不
# 杀却照样拉新，每 ~65 秒净增一个永不退出的实例（与 2026-08-14 的 78 孤儿事故
# 同型，由它自己的修复重新引入）。钩子侧已改为纯内建读 cmdline，这里是**兜底**：
# 一个既不在注册中、又活过 5 分钟的 daemon，必然是卡在了它自己的检查点
# 之外（寿命闸要求循环还在转），四条回收路径没有一条够得着它。
# 判据仍是 argv 位置匹配 + 排除 `-c` 外壳（round-10 起在渲染脚本那条分支上验证
# 过的同一套纪律），绝不用「命令行提及脚本名」那种会误杀诊断/测试外壳的模糊匹配。
# 阈值与 STATUSLINE_PANEL_DAEMON_MAX_LIFE 无关（round-18 订正）：注册中的那个
# 实例由 $regWpid 排除、活到自己的寿命闸都不会被碰，而未注册的实例无论寿命闸
# 设多大都该在几秒内让位——把这里调大只会把第 17 轮刚补上的盲区重新开成小时级。
# 300s, not 7200 (round-17): the third orphan storm minted one wedged
# instance every ~65s, so a 2-hour grace let ~110 of them pile up. An
# UNREGISTERED daemon is wrong within seconds by design - it concedes
# on its next 5s beat, or dies of idleness in 2 minutes - so 5 minutes
# is already generous. The registered one is excluded above and lives
# up to its own lifetime cap untouched.
$orphanCutoff = (Get-Date).AddSeconds(-300)
Get-CimInstance Win32_Process -Filter "Name='bash.exe'" |
  Where-Object {
    $_.CommandLine -notmatch '\s-c\s' -and
    $_.CommandLine -match 'bash(\.exe)?"?\s+"?[^"]*statusline-panel-daemon\.sh(\s|"|$)' -and
    $_.ProcessId -ne $regWpid -and
    $_.CreationDate -lt $orphanCutoff
  } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
