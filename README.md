# claude-code-statusline

Claude Code 的信息密集型彩色状态栏（Windows / Git Bash，POSIX 兼容）：主会话四行主题网格 + 子代理面板表格行，每 2 秒自动刷新，数据缺失的段自动隐藏、整行为空时该行消失，关键指标随状态动态变色。MIT 协议；[English](README.en.md)。

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
| 1 | 身份与位置 | 秒级时钟 · 模型`·`思考档位（热度色）`·`think · 目录缩写（`~`/折叠，末级亮蓝）· `⎇`worktree · 仓库（**OSC 8 超链接**）· 分支+脏`*` · PR（**超链接** + 评审状态 + CI 徽记）|
| 2 | 上下文引擎 | `ctx` 五格电池（**占用=输入+最新输出**，`│`=80% 压缩线惯例标记，k/M 单位）· 消耗走势`▁▂▃▄▅▆`+速率（同段同色）· `cache 命中率一位小数 r/w量 新鲜度(hot→倒计时→cold)` · `↻`压缩次数`↓`回收量 |
| 3 | 花费 | `$`金额+`$X.X/h`速率 · `today` 今日跨会话总花费 · `week` 近 7 天总花费 · `+增/-删`行数 |
| 4 | 限额与会话 | `5h`/`7d` 用量%`·t`时间游标`→`重置时刻 · `wk` 按模型周配额（当前模型常显，他模型 ≥50% 才现身）· `extra` 付费溢出 · `»`会话名 |

**动态色语言**：额度/上下文/速率/花费/命中率各有绿黄红档；限额的用量百分比带**节奏覆盖**——额度%反超时间游标 `·t%` 即升黄、反超 15 点即亮红（"照这个速度撑不到重置"）。

## 子代理面板行（subagentStatusLine）

```
▸ 0.2.79 收尾与发布(local_agent) ● | 295k tok | ▆▃▁ 14.9k/m | Σ81% | 19m46s@09:43:00 | 同步文档并推送
▸ code-reviewer·max ✓              | 68k tok  | 10.8k/m     | Σ18% | 6m17s@09:56:29  | Review auth
```

- 灰`▸` + **亮紫**身份（主行是亮青，主/子一眼分）+ 灰`(类型)` + 青`·少数派模型`（仅与面板多数不同）+ 热度`·档位`（仅显式指定）+ 状态图标 `●`运行绿/`○`排队黄/`✗`失败红/`✓`完成绿
- `Nk tok` **累计消耗**（拒绝伪装成"窗口占用"的电池——tokenCount 是累计口径，宁精勿滥）· 走势+速率 · `Σ`份额（吞金兽 ≥75% 亮红）· 秒级用时`@`启动时刻 · 宽度预算截断的描述
- **表格对齐**：全面板逐列取最大宽度（真显示宽度：CJK=2 格），缺中间列垫空位、全空列整列裁掉；走势封顶 `▆` 防止多行上下粘连

## 工程规格（为什么它又快又稳）

- **每次渲染进程数 ≈ 2**（jq×1 + git×1；可选 tail/date×1）：所有辅助函数走 REPLY 无 fork 调用、`printf -v` 替代一切 `$(date)`、纯 bash 解析历史文件——从最初 35+ 进程/3 秒优化到 **<1 秒**，支撑 `refreshInterval: 2` 的常驻刷新
- **状态文件** `~/.claude/statusline-history.tsv`（0x1F 分隔，TAB 旧格式自动兼容迁移，按 8 天时间窗裁剪）驱动走势/速率/$每小时/today/week；`/clear` 重置按单调段分别计峰，不少算
- **防御体系**：全部字段 `// empty`+数值正则守卫、历史行整行形状校验、Windows jq 的 CRLF 剥离、`LC_ALL=C.UTF-8` 字符计宽、NBSP 对齐垫充（防 VSCode 终端吞空格）、行首 `\e[0m` 防宿主样式渗染、非零退出=白屏的红线
- **外部数据全部缓存+后台脱离刷新**：PR CI 状态（gh，60s）、周配额/溢出（OAuth `/api/oauth/usage`，180s+429 退避——**非官方端点**，随时可能失效，失效即整段静默消失）

## 依赖与安装

Claude Code ≥ 2.1.221（子代理 effort 字段）、Git Bash（bash ≥ 4.3，UTF-8）、`jq`、`git`；`gh` 可选（CI 徽记）。

1. 两个 `.sh` 复制到 `~/.claude/`（主目录自动检测，无需改路径）。
2. `~/.claude/settings.json` 合并 `settings-snippet.json`（statusLine + refreshInterval + subagentStatusLine 三键）。
3. 保存即生效。**推荐**：把 [`AI-GUIDE.md`](AI-GUIDE.md) 全文发给 Claude Code 让它替你装并按机器适配。

## 测试

```bash
bash test.sh            # 渲染演示（终端看真色彩）
bash test.sh --codes    # ANSI 码可视化
bash test.sh --assert   # 17 项断言（CI 用，含性能门槛）
```

GitHub Actions 在每次 push 自动跑断言套件。

## 已知边界

- 刷新由 `refreshInterval: 2` 驱动（事件另有 300ms 防抖）；渲染实测 0.7–1.3 秒。
- workflow/ultracode 编队渲染在 `/workflows` 专属 UI，**不经过** subagentStatusLine（实测）；面板行只承载常规子代理。
- 压缩计数/缓存倒计时读 transcript 尾部 128KiB（超出窗口的旧边界不计）；缓存倒计时的 TTL 是假设值（`STATUSLINE_CACHE_TTL_SECONDS`，默认 3600）。
- 电池上的 `│` 压缩线是 80% 社区惯例，非官方阈值。
- `date -d`（GNU）与 `printf '%(...)T'`（bash ≥4.2）；macOS 需改 `date -r`。
