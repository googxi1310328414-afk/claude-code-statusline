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
[ "${BASH_VERSINFO[0]}" -ge 4 ] || die "需要 bash >= 4（Git Bash 自带 5.x）"
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
  old_dp=""
  old_hb=""
  [ -r "$daemon_pid_file" ] && { read -r old_dp; read -r old_hb; } < "$daemon_pid_file" 2>/dev/null
  # 与钩子/接管同一套判活（数字 pid + 心跳 60s 内 + kill -0）——残留 pid
  # 被系统回收给无关进程时，裸 kill 会把 SIGTERM 发给无辜进程（另一
  # 会话的 bash/git 都可能中招）；判不活就只删 pid 文件
  old_alive=0
  if [[ "$old_dp" =~ ^[0-9]+$ ]] && [[ "$old_hb" =~ ^[0-9]+$ ]]; then
    now_i=$(date +%s)
    hb_age=$(( now_i - old_hb ))
    [ "$hb_age" -ge -60 ] && [ "$hb_age" -le 60 ] && kill -0 "$old_dp" 2>/dev/null && old_alive=1
  fi
  if [ "$old_alive" -eq 1 ]; then
    kill "$old_dp" 2>/dev/null
    say "✓ 旧面板 daemon(pid $old_dp) 已回收——下一拍面板钩子自动以新版拉起"
  fi
  # 被 SIGTERM 杀掉的 daemon 走不到退出清理——顺手删掉 pid 文件，
  # 免得残留 pid 被系统回收给无关进程后欺骗钩子的探活（心跳机制
  # 是主防线，这里是零成本的辅助卫生）
  rm -f "$daemon_pid_file" 2>/dev/null
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
smoke_payload=$(printf '{"session_id":"install-smoke","model":{"display_name":"Smoke"},"workspace":{"current_dir":"%s"}}' "$HOME")
smoke_out=$(printf '%s' "$smoke_payload" | STATUSLINE_HISTORY_FILE="$CLAUDE_DIR/.smoke-h.$$" STATUSLINE_DAILY_FILE="$CLAUDE_DIR/.smoke-d.$$" bash "$CLAUDE_DIR/statusline-command.sh" 2>/dev/null)
rm -f "$CLAUDE_DIR/.smoke-h.$$" "$CLAUDE_DIR/.smoke-d.$$" 2>/dev/null
[ -n "$smoke_out" ] || die "主状态栏冒烟渲染无输出"
smoke_line1=$(printf '%s' "$smoke_out" | sed -n 1p | sed 's/\x1b\[[0-9;]*m//g; s/\x1b\]8;;[^\x1b]*\x1b\\\\//g')
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
