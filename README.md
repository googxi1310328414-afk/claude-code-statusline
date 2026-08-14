# claude-code-statusline

[![test](https://github.com/googxi1310328414-afk/claude-code-statusline/actions/workflows/test.yml/badge.svg)](https://github.com/googxi1310328414-afk/claude-code-statusline/actions/workflows/test.yml)

Claude Code 的信息密集型彩色状态栏（Windows / Git Bash，POSIX 兼容）：主会话四行主题网格 + 子代理面板表格行，`refreshInterval` 常驻自动刷新（主 10s；面板为宿主固定 ~5s 节拍，机理见专章），数据缺失的段自动隐藏、整行为空时该行消失，关键指标随状态动态变色。MIT 协议；[English](README.en.md)。

![效果预览](assets/preview.svg)

```
10:02:45                            | Fable 5·max·think | ~\proj\webapp                   | acme/webapp | main* | PR#42 approved
ctx ███░│ 66% 70k/200k              | ▆▆▁ 4.9k/m        | cache 92.3% r60.0k·w312 44m55s  | ↻2 ↓230k
$0.42 $4.8/h                        | today $55.97      | week $89.20                     | +156/-23
5h 37%·t60%→12:02 7d 12%·t57%→08-16 | wk Fab8%          | » my-session
```

## 四行主题布局（列网格对齐）

| 行 | 主题 | 段 |
|---|---|---|
| 1 | 身份与位置 | 秒级时钟 · 模型短 id 名（同面板规则，保 `[1m]`，无 id 回退 display_name）`·`思考档位（热度色）`·`think · 目录缩写（`~`/折叠，末级亮蓝）· `⎇`worktree · 仓库（**OSC 8 超链接**）· 分支+脏`*` · `⚑`stash 数（≥5 亮红，0 隐藏）· PR（**超链接** + 评审状态 + CI 徽记）|
| 2 | 上下文引擎 | `ctx` 五格电池（**占用=输入+最新输出**，`│`=80% 压缩线惯例标记，k/M 单位）· 消耗走势`▁▂▃▄▅▆`+速率（同段同色）· `cache 命中率一位小数 r/w量 新鲜度(hot→倒计时→cold)` · `↻`压缩次数`↓`回收量 |
| 3 | 花费 | `$`金额+`$X.X/h`速率 · `today` 今日跨会话总花费 · `week` 近 7 天总花费 · `+增/-删`行数 |
| 4 | 限额与会话 | `5h`/`7d` 用量%`·t`时间游标`→`重置时刻 · `wk` 按模型周配额（当前模型常显，他模型 ≥50% 才现身）· `extra` 付费溢出 · `»`会话名 |

**动态色语言**：额度/上下文/速率/花费/命中率各有绿黄红档；限额的用量百分比带**节奏覆盖**——额度%反超时间游标 `·t%` 即升黄、反超 15 点即亮红（"照这个速度撑不到重置"）。

## 子代理面板行（subagentStatusLine）

```
▸ 0.2.79 收尾与发布(local_agent) ● | 295k tok | ▆▃▁ 14.9k/m | Σ81% | 19m46s@09:43:00 | 同步文档并推送
▸ code-reviewer·max ✓              | 68k tok  | 10.8k/m     | Σ18% | 6m17s@09:56:29  | Review auth
```

- 灰`▸` + **身份分色**：等待/终态用语义色（排队黄/完成绿/失败亮红），**运行中的代理按 task id 稳定哈希取色**（亮青/亮蓝/亮紫/青/蓝/亮白六色轮转，同一代理终生同色、跨帧跨会话稳定）——running 是绝大多数时间的状态，若也用固定色，整块面板就会读成一片同色，现在并发的几个代理一眼分得开——身份是行内最宽最靠左的字段，让它直接承载状态，一眼扫左边缘就知道每个代理在干什么；主行身份是亮青，主/子仍一眼分）+ 灰`(类型)` + 热度`·档位`（仅显式指定）+ 状态图标 `●`运行绿/`○`排队黄/`✗`失败红/`✓`完成绿（形状与颜色双编码）；紧随其后是**独立模型列**（青短名恒显，剥 `claude-` 前缀与日期后缀、**保留** `[1m]` 容量标记；全面板无模型则整列裁掉）
- `Nk tok` **累计消耗**（拒绝伪装成"窗口占用"的电池——tokenCount 是累计口径，宁精勿滥）· 走势（**自建 10s 采样**，每格≈10s；冷启动回退宿主 tokenSamples）+速率 · `Σ`份额（吞金兽 ≥75% 亮红）· 秒级用时**按时长分档**（<2min 灰/<10min 白/<30min 黄/≥30min 亮红）`@`启动时刻 · 宽度预算截断的描述
- **表格对齐**：全面板逐列取最大宽度（真显示宽度：CJK=2 格），缺中间列垫空位、全空列整列裁掉；走势封顶 `▆` 防止多行上下粘连

## 工程规格（为什么它又快又稳）

- **每次渲染进程数 ≈ 2**（jq×1 + git×1；可选 tail/date×1）：所有辅助函数走 REPLY 无 fork 调用、`printf -v` 替代一切 `$(date)`、纯 bash 解析历史文件——从最初 35+ 进程/3 秒优化到 **<1 秒**，支撑秒级 `refreshInterval` 常驻刷新（取消规则要求渲染远快于间隔——见"自动刷新机制"）
- **状态文件双层**：细粒度 `statusline-history.tsv`（0x1F，TAB 旧格式自动兼容，**90 分钟**窗）只养走势/速率/$每小时；today/week 走 `statusline-daily.tsv` 日聚合（单调段状态机 + 水位线增量：重放不双计、并发丢写自愈、首跑自动播种）——每帧不再重走几万行历史；写入**追加优先**（最老行超窗 30 分钟/行帽/脏行才全量重写，稳态磁盘 churn −95%）；`/clear` 重置按单调段分别计峰，不少算
- **防御体系**：全部字段 `// empty`+数值正则守卫、历史行整行形状校验、Windows jq 的 CRLF 剥离、`LC_ALL=C.UTF-8` 字符计宽、NBSP 对齐垫充（防 VSCode 终端吞空格）、行首 `\e[0m` 防宿主样式渗染、非零退出=白屏的红线
- **外部数据全部缓存+后台脱离刷新**：PR CI 状态（gh，60s，**按 repo+PR 分键**的缓存文件——多会话停在不同 PR 不再互相驱逐；gh 无结果也写**负缓存**，未登录/断网时按 TTL 重试而非每帧重派生）、周配额/溢出（OAuth `/api/oauth/usage`，180s+429 退避——**非官方端点**，随时可能失效，失效即整段静默消失）

## 依赖与安装

Claude Code ≥ 2.1.221（子代理 effort 字段）、Git Bash（bash ≥ 4.3，UTF-8）、`jq`、`git`（stash 段需 ≥2.35，更旧仅少这一段）；`gh` 可选（CI 徽记）。

**一行命令**（推荐，幂等：重复执行=更新；在本地 clone 里执行则离线用本地文件）：

```bash
curl -fsSL https://raw.githubusercontent.com/googxi1310328414-afk/claude-code-statusline/main/install.sh | bash
```

自动完成：语法门 + 四脚本原子安装、`statusline-panel.d/` 目录、settings.json **合并**（保留既有键，原文件自动备份，语义无变化不动文件）、冒烟渲染验证；追加 ` -s -- --with-watchdog` 顺带注册看门狗计划任务。手动安装：

1. 四个 `.sh`（两个渲染脚本 + `statusline-panel-hook.sh`/`statusline-panel-daemon.sh`）复制到 `~/.claude/`（主目录自动检测，无需改路径），并创建目录 `~/.claude/statusline-panel.d/`。
2. `~/.claude/settings.json` 合并 `settings-snippet.json`（statusLine 含 `refreshInterval: 10`；subagentStatusLine 指向面板钩子，**勿配** refreshInterval——宿主不认，见"自动刷新机制"）。
3. 保存即生效。**推荐**：把 [`AI-GUIDE.md`](AI-GUIDE.md) 全文发给 Claude Code 让它替你装并按机器适配。

## 测试

```bash
bash test.sh            # 渲染演示（终端看真色彩）
bash test.sh --codes    # ANSI 码可视化
bash test.sh --assert   # 104 项断言（CI 用，含性能门槛与十一轮对抗审查回归组+配色断言）
```

GitHub Actions 在每次 push 自动跑断言套件。

## 自动刷新机制（重点）

状态栏能"自己动"靠两层驱动叠加，任何一层的参数配错都可能变成一栏空白——以下是实测（含一次生产事故）换来的完整机理：

1. **事件驱动打底**：宿主在新助手消息、`/compact`、权限切换等时刻重跑脚本（约 300ms 防抖）。只有这层时，空闲期状态栏静止不动。
2. **`refreshInterval: N`（秒）常驻定时器**：settings.json 配上后，空闲时宿主也每 N 秒把最新 stdin JSON 喂给脚本**整个重跑一遍**、用输出重画。每帧都是全新进程、无常驻驻留——跨帧记忆（走势/速率/today/week/子代理采样）全部依赖 `~/.claude` 下的状态文件续命，这是"无状态脚本 + 有状态文件"的刻意设计。命令写成 `exec bash ~/.claude/…`（见 settings-snippet）可省掉宿主 `-c` 包装壳那一层进程。
3. **取消规则（生死线）**：新触发到来时宿主会 **taskkill 杀掉仍在跑的上一帧**。因此 **N 必须显著大于最坏渲染耗时**——一旦机器负载把渲染拖过 N 秒，就进入"帧帧被杀→输出永远到不了终点→整栏空白"的取消风暴（2026-08-13 双会话 fork 枯竭实锤：渲染被拖过 2s 间隔，黑匣子与进程启动追踪均有存证）。本仓库默认主栏 **10s**（**负载优先**：渲染实测 ~0.3-0.5s，但多会话+代理编队的风暴期会拖长，10s 为取消规则留足余量并压低常驻进程流量；代价是数据滞后≤10s，属明确接受的取舍）；子代理面板的节拍**由宿主固定**（2.1.229 实测精确 ~5s 一拍，`refreshInterval` 键对 subagentStatusLine 无效，勿配）。
4. **配置热重载**：宿主对 settings.json 做**内容**监听——改任意值保存，渲染循环 1 秒内重建（仅 touch mtime **无效**）。渲染循环因挂死彻底卡住时，这也是唯一免重启的复活手段。
5. **忙碌回合**：主栏**画面**冻结在回合开始帧，但**调用照常**（状态文件持续新鲜，回合结束瞬间回正）；子代理面板不受此限、全程实时。
6. **采样与刷新的配比**：主栏 10s 刷新 × 30s 采样节流 = 每三帧记一次历史（走势每格≈30s，整图窗口 ~4.5 分钟）；面板宿主 ~5s 节拍 × 10s 采样 = 每两帧一样（每格≈10s）。刷新间隔管"画面多新"，采样节流管"走势每格多长"——两个旋钮独立调。
7. **自愈层（可选，Windows）**：`statusline-watchdog.ps1` 由计划任务每 2 分钟清理挂死 >30s 的渲染 bash（fork 枯竭下的兜底）；**必须经 `statusline-watchdog.vbs`（wscript）拉起**——计划任务直接跑 powershell 会在 `-WindowStyle Hidden` 生效前闪一下控制台窗口。两文件复制到 `~/.claude/`（vbs 经 `%USERPROFILE%` 运行时解析路径，任意用户开箱即用、无需改内容；**vbs 必须保持纯 ASCII**——wscript 按系统 ANSI 码页解析，UTF-8 中文注释会在 GBK 下吞换行、把真代码吞进注释，实锤过每 2 分钟弹错误框，test.sh 有断言防复发）后：`schtasks /Create /SC MINUTE /MO 2 /TN claude-statusline-watchdog /TR "wscript.exe C:\Users\<你>\.claude\statusline-watchdog.vbs"`。
8. **面板常驻 daemon**：subagentStatusLine 命令指向 `statusline-panel-hook.sh`——钩子只做"倒载荷 + 秒回上一帧缓存"（纯内建，稳态零派生，延迟≈bash 启动的毫秒级），真正的渲染由 `statusline-panel-daemon.sh` 异步完成（内容滞后一拍 ~5s，对累计 token/用时无感知）。宿主重画面板是"先默认行、钩子返回才替换"，钩子延迟=默认行闪烁窗口——daemon 化把它从整段渲染耗时（~300ms）压到毫秒级。缓存键=载荷首任务 id（并发会话任务集不相交，天然各用各的缓存）；面板缓存首行为渲染纪元、钩子拒供 >60s 陈旧帧（daemon 起不来时诚实降级为默认行而非永久回放冻结帧）；daemon 单实例（noclobber 抢占；pid 文件两行协议 pid+心跳，daemon 墙钟 5s 原子刷新心跳、钩子/接管/install 三处判活统一"kill -0 + 心跳 60s 内"——残留 pid 被系统回收给无关进程时不再死锁或误杀；陈旧 pid 接管走"删除+独占重建"而非裸覆写，退出删除先验证 pid 归属——并发接管不再互踩）、无活 2 分钟自灭、死了由下一拍钩子拉起；**挂死的渲染子进程由 daemon 自身硬超时截杀跳帧**（默认 15s，`STATUSLINE_PANEL_RENDER_TIMEOUT` 可调，约为正常渲染的 50 倍——此前无超时，子进程一挂 daemon 即永久卡死、探活却始终"存活"，全部会话面板冻结在旧帧且默认安装无任何恢复路径；第 7 条看门狗现按**心跳陈旧**判据纳入 daemon 回收，钩子发现「pid 活着但心跳冻结」会先杀后拉，daemon 另有绝对寿命闸 1 小时（`STATUSLINE_PANEL_DAEMON_MAX_LIFE`）——2026-08-14 实测过一次事故：一个卡死实例使钩子每 ~65 秒拉起一个新 daemon，累计 **78 个孤儿常驻烧掉 22 CPU 小时**，当时无任何组件负责回收；另注意 **cygwin 的 `ps` 看不到全部实例**，回收必须走 Windows 进程表）——全链路自愈，无需手工管理。状态目录 `~/.claude/statusline-panel.d/`。

## 已知边界

- 渲染实测 0.4–1.3 秒（隔离基准 0.4–0.6s，真实载荷 ~1.2s）；刷新机理与取消规则见上一章。
- **"刷新了但数字没动"是上游数据节奏**：宿主载荷里的 token/cost 只在每次 API 响应边界前进（实测同值连续 2-4 帧、平台期 ~20-40s，长工具调用/长生成期间更久），渲染忠实镜像宿主账目——非脚本滞后，脚本侧无解。
- **忙碌回合中主状态栏绘制完全挂起**（实测：脚本仍按节奏被调用、数据保持新鲜，但画面冻结在回合开始帧；resize/交互均无法强制重画；回合结束瞬间回正）。同屏子代理面板不受此限、全程实时。根治需官方支持，可 `/feedback` 提"busy 期间按 refreshInterval 重绘 statusLine"。
- workflow/ultracode 编队渲染在 `/workflows` 专属 UI，**不经过** subagentStatusLine（实测）；面板行只承载常规子代理。
- 压缩计数/缓存倒计时读 transcript 尾部窗口（默认 512KiB，`STATUSLINE_TRANSCRIPT_TAIL_BYTES` 可调；重会话单条 JSONL 实测已达 114KiB——单条超窗会让两段静默消失，故留 ~4× 余量），超出窗口的旧边界不计；窗口扫描由 `tail | awk` 一次管道预滤（+1 fork，毫秒级）——bash 侧只拆有效行，**帧耗随命中数而非窗口字节数走**（旧实现 `mapfile` 整窗拆行实测 ~3.5μs/字节、满窗每帧 ~1.8s，已修）；窄终端（<100 列）该块整体跳过（紧凑行本就没有这两段）。缓存倒计时的 TTL 是假设值（`STATUSLINE_CACHE_TTL_SECONDS`，默认 3600）。
- 电池上的 `│` 压缩线是 80% 社区惯例，非官方阈值。
- `date -d`（GNU）与 `printf '%(...)T'`（bash ≥4.2）；macOS 需改 `date -r`。
