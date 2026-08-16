#!/bin/bash
# install.sh - 一行命令安装/更新整套状态栏：
#
#   curl -fsSL https://raw.githubusercontent.com/googxi1310328414-afk/claude-code-statusline/main/install.sh | bash
#
# 幂等：重复执行=更新（文件逐个比对，未变的跳过；settings 语义比对，
# 无实际变化不动文件）。在本地 clone 根目录执行时直接用本地文件，不联网。
# 可选参数（管道形式传参：`... | bash -s -- --with-watchdog`）：
#   --with-watchdog   顺带注册 Windows 看门狗计划任务（每 2 分钟自愈清理）
# 安装内容：四个渲染/钩子脚本 + 看门狗两件套 原子写入 ~/.claude/、
# 建 ~/.claude/statusline-panel.d/、settings.json **合并**（原文件先备份，
# 任何一步失败都不动原配置）、装完冒烟渲染验证。保存即生效，无需重启。
export LC_ALL=C.UTF-8

REPO_TARBALL="https://github.com/googxi1310328414-afk/claude-code-statusline/archive/refs/heads/main.tar.gz"
INSTALL_FILES=(statusline-command.sh subagent-statusline.sh statusline-panel-hook.sh statusline-panel-daemon.sh statusline-watchdog.ps1 statusline-watchdog.vbs)
CLAUDE_DIR="${HOME}/.claude"

with_watchdog=0
for arg in "$@"; do [ "$arg" = "--with-watchdog" ] && with_watchdog=1; done

say() { printf '%s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

# ---------- 前置检查 ----------
[ -n "${BASH_VERSINFO:-}" ] || die "需要 bash 运行本安装器"
# 4.3，不是 4（round-15）：渲染用 `local -n` 名引用（4.3+），`printf
# '%(fmt)T'` 需 4.2+。在 4.0-4.2（如 CentOS 7 自带的 4.2.46）上 `local -n`
# 报 invalid option 后函数继续跑，四行全为空串——正是本项目自定的白屏红线，
# 而下面的冒烟判据只看「输出非空」，纯转义码同样非空，于是照样报「通过」。
[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; } ||
  die "需要 bash >= 4.3（渲染用 local -n 名引用；Git Bash 自带 5.x）"
command -v jq >/dev/null 2>&1 || die "缺 jq（状态栏运行必需）：winget install jqlang.jq 或 pacman -S jq"
command -v git >/dev/null 2>&1 || say "⚠ 未找到 git：分支/脏标/stash 段将不显示，其余功能不受影响"

# ---------- 取文件：本地 clone 优先，否则下载 tarball ----------
src_dir=""
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)
if [ -n "$script_dir" ] && [ -f "$script_dir/statusline-command.sh" ] && [ -f "$script_dir/settings-snippet.json" ]; then
  src_dir="$script_dir"
  say "→ 本地模式：使用 $src_dir"
else
  command -v curl >/dev/null 2>&1 || die "缺 curl"
  command -v tar >/dev/null 2>&1 || die "缺 tar"
  dl_tmp=$(mktemp -d) || die "mktemp 失败"
  trap 'rm -rf "$dl_tmp"' EXIT
  say "→ 下载 $REPO_TARBALL"
  curl -fsSL "$REPO_TARBALL" | tar -xz -C "$dl_tmp" || die "下载/解包失败（网络或 GitHub 可达性）"
  for d in "$dl_tmp"/*/; do src_dir="${d%/}"; break; done
  [ -n "$src_dir" ] && [ -f "$src_dir/statusline-command.sh" ] || die "包内容异常"
fi

# ---------- 语法门 + 原子安装 ----------
mkdir -p "$CLAUDE_DIR" "$CLAUDE_DIR/statusline-panel.d" || die "无法创建 $CLAUDE_DIR"
daemon_updated=0
for f in "${INSTALL_FILES[@]}"; do
  [ -f "$src_dir/$f" ] || die "包内缺少 $f"
  case "$f" in *.sh) bash -n "$src_dir/$f" || die "$f 语法检查未过（下载损坏？）" ;; esac
  if [ -f "$CLAUDE_DIR/$f" ] && cmp -s "$src_dir/$f" "$CLAUDE_DIR/$f"; then
    say "= $f 已是最新"
    continue
  fi
  # 原子安装：绝不让正被 2 秒刷新循环执行中的脚本读到半截文件
  cp "$src_dir/$f" "$CLAUDE_DIR/.install.$f.$$" && mv -f "$CLAUDE_DIR/.install.$f.$$" "$CLAUDE_DIR/$f" || die "安装 $f 失败"
  chmod +x "$CLAUDE_DIR/$f" 2>/dev/null
  say "✓ $f 已安装"
  [ "$f" = "statusline-panel-daemon.sh" ] && daemon_updated=1
done

# ---------- 常驻 daemon 回收（仅 daemon 本体更新时） ----------
# daemon 是常驻进程：磁盘上换了新文件，跑着的还是旧代码——不回收的话
# 修复对活跃会话永不生效，卡死的旧实例更是探活恒真、永不被替换。渲染
# 脚本(subagent-statusline.sh)不用重启——daemon 每帧都是新的子进程读盘。
if [ "$daemon_updated" -eq 1 ]; then
  daemon_pid_file="$CLAUDE_DIR/statusline-panel.d/daemon.pid"
  # 全量回收（round-9，事故驱动）：旧版只读 pid 文件里那一个、且只在
  # 「心跳新鲜」时才杀——恰好把真正该回收的卡死实例排除在外（它心跳
  # 必然陈旧），未注册的堆叠实例更是够不到。实测后果：本机曾累积 78 个
  # 孤儿 daemon 常驻烧掉 22 CPU 小时，且全都在跑旧代码。现按命令行匹配
  # 杀掉**所有**面板 daemon（它们是本项目自己的进程、名字唯一），下一拍
  # 钩子会以新版拉起一个。
  # 只回收「注册在案」的那一个（round-10）：早先按命令行匹配的做法看似
  # 稳妥，实测却会把任何**提及**该文件名的外壳（诊断命令、测试脚本、AI
  # 代理自己的 bash——它们的命令行同样以该文件名结尾）一并 -Force 杀掉，
  # 与 2026-08-13 的误杀事故同型。现改为读 pid 文件：第 1 行 cygwin pid
  # 用于 kill，第 3 行 Windows pid 交给 PowerShell 兜底（cygwin 的 ps 看
  # 不到全部实例）。未注册的孤儿由看门狗按心跳陈旧回收，或随其 1 小时
  # 寿命闸自然退出——两条路都不需要模糊匹配。
  recycled=0
  old_dp=""; old_hb=""; old_wp=""; old_rp=""
  if [ -r "$daemon_pid_file" ]; then
    { read -r old_dp; read -r old_hb; read -r old_wp; read -r old_rp; } < "$daemon_pid_file" 2>/dev/null
  fi
  # 身份确认后才发信号（round-11）：只凭「数字 pid + kill -0」就杀，等于
  # 相信一个可能早已被系统回收给别人的 pid——daemon 没有 trap，任何强杀
  # 路径（钩子 REAP / 看门狗 / 重启）都会把 pid 文件留在盘上，而 cygwin
  # pid 回收极快、重启后更从低位重排，「重启后跑一次 curl | bash 更新」
  # 就可能对用户自己的交互 Git Bash、宿主 bash、甚至正在跑 install 的
  # 这棵进程树连发 TERM+KILL（与 2026-08-13/14 两次误杀事故同型）。
  # 判据与钩子完全一致：cmdline 尾部必须就是 daemon 脚本；读不到就不杀。
  # 身份读取零派生（round-13 现场事故）：原先用 `$(tr ... < cmdline)`，
  # 而命令替换要 fork——恰恰在 fork 枯竭这条路径上失败，捕获为空、模式不
  # 匹配、于是**什么都不杀却照样拉新**，等于把 78 孤儿事故的放大器原样装
  # 回来。cmdline 是 NUL 分隔的，`read -d ''` 纯内建即可读，且判据收窄为
  # 「最后一个 argv 元素」并排除任何带裸 `-c` 的外壳。
  old_cmd=""
  old_ok=0
  if [[ "$old_dp" =~ ^[0-9]+$ ]] && kill -0 "$old_dp" 2>/dev/null && [ -r "/proc/$old_dp/cmdline" ]; then
    old_arg=""; old_isc=0
    while IFS= read -r -d '' old_arg; do
      [ "$old_arg" = "-c" ] && old_isc=1
      old_cmd=$old_arg
      old_arg=""
    done < "/proc/$old_dp/cmdline" 2>/dev/null
    [ -n "$old_arg" ] && old_cmd=$old_arg
    [ "$old_isc" -eq 1 ] && old_cmd=""
    case "$old_cmd" in
      *statusline-panel-daemon.sh) old_ok=1 ;;
    esac
  fi
  if [ "$old_ok" -eq 1 ]; then
    kill "$old_dp" 2>/dev/null && recycled=1
    sleep 1
    kill -9 "$old_dp" 2>/dev/null
  fi
  # 第 4 行是它在途的渲染子进程（round-13）：daemon 被杀后它会变成孤儿
  # 继续跑并占着 tmp 名，而它的 pid 从外部无从推导——daemon 自己不是进程
  # 组长（`( bash ... & )` 无作业控制派生），杀「它的组」什么也够不着。
  # 渲染子进程则是在 `set -m` 下起的、自成一组，可以连它的 jq 一起收掉。
  if [[ "$old_rp" =~ ^[0-9]+$ ]] && kill -0 "$old_rp" 2>/dev/null; then
    old_rcmd=""; old_rarg=""; old_risc=0
    while IFS= read -r -d '' old_rarg; do
      [ "$old_rarg" = "-c" ] && old_risc=1
      old_rcmd=$old_rarg
      old_rarg=""
    done < "/proc/$old_rp/cmdline" 2>/dev/null
    [ -n "$old_rarg" ] && old_rcmd=$old_rarg
    [ "$old_risc" -eq 1 ] && old_rcmd=""
    case "$old_rcmd" in
      *subagent-statusline.sh)
        kill -- "-$old_rp" 2>/dev/null
        kill "$old_rp" 2>/dev/null
        kill -9 -- "-$old_rp" 2>/dev/null ;;
    esac
  fi
  # Windows 侧兜底（cygwin 的 ps/kill 看不到全部实例）。判据必须与看门狗
  # 完全同款（round-14）：此前只有 `-match 'statusline-panel-daemon'`，
  # 既无 argv 位置尾锚也不排除 `-c` 外壳——正是 AI-GUIDE §4 明令「绝不可」
  # 的提及型匹配。daemon 没有 trap，任何强杀都会把 pid 文件连同第 3 行
  # winpid 留在盘上，而 Windows pid 重启后从低位重排、回收极快：那个陈旧
  # winpid 只要落到任意一个命令行里**提到**该文件名的 bash.exe（诊断命令、
  # 测试脚本、AI 代理自己的 bash——本机极常见），跑一次更新就会把它
  # -Force 杀掉，与 2026-08-13/14 两次误杀事故同型。
  # 这条路刻意不受上面 old_ok 约束：cygwin 侧确认不了（进程它根本看不到）
  # 正是它存在的理由；安全性由这里自己这份同等严格的判据保证。
  # 且只有真的杀掉了才算「已回收」——原先无条件置位，什么都没杀也报成功。
  if [[ "$old_wp" =~ ^[0-9]+$ ]] && command -v powershell.exe >/dev/null 2>&1; then
    ps_killed=$(powershell.exe -NoProfile -NonInteractive -Command "\$p = Get-CimInstance Win32_Process -Filter \"ProcessId=$old_wp\" -ErrorAction SilentlyContinue; if (\$p -and \$p.Name -eq 'bash.exe' -and \$p.CommandLine -notmatch '\s-c\s' -and \$p.CommandLine -match 'bash(\.exe)?\"?\s+\"?[^\"]*statusline-panel-daemon\.sh(\s|\"|\$)') { Stop-Process -Id $old_wp -Force -ErrorAction SilentlyContinue; 'KILLED' }" 2>/dev/null | tr -d '\r\n')
    [ "$ps_killed" = "KILLED" ] && recycled=1
  fi
  [ "$recycled" -gt 0 ] && say "✓ 旧面板 daemon 已回收——下一拍钩子自动以新版拉起"
  # pid 文件与在途渲染残骸一并清掉，避免新实例读到陈旧注册
  rm -f "$daemon_pid_file" "$CLAUDE_DIR/statusline-panel.d"/render.* "$CLAUDE_DIR/statusline-panel.d"/*.raw 2>/dev/null
fi

# ---------- settings.json 合并（保留既有键；失败不落地） ----------
snippet="$src_dir/settings-snippet.json"
settings="$CLAUDE_DIR/settings.json"
if [ ! -f "$settings" ]; then
  cp "$snippet" "$settings" || die "创建 settings.json 失败"
  say "✓ settings.json 已创建"
else
  merged=$(jq -s '.[0] * .[1]' "$settings" "$snippet" 2>/dev/null) || merged=""
  [ -n "$merged" ] || die "现有 settings.json 无法解析（JSON 语法错误？）——未做任何修改"
  if [ "$(jq -S . "$settings" 2>/dev/null)" = "$(jq -S . <<< "$merged")" ]; then
    say "= settings.json 配置已就位"
  else
    backup="$settings.bak-install-$(date +%Y%m%d-%H%M%S)"
    cp "$settings" "$backup" || die "备份 settings.json 失败——未做任何修改"
    printf '%s\n' "$merged" > "$settings.tmp.$$" && mv -f "$settings.tmp.$$" "$settings" || die "写入 settings.json 失败（备份在 $backup）"
    say "✓ settings.json 已合并（原文件备份：${backup##*/}）"
  fi
fi

# ---------- 看门狗计划任务（可选，仅 Windows） ----------
if [ "$with_watchdog" -eq 1 ]; then
  if command -v schtasks.exe >/dev/null 2>&1; then
    win_home=$(cygpath -w "$HOME" 2>/dev/null) || win_home="$HOME"
    if schtasks.exe /Create /F /SC MINUTE /MO 2 /TN claude-statusline-watchdog /TR "wscript.exe \"$win_home\\.claude\\statusline-watchdog.vbs\"" >/dev/null 2>&1; then
      say "✓ 看门狗计划任务已注册（每 2 分钟，wscript 零窗口拉起）"
    else
      say "⚠ 计划任务注册失败（权限？）——可手动：schtasks /Create /F /SC MINUTE /MO 2 /TN claude-statusline-watchdog /TR \"wscript.exe $win_home\\.claude\\statusline-watchdog.vbs\""
    fi
  else
    say "⚠ 非 Windows 环境，跳过看门狗"
  fi
elif command -v schtasks.exe >/dev/null 2>&1 && ! schtasks.exe /Query /TN claude-statusline-watchdog >/dev/null 2>&1; then
  say "ℹ 可选自愈层未注册：重新执行并加 --with-watchdog（管道形式：| bash -s -- --with-watchdog）"
fi

# ---------- 冒烟验证（状态文件全部隔离，不碰真实数据） ----------
# 冒烟状态文件改放临时目录（round-10）：脱离式 usage 子壳会在父渲染退出
# **之后**才写退避文件，放在 $CLAUDE_DIR 时那次写入总是晚于清理行，于是
# 每装一次就在真实 ~/.claude 永久留一个 .smoke-ub.<pid>，且没有任何清扫
# glob 覆盖它。临时目录整体删除，不留痕。
smoke_tmp=$(mktemp -d) || die "mktemp 失败"
smoke_payload=$(printf '{"session_id":"install-smoke","model":{"display_name":"Smoke"},"workspace":{"current_dir":"%s"}}' "$HOME")
# 全部 env 覆盖都要给（round-7）：只隔离 history/daily 时，wk 段仍会
# 派生后台任务读真实 .credentials.json 的 OAuth token 去打非官方 usage
# 端点，并往真实 ~/.claude 写缓存/退避——一行安装命令不该在用户不知情
# 时动用其凭据发网络请求。CRED 指向不存在的路径即可完全断开该链路。
smoke_out=$(printf '%s' "$smoke_payload" |   STATUSLINE_HISTORY_FILE="$smoke_tmp/h"   STATUSLINE_DAILY_FILE="$smoke_tmp/d"   STATUSLINE_CI_CACHE_PREFIX="$smoke_tmp/ci"   STATUSLINE_USAGE_CACHE_FILE="$smoke_tmp/uc"   STATUSLINE_USAGE_BACKOFF_FILE="$smoke_tmp/ub"   STATUSLINE_CRED_FILE="$smoke_tmp/nocred"   bash "$CLAUDE_DIR/statusline-command.sh" 2>/dev/null)
rm -rf "$smoke_tmp" 2>/dev/null
[ -n "$smoke_out" ] || die "主状态栏冒烟渲染无输出"
smoke_line1=$(printf '%s' "$smoke_out" | sed -n 1p | sed 's/\x1b\[[0-9;]*m//g; s/\x1b\]8;;[^\x1b]*\x1b\\\\//g')
# 「非空」不够（round-15）：一行纯转义码同样非空。剥色后必须还剩可见内容，
# 否则就是白屏——它长得跟成功一模一样，只有这一条判据能把它认出来。
[ -n "$(printf '%s' "$smoke_line1" | tr -d ' \t')" ] || die "主状态栏冒烟渲染只有转义码（剥色后为空）"
# 降级行同样「剥色后可见」（round-16）：渲染脚本无法渲染时输出的正是
# 一行 `HH:MM:SS | statusline: degraded (fork)`——jq 在场但跑不通（不带
# oniguruma 编译的 jq 使 gsub 未定义、jq 过老、脚本被截断），装机那一刻
# fork 枯竭也会走到这里。旧判据把它当成功，于是一行命令告诉用户「已验证
# 通过」，而此后每一帧状态栏永远只有那行降级文本。这类「长得跟成功一模
# 一样」的失败正是冒烟要挡的东西。
case "$smoke_line1" in
  *'statusline: degraded'*|*'statusline: jq missing'*)
    die "主状态栏冒烟只得到降级行（$smoke_line1）：jq 存在但不可用（gsub 需 oniguruma 支持）或版本过老，装完也只会是这一行" ;;
esac
say "✓ 主状态栏冒烟通过：$smoke_line1"

panel_tmp=$(mktemp -d) || die "mktemp 失败"
printf '{"columns":100,"tasks":[{"id":"smoke","tokenCount":1,"description":"x"}]}' |
  STATUSLINE_PANEL_DIR="$panel_tmp" STATUSLINE_PANEL_DAEMON=/dev/null bash "$CLAUDE_DIR/statusline-panel-hook.sh" >/dev/null 2>&1
if [ -f "$panel_tmp/spool.smoke.new" ]; then
  say "✓ 面板钩子冒烟通过"
else
  rm -rf "$panel_tmp"
  die "面板钩子冒烟失败"
fi
rm -rf "$panel_tmp"

say ""
say "全部完成。状态栏在下一次刷新即生效（无需重启 Claude Code）。"
say "卸载：删除 ~/.claude/statusline-*.sh、statusline-watchdog.*、statusline-panel.d/，"
say "     移除 settings.json 中 statusLine/subagentStatusLine 两键，"
say "     以及计划任务：schtasks /Delete /F /TN claude-statusline-watchdog"
exit 0
