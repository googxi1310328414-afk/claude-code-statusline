# AI 复刻指导：Claude Code 四行彩色状态栏 + 子代理面板行

> **用法**：把本文件全文发给 Claude Code（或任何能读写文件、执行 shell 的 AI agent），说"按这份指导配置状态栏"。本文是完整规格：数据契约、每段的格式/颜色/阈值、状态文件、健壮性要求、安装与验证。仓库根目录有参考实现（`statusline-command.sh`、`subagent-statusline.sh`），但你（AI）应按规格在目标机器上适配重建，而不是盲目复制。

## 0. 前置检查

1. 环境：bash ≥ **4.3**（渲染用 `local -n` 名引用，4.3+；`printf '%(fmt)T'` 需 4.2+。4.0-4.2 上 `local -n` 报 invalid option 后函数继续跑、四行全空 = 白屏，而「输出非空」式的冒烟判据认不出来——安装器已按 4.3 卡闸并加了「剥色后仍有可见内容」的判据）（Windows 用 Git Bash），`jq`、`git` 可用（git ≥2.35 才有 stash 段，更旧则该段自动消失）；`locale charmap` 应为 UTF-8（否则多字节字符宽度计数会提前截断）。
2. 确认目标机器**主目录**，目录缩写逻辑用它，不要硬编码别人的路径。
3. `date -d "@epoch"` 是 GNU 语法（Git Bash/Linux）；macOS/BSD 用 `date -r epoch`。
4. **Windows 陷阱**：Windows 版 jq 输出 CRLF。`$(...)` 命令替换在 MSYS bash 会剥掉尾部 `\r`，**但 `mapfile`/`read` 逐行读不会**——凡逐行读 jq 输出，必须管过 `tr -d '\r'`，否则数值校验全部静默失败。**`.ps1` 必须带 UTF-8 BOM**（PowerShell 5.1 对无 BOM 的 .ps1 按系统 ANSI 码页解码，本机 GBK——与下面 vbs 同一个坑，只是 CRLF 恰好挡住了它；test.sh 有 BOM 断言）。**`.vbs` 必须纯 ASCII + CRLF**：wscript 按系统 ANSI 码页（本机 GBK）解析 vbs，行尾 UTF-8 多字节字符的末字节若落在 DBCS 前导区（如 `。` 的 0x82）会把换行符当尾字节吞掉、注释一路吞并下一行——生产实锤：`Set sh = CreateObject` 整行被吞进注释，计划任务每 2 分钟弹一次"缺少对象: 'sh'"错误框（test.sh 已有纯 ASCII 断言防复发）。
5. 刷新机制：宿主**事件驱动**（新助手消息/compact/权限切换，约 300ms 防抖）+ `refreshInterval: N`（秒）常驻定时器（空闲也每 N 秒重跑脚本）。**新触发会取消进行中的渲染**——N 必须显著大于最坏渲染耗时，否则帧帧被杀、整栏空白（重负载下实锤过）。settings.json 是**内容**监听热重载（touch 无效），渲染循环挂死时改任意值保存即免重启复活。忙碌回合主栏画面冻结但调用照常，回合结束回正。
6. 颜色一律基础 16 色 ANSI（30–37/90–97），bash ANSI-C quoting 常量（`GREEN=$'\e[32m'`），输出只用 `printf '%s\n'`（永不 `%b`）；每个着色 token 独立 reset。本文颜色记号：灰90、红31、绿32、黄33、蓝34、紫35、青36、白37、亮蓝94、亮紫95、亮青96、亮红91、亮白97。

## 1. 主状态栏（statusLine）

### 1.1 stdin JSON 契约（每次刷新一个对象，只列用到的字段）

```jsonc
{
  "session_id": "…",                       // 状态文件按它分会话
  "session_name": "…",                     // 可选
  "model":    { "display_name": "Fable 5" },
  "effort":   { "level": "max" },          // 可选 low|medium|high|xhigh|max
  "thinking": { "enabled": true },         // 可选
  "workspace": {
    "current_dir": "C:\\Users\\me\\proj",
    "repo": { "owner": "acme", "name": "webapp" }   // 可选
  },
  "worktree": { "name": "wt-fix", "branch": "main" }, // 仅 --worktree 会话
  "pr": { "number": 42, "review_state": "approved" }, // 可选
  "context_window": {
    "remaining_percentage": 65.8,          // 可能 null；官方口径为 input-only
    "total_input_tokens": 68471,
    "total_output_tokens": 1200,
    "context_window_size": 200000,
    "current_usage": {                     // 可能 null
      "input_tokens": 2000, "cache_creation_input_tokens": 3000,
      "cache_read_input_tokens": 60000
    }
  },
  "cost": { "total_cost_usd": 0.4231, "total_lines_added": 156, "total_lines_removed": 23 },
  "rate_limits": {                         // 两窗口各自独立可选
    "five_hour": { "used_percentage": 37.4, "resets_at": 1770000000 },
    "seven_day": { "used_percentage": 12.1, "resets_at": 1770500000 }
  }
}
```

**铁律**：任何字段都可能缺失或为 null；取值一律 `// ""` + 数值校验；缺数据的段整段消失，绝不显示 null、不留悬空分隔符。**必须是 `// ""` 而不是 `// empty`**：本项目的 jq 是「单次输出 N 个**定长位序**字段 + `__END__` 哨兵 + mapfile 按下标取用」（见硬性要求 0c(b)、§2.0(e)），而 `// empty` 对缺失/空值**根本不产行**——照 `// empty` 复刻会让字段整体上移、哨兵落不到 F[N]，形状校验每帧判负，于是任何带可选字段缺失的真实载荷都被永久渲染成 `HH:MM:SS | statusline: degraded (fork)` 一行；若复刻者又省了哨兵，则退化成 cost 被当成 tokens 那类静默串位。`// empty` 只适用于**单值**提取（例如从凭据文件里取 accessToken）。

### 1.2 输出：四行主题式布局

> **权威规格说明**：下面的分段表描述核心形态；每段的最终权威细节（含后续增量：today/week 跨会话统计、`wk` 按模型周配额、`extra` 溢出、压缩计数 `↻`、缓存倒计时、80% 压缩线 `│`、`·t` 节奏游标及其变色覆盖）以参考实现 `statusline-command.sh` **头部注释**为准——实现时先通读那份头注。

四行分组：**1 身份与位置**（时钟|模型|目录|worktree|仓库|分支|⚑stash|PR+CI）；**2 上下文引擎**（ctx 电池|走势+速率|cache 三件套|↻压缩）；**3 花费**（$+$/h|today|week|行数）；**4 限额与会话**（5h/7d 节奏游标|wk 模型配额|extra|»会话名）。每行独立拼装，段间分隔符为灰色 ` | `（前后 reset），行尾补一次 reset；**一行内无任何段时该行不打印**（第 1 行有时钟兜底恒在）。settings.json 的 statusLine 键配 `"refreshInterval": 10`（**负载优先**：渲染实测 ~0.3-0.5s，但多会话+代理编队的风暴期会拖长——10s 为取消规则留足余量并压低常驻进程流量；数据滞后≤10s 属接受的取舍）；**subagentStatusLine 配 refreshInterval 无效**（2.1.229 实测：配 3 仍精确 5.000s 一拍——面板节拍由宿主固定 ~5s 驱动，勿写该键）。

**第 1 行 · 身份与位置**
1. 时钟：`date +%H:%M:%S`，亮白。
2. 模型：**短 id 名**亮青（与面板同规则：剥 `claude-` 前缀与日期后缀、**保留** `[1m]` 容量标记；`.model.id` 缺失回退 display_name）+ 灰`·` + 档位热度色（low灰/medium绿/high黄/xhigh亮紫/max亮红/未知黄）+ 灰`·` + `think` 紫（仅 `.thinking.enabled == true`）。各部分独立可缺。
3. 目录：显示副本三步变换——主目录前缀（大小写不敏感，反斜杠/正斜杠都匹配）→`~`；`/`→`\`；组件数>3 折叠为 `首\…\倒数第二\末尾`。末级组件亮蓝，其余（含所有 `\` 和 `…`）蓝；单组件整体亮蓝。**git 命令必须用原始未变换路径**。
4. worktree：`.worktree.name` 存在才显示：灰`⎇ ` + 名称亮蓝 + （branch 存在时）灰`→` + 分支绿。
5. 仓库：owner 与 name 都存在才显示：owner青 + `/`灰 + name亮青。
6. 分支：与脏检测、stash 计数共用**同一次** `git -C "$dir" --no-optional-locks status --porcelain=v2 --branch --show-stash 2>/dev/null`：`# branch.head` 头行取名（无 upstream 修饰需剥；`(detached)`→空→整段消失；无提交仓库仍给名），首个非 `#` 开头行=脏（含未跟踪，追加独立黄`*`）——头行恒在实体行之前，见脏即 break，不遍历大脏树。名称恒绿。
6b. stash：`# stash N` 头行（git ≥2.35 且 N≥1 才输出）驱动：灰`⚑` + 数量（黄，≥5 亮红）；0/非仓库/旧 git 整段消失；与分支段刻意独立（detached 仍显示）。
7. PR：`.pr.number` 存在才显示：`PR#N` 紫；有 review_state 加空格+状态词（approved绿/changes_requested亮红/draft灰/其他黄）。

**第 2 行 · 上下文引擎**
8. 上下文电池：灰`ctx ` 标签起段。**主路径**（total_input_tokens 与 context_window_size 均为正数）：`occupied = total_input_tokens + total_output_tokens(数值时)`，`used=occupied*100/window` 夹 0–100，`remaining=100-used` 统一驱动一切——五格电池（实格数 `(remaining+10)/20` 夹 0–5，实格`█`、空格`░`灰）、档色（≥50绿/20–49黄/<20亮红且加亮红`!`前缀）、百分比数字；token 文本 `占用/窗口`，各数字独立格式化：<1000k 用 `(n+500)/1000` 取 k；≥1000k 用 M（`m10=(n+50000)/100000`，小数为零省略：`1M`、`1.5M`），白`294k`+灰`/1M`。**回退路径**（token 字段不可用但 remaining_percentage 非 null）：按百分比驱动电池，无 token 文本，显示值 `printf '%.0f'`，阈值判断用整数截断（floor）。
9. 走势+速率（一段，两半各自可选，空格连接）：走势=历史文件同会话行 token 列的相邻差值（负值夹 0，取最近 ≤9 行→≤8 个差值，≥2 个才显示），min..max 归一到 **6 级** `▁▂▃▄▅▆`（**封顶 ▆，刻意不用 ▇/█**——满高格会与相邻行叠字粘连；全等→全`▃`），**着色随速率档**（速率半段存在时与其同色，速率缺席回退青色）；速率=最新 token 值减 5 分钟窗口内最旧值 / 时距（需时距 ≥60s 且差值非负），≥1000/min 显示一位小数 k（整数算法 `delta*60/(span*100)` 得十倍值再拆），否则 `N/m`；档色 <5000灰/5000–14999黄/≥15000亮红。
10. 缓存命中：`.context_window.current_usage` 的 r=cache_read、w=cache_creation、i=input，denom=i+w+r>0 才显示：灰`cache ` + **一位小数** `N.M%`（整数算法 `r*1000/denom` 得十倍值再拆，如 `92.3%`）档色按整数部分 ≥80绿/50–79黄/<50亮红。

**第 3 行 · 花费（11-12）｜第 4 行 · 限额与会话（13-14）**（编号沿用历史序，不代表行号；第 3 行实为「花费 | today | week | 行数」，today/week 见硬性要求 0b 的日聚合规格）
11. 花费：`$` 不着色（终端默认色）+ 金额 `printf '%.2f'` 档色（整数部分 <1灰/1–4黄/≥5亮红）+ 空格 + `$X.X/h` 速率（历史文件 60 分钟窗口，纯 bash 分转换：整数部分*100+前两位小数，需时距 ≥120s 且差值非负，`cents*3600/span` 得每小时分数，按整美元档色同金额）。速率半独立可缺。
12. 行数：任一字段存在即显示（缺的按 0）：`+A`绿 `/`不着色 `-R`红。
13. 限额：两窗口独立可选，空格连接。每窗口：标签 `5h`/`7d` **青**（与动态百分比、白色重置时间三分）+ 百分比 `%.0f` 档色（floor 值 <50绿/50–79黄/≥80亮红；外层数值守卫 `^-?[0-9]{1,3}(\.[0-9]+)?$` + 0..100 夹取——垃圾/负值/巨数绝不渲染假读数）+ `resets_at` **归一化**后 `→时刻`白（5h 用 `%H:%M`，7d 用 `%m-%d`）：`^[0-9]{1,13}$` 位数帽防算术溢出、`>1e12` 视为毫秒除 1000（与 startTime 同法）、再过合理区间 `[now-1天, now+窗口+1天]`——出界则 `→时刻` 与 `·t` 游标半段一并消失，绝不渲染 1970 时钟或强制假红。
14. 会话名：`.session_name` 存在才显示：灰`» 名称`。

### 1.3 状态文件（走势/速率/花费速率的数据源）

**env 覆盖契约（测试隔离命脉——按本规格复刻必须原样实现，否则 `bash test.sh --assert` 会写真实 ~/.claude、真拿用户 OAuth token 发网络请求）**：`STATUSLINE_HISTORY_FILE`（细粒度历史）、`STATUSLINE_DAILY_FILE`（日聚合）、`STATUSLINE_SUBAGENT_TREND_FILE`（面板趋势）、`STATUSLINE_CI_CACHE_PREFIX`（CI 徽记缓存前缀，`.{owner}-{repo}-{pr}` 拼在其后）、`STATUSLINE_USAGE_CACHE_FILE` / `STATUSLINE_USAGE_BACKOFF_FILE`（wk/extra 缓存与退避）、`STATUSLINE_CRED_FILE`（OAuth 凭据路径）、`STATUSLINE_PANEL_DIR` / `STATUSLINE_PANEL_RENDERER` / `STATUSLINE_PANEL_DAEMON`（面板三件）、`STATUSLINE_TRANSCRIPT_TAIL_BYTES` / `STATUSLINE_CACHE_TTL_SECONDS` / `STATUSLINE_PANEL_RENDER_TIMEOUT`（行为旋钮）。全部形如 `${VAR:-默认}`。

`~/.claude/statusline-history.tsv`，**0x1F 分隔**行：`epoch␟session_id␟tokens␟cost`（读取端兼容旧 TAB 格式，见硬性要求 0b）（tokens 记**占用**=输入+输出，主路径不可用时记 input-only；缺值存空串）。每次调用：同会话最后一行不存在或 ≥30 秒旧才追加（采样步长，与 refreshInterval 配比：走势每格≈30 秒变化量，整图窗口 ~4.5 分钟）；写入**追加优先**：平时只做一次 O_APPEND 追加；仅当最老行超出保留窗（**90 分钟**，最宽消费者是 $/h 的 60 分钟窗）+30 分钟松弛、或行帽触顶时，才做一次全量裁剪重写（**带 `$$` 的临时文件**+原子 `mv`——固定 tmp 名会让多会话并发裁剪互撞丢行，已实锤）。所有读取按会话过滤、要求恰好 4 列 + 逐列数值校验，损坏/并发行静默跳过；全部文件操作 `2>/dev/null` 包裹，文件不可写绝不能影响其余段。细粒度行仅保 90 分钟，today/week 由日聚合文件驱动（见硬性要求 0b）。

## 2. 硬性要求（两个脚本通用）

0. **进程预算（Windows 生死线）**：MSYS2 上每次 fork ≈2–5ms，命令替换 `$(纯bash函数)` 也 fork——热路径出现几百次就是数秒卡顿。铁律：(a) 所有纯 bash 辅助函数用 **REPLY 返回模式**（`fn args; out=$REPLY`），调用点零命令替换；(b) 一切日期格式化用 `printf -v var '%(fmt)T' epoch`；(c) 文件读取用 `mapfile -t arr < file` / `read -r var < file`（无管道）；(d) TSV 拆列用 `IFS=$'\x1f' read -r -a`——**分隔符必须用 0x1F**，tab 属 IFS 空白类会折叠连续空字段导致整行串位；(e) 每次渲染的外部进程预算：jq×1 + git×1（+宽模式且有 transcript 时 tail+awk×1 管道、date≤1；低频路径——历史全量重写 ~30min 一次允许 find×1 清孤儿 tmp、日聚合持久化 ~300s 一次 mv×1（重放安全故可滞后落盘；折叠必与裁剪同帧先行，崩溃最多重放 300s 折叠、零丢失）、面板趋势态每采样帧 mv×1（它是跨进程记忆本体，不可滞后）、daemon 心跳 ~5s mv×1），后台任务必须完全脱离（重定向全关 + `&` + disown）。
0b. **历史文件双层**：细粒度 `~/.claude/statusline-history.tsv`（0x1F 4 列 `epoch␟session_id␟tokens␟cost`；读取端先 `${line//$'\t'/$'\x1f'}` 兼容旧 TAB；**整行形状校验**，恰好 4 列+逐列数值正则，否则整行丢弃——严禁部分字段泄入求和；按 **90 分钟**窗（最宽消费者是 $/h 的 60 分钟窗，多留 30 分钟松弛）+1 万行帽裁剪重写）只服务走势/速率/$每小时。today/week 走日聚合 `statusline-daily.tsv`（0x1F **7 列** `day␟sid␟closed␟peak␟prev␟last_epoch␟base`：单调段状态机增量前推 + **last_epoch 水位线** + **base=当日午夜基线**（会话累计 `.cost.total_cost_usd` 跨午夜**不清零**，而本表按「日×会话」建键：新一天首折必然以继承的整段累计播种，故当日贡献只能算 **closed+peak-base**（下夹 0），直接算 closed+peak 会让 week（跨两天求和）把午夜前的钱记两遍——实测真花 $5.10 渲染成 $10.10；跨界 `/clear` 使基线高于播种值时 base 回落 0。**聚合行同理**：settled 日折叠与 400 行溢出合并都必须先减 base 再累加，写出的 `_agg` 行也写满 7 列、base=0（它已是净额）——聚合侧漏减会让该天在 settle 的那一帧凭空跳涨，且细粒度行早已过期、再无重建路径；旧 6 列行读作 base=0 平滑迁移。**三条易踩空的细则**：(i) **base 列留空 = 当日基线尚未确立**，绝不可写成 0——无可解析成本的行只落水位线、此时并不知道基线，写 0 会在下一帧被读成「已知 0」，第一条真实成本行便以 0 播种，跨午夜双计原样复活（实测两帧后 .10 渲染成 0.10）；(ii) **全零行（closed=peak=prev 皆 0，即纯水位线行）不得参与「每会话最新累计」的推举**，否则它会以 0 覆盖昨天的真实基线（同一条双计的另一条进路）；/clear 后的行仍算证据（closed 列承载已闭合的段）；(iii) **未知基线 ≠ 0**：会话的 per-session 行可能已被 _agg 折叠（settled 日 / 400 行溢出 / 9 日裁剪三条路），它再回来时若按 base=0 播种，就把「继承的整段累计」当成今日花费，而那笔钱已经躺在 _agg 里——today/week 双计。无基线记录时的正解是「这一天只拥有它被观察到花掉的部分」，即 base=首次观测值；唯一允许 base=0 的是**整个日聚合文件为空**（首跑/全新安装，从存量细粒度行播种）那一种。）——重放不双计、并发丢写由细粒度行自愈、首跑自动从存量行播种同一代码路径；week=含今日的近 7 个自然日，文件留 9 日）。**两个文件的写入模型不同，勿混为一谈**：细粒度历史是**追加优先**——平时新行走单次 O_APPEND 追加（并发天然安全），仅当最老行超出读窗 30 分钟（90min+30min 松弛）、头部 20 行探测不到任何可用 epoch（时钟前跳后又回校的自锁态）、或行帽触顶时才全量裁剪重写（`$$` 临时名+原子 mv）——稳态下约每 30 分钟才重写一次，而非旧的每次追加都重写；**畸形行不触发重写**（读端本就整行丢弃，等那趟周期性重写顺带清掉即可，否则每帧都会被一行脏数据拖去重写）。日聚合文件**从不追加**：它是整表状态、只有 mapfile 读 + 整表 tmp+mv 重写，节流为「内存水位线比盘上新 ≥300s 才落盘」（与 §2.0(e) 的「日聚合持久化 ~300s 一次 mv×1」是同一件事）——**按 O_APPEND 复刻会给同一 (day,sid) 写出多行**，加载端 last-wins 看着能跑，但 400 行溢出合并是逐行累加，重复行会被重复计入 `_agg`，today/week 永久通胀。
0c. **抗资源枯竭·永不白屏三件套**（Windows 大进程树下 fork 枯竭真实存在——bash 报 `fork: retry: Resource temporarily unavailable`、子进程 0xC0000142——届时 jq spawn 会失败）：(a) **stderr 黑匣子**：`export LC_ALL` 后立即 `exec 2>>~/.claude/statusline-err.log`（黑匣子有界：主脚本把轮转挂在 ~30 分钟一次的历史重写路径上，用一次 `find -size +64k` 判定后截断——**不可放在每帧路径**，按行数每帧重读日志在风暴残留后是 ~100ms/帧的常驻税；面板 daemon 常驻，其轮转在启动时跑一次即可），任何 stderr 泄给宿主都会整栏白屏，黑匣子既保白屏防线又留尸检证据；(b) **哨兵形状校验**：单次 jq 输出 N 个字段后**必须再追加一个字面量哨兵字段 `("__END__")`**——裸行数检查不可靠，因为 `$(...)` 命令替换会剥掉**全部**尾随换行，末字段（如 transcript_path）为空时 jq 输出以连续换行结尾、被整体剥除，健康载荷凭空少行而误判（真机踩过：无 transcript_path 的载荷 100% 误触发假降级）；哨兵永不为空、必幸存剥除，检查 `[ "${#F[@]}" -lt N+1 ] || [ "${F[N]}" != "__END__" ]` 才可靠；(c) **降级行**：形状校验失败时输出一行 `HH:MM:SS | statusline: degraded (fork)`（`printf '%(%H:%M:%S)T' -1`，零进程）并 `exit 0`——绝不空输出、绝不非零退出。

0d. **语句预算**：MSYS 下 bash 每条语句 ~20-40μs（解释器本身的价格，与语句内容几乎无关）——热路径"每行 × 每帧"的循环体语句数就是毫秒账。**禁止任何随历史/日志增长的每帧重扫**：跨帧记忆一律用规模有界的紧凑状态文件承载（日聚合按天×会话、趋势态按活跃任务，皆此模式）。同一状态文件**每帧只许走一遍**（第一轮对抗审查实锤：历史文件曾被两个近同构循环各扫一遍，1260 行 3 会话稳态白付 ~0.3-0.7s/帧——现为单循环同时喂走势数组/裁剪集/日聚合折叠/节流纪元）。**`mapfile <<< 大块` 按字节计价 ~3.5μs/B**（512KiB≈1.8s，换临时文件同样慢——拆行本身就是 O(bytes)，"逐行扫描只按行数计价"的成本模型是错的）：大块文本一律在管道里先经 awk/grep 预滤成小结果再拆行（transcript 尾窗模式），或先有界切片（`${blob:0:2048}`）再用参数展开逐行走（git porcelain 头部模式）。
1. 无浮点：比较一律"截断小数→整数比"（非负数等价 floor）；显示另行 printf。
2. printf/算术前必须 `[ -n ]` + `[[ =~ ^[0-9]+$ ]]` 守卫。
3. 先判段非空再包颜色，禁止"只有颜色码的空段"进入拼装。
4. git 全部 `--no-optional-locks` + stderr 静默；目录非法时整段静默消失。
5. stdin 零 fork **分块**读入：`input=""; while IFS= read -r -N 65536 c; do input+="$c"; done; input+="$c"`。**禁 `read -d ''` 单次读**（管道上逐字节 read，实测 100KB 慢 5 倍——面板载荷带 tokenSamples 会放大）、**禁 `$(cat)`**（子壳+cat 两个进程）；`-N` 按字符计数不会撕裂多字节。jq 用 herestring 喂入 `jq -r '…' <<< "$input"`（免 printf 管道的子壳 fork；不用 echo）。settings 命令写成 `exec bash ~/.claude/…`，省掉宿主 `-c` 壳那层进程。
6. **逐行读 jq/awk 输出必须 `| tr -d '\r'`**（见前置检查 4）。
7. 两脚本 shebang 后第一句 `export LC_ALL=C.UTF-8`——所有 `${#}` 长度、`${var:0:N}` 切片、正则类按**字符**而非字节算，对齐才成立。
8. **列对齐**：每段维护无转义纯文本孪生串（颜色与 OSC 8 序列不计宽）。主状态栏**四行**按列索引取最大宽度补 NBSP 成网格（每行最后一格不垫）；子代理面板两遍法——第一遍算出所有行**至多 6 个**定位列（含独立模型列，显示序 0,5,1,2,3,4）的内容与宽度并取列最大值，**全空列整列裁掉**，第二遍只按活跃列统一垫宽后输出（缺中间活跃列的行垫空占位，尾部缺列丢弃；描述列共用统一预算 = `columns − 活跃列最大宽之和 − 3×活跃列数`——只计活跃列，每列摊 3 格分隔符）。宽度一律经 disp_width 按**真实终端格数**测量（东亚宽字符=2 格），精确对齐而非近似。
9. **OSC 8 超链接**（`\e]8;;URL\e\\文本\e]8;;\e\\`，零宽、不计入纯文本宽度）：PR 段的 `PR#N` 链到 `.pr.url`；仓库段整体链到 `https://<.workspace.repo.host // "github.com">/<owner>/<name>`；URL 含空白或 ESC 时放弃链接回退纯文本。

## 3. 安装

**一行命令**：`curl -fsSL https://raw.githubusercontent.com/googxi1310328414-afk/claude-code-statusline/main/install.sh | bash`（幂等；本地 clone 内离线；settings 合并式带备份；冒烟自检；`--with-watchdog` 注册自愈层）。等价手动步骤：四脚本（两渲染 + 面板钩子/daemon）写入 `~/.claude/` 并建目录 `~/.claude/statusline-panel.d/`；`~/.claude/settings.json` **合并**（勿覆盖其他键）：

```json
{
  "statusLine":         { "type": "command", "command": "exec bash ~/.claude/statusline-command.sh", "refreshInterval": 10 },
  "subagentStatusLine": { "type": "command", "command": "exec bash ~/.claude/statusline-panel-hook.sh" }
}
```

保存即生效，无需重启。

## 4. 子代理面板行（subagentStatusLine）

**常驻 daemon 架构（必须）**：宿主重画面板时先出默认行、钩子返回才替换——钩子延迟即"闪回默认"窗口。因此 subagentStatusLine 命令指向轻钩子 `statusline-panel-hook.sh`（纯内建：分块读 stdin → 按**载荷首任务 id** 派生缓存键 → spool 单次直写交接（刻意非原子：newest-wins 有损语义，撕裂帧由 -s 门+坏帧连击兜底） `spool.<key>.new` → mapfile 秒回 `cache.<key>`（首行=渲染纪元，钩子按龄 60s 拒供） 上一帧 → `kill -0` 探测 daemon、死则游离拉起），渲染由 `statusline-panel-daemon.sh` 异步跑真渲染脚本完成（单实例 noclobber 抢占；**pid 文件为四行协议**（规格见下一段）——daemon 以**墙钟 5 秒**节奏原子刷新第二行（主循环与渲染等待循环双检查点，任何路径都饿不死心跳；严禁按循环轮数计拍——轮长无上界，挂死渲染曾把拍距拉到 ~230s 致活 daemon 被误判死、替身叠加）；**判活=数字 pid + kill -0 + 心跳 60s 内**，钩子探活与接管判定同一判据（install 回收**不看心跳**：卡死实例的心跳必然陈旧，按心跳新鲜才杀恰好把最该回收的那个排除在外——它改为身份确认后无条件回收注册者）（裸 kill -0 会被系统回收给无关进程的残留 pid 永久欺骗——钩子永不拉起、面板死锁；install 裸 kill 更会误杀无辜进程）；缺/旧心跳一律判死；**陈旧接管=删除+独占重建、绝不裸 `>` 覆写**（截断窗会让并发读者误判无主）；**退出删除 pid 文件前必须校验内容==$$**（否则先退的一方会删掉存活实例的注册、级联拉起第三实例）；0.3s fifo `read -t` 零派生轮询；无活 2 分钟自灭；**绝对寿命闸**（默认 1h，`STATUSLINE_PANEL_DAEMON_MAX_LIFE`）；`--once` 供测试）。
**pid 文件为四行协议**：`cygwin_pid ␤ 心跳epoch ␤ windows_pid ␤ 在途渲染子进程pid`——第 3 行取自 `/proc/self/winpid`，是给 PowerShell 看门狗用的**精确身份**（cygwin pid 对它毫无意义）；第 4 行是 daemon 当前在途的渲染子进程（空闲时为空行，随 5 秒心跳一起刷新），**它无法从外部推导**：daemon 是钩子用 `( bash … & )` 在无作业控制的脚本里派生的，继承钩子的 PGID、自己不是组长，`kill -- "-$daemon_pid"` 打到的是一个根本不存在的进程组（ESRCH 空转，且若该 pid 恰好撞上某个遗留 PGID 就会误伤一整组无关进程）；而渲染子进程是在 `set -m` 下起的、自成一组，凭第 4 行可以连它的 jq 一起精确收掉。卡死的 daemon 通常正是**因为**渲染子进程卡住，只杀 daemon 会把它变成常驻孤儿（还占着 tmp 名）——daemon 自己在「让位退出」路径上也必须先收掉它再 exit。回收 daemon **绝不可**按「命令行提及脚本名」匹配：任何谈到该文件名的外壳（诊断命令、测试脚本、AI 代理自己的 bash）命令行同样以它结尾，实测会 -Force 杀掉无关进程、甚至因「保留最新启动者」而杀掉真正注册且心跳新鲜的 daemon（2026-08-14 第 10 轮实锤，与 2026-08-13 的误杀事故同型）。正解：钩子按 `/proc/<pid>/cmdline` 尾部精确确认后才杀；看门狗只在「注册者心跳 >180s 陈旧」时按第 3 行的 Windows pid 精确回收并二次确认进程身份；install 只回收 pid 文件里注册的那一个。未注册的孤儿交给寿命闸自然退出。
**bash 前缀剥离是二次方**（`${var#*pat}` 会从每个位置重扫）：钩子取缓存键、主脚本取 timestamp 都踩过，实测 80KB 载荷 13.6-13.8s。凡在大字符串上定位子串，一律先有界切片（`${s:0:4096}`）或交给 awk 一次线性扫描。
**血的教训**：2026-08-14 曾因「钩子判死后只拉新不杀旧」累积 **78 个孤儿 daemon、烧掉 22.3 CPU 小时**；且 **cygwin 的 `ps` 看不到全部实例**（ps 显示 0 而 Windows 进程表显示 3），排查与回收都必须走 Windows 进程表。
**同一事故第二次（2026-08-15，第 13 轮现场）：38 个孤儿 daemon、3.03 CPU 小时**（8 核吃掉 4.5 核），而「先回收再拉起」那道闸当时已经在了——它失效是因为**身份确认自己要 fork**：`_cmd=$(tr '\0' ' ' < /proc/<pid>/cmdline)` 是命令替换，而这条路径存在的唯一理由就是 fork 枯竭；fork 一失败捕获即为空、模式不匹配、于是**什么都不杀却照样拉新**，每 ~65 秒净增一个永不退出的实例。**铁律：一切在故障路径上的身份/状态读取必须零派生**——cmdline 是 NUL 分隔的，用 `while IFS= read -r -d '' arg` 纯内建读，判据取**最后一个 argv 元素**并排除任何含裸 `-c` 的外壳（空格拼接的旧写法还有另一个洞：`bash -c '… # statusline-panel-daemon.sh'` 拼出来的串同样以脚本名结尾，会被尾部匹配误杀）。另加兜底：看门狗回收「不在注册中且活过寿命闸两倍（2h）」的 daemon——未注册的卡死实例是四条回收路径全都够不着的唯一盲区（寿命闸要求循环还在转）。**渲染子进程必须带硬超时**（后台启动+fifo 节拍计数等待，默认 15s，`STATUSLINE_PANEL_RENDER_TIMEOUT` 覆盖；超时杀子进程跳帧，缓存继续供上一好帧）——同步无超时等待曾是全会话面板永久冻结的单点（子进程挂死→daemon 阻塞→`kill -0` 探活恒真→永不重启，默认安装无恢复路径）；每次渲染的 cache tmp 名带自增序号（MSYS/NTFS 上被杀子进程的 tmp 名会短暂处于 delete-pending、不可复用）。并发会话任务集不相交→缓存键天然隔离；一切竞争丢失都由下一拍自愈。状态目录 `$STATUSLINE_PANEL_DIR`（默认 `~/.claude/statusline-panel.d/`），renderer/daemon 路径可用 `STATUSLINE_PANEL_RENDERER`/`STATUSLINE_PANEL_DAEMON` 覆盖（测试用）。

### 4.1 契约（与主状态栏不同！）

每次刷新 stdin 收到**一个**JSON：`{"columns": <可用宽度>, "tasks": [<每个子代理一个对象>]}`。实测：只有常规 Agent 子代理（type=`local_agent`，身份在 `label` 字段、通常无 `name`）会出现；workflow/ultracode 编队渲染在 /workflows 专属 UI，不经过此钩子。任务字段：`id`、`name`、`type`、`status`、`description`、`label`、`startTime`（Unix 时间戳，**可能是毫秒**：>10^12 则除以 1000）、`tokenCount`（**累计消耗**，可远超窗口！）、`model`、`contextWindowSize`（≥2.1.205）、`effort`（≥2.1.214，缺席=继承主会话）、`tokenSamples`（结构未文档化）。对 `.tasks[]` 每个元素向 stdout 输出一行紧凑 JSON `{"id":…,"content":…}`（`jq -cn --arg` 构造）；无 `id` 跳过（保持默认渲染）；tasks 空则无输出。

### 4.2 行规格（7 段含独立模型列，同款分隔符/守卫）

1. 身份：灰`▸ ` + name/label/type 三选一、**分色**（pending|queued|starting **黄33** / completed|done|finished **绿32** / failed|error|cancelled|killed **亮红91** / **其余（含 running，即绝大多数时间）按 task id 稳定哈希在 96/94/95/36/34/97 六色相里取一个**——固定色会让整块面板读成一片同色，哈希色让并发代理一眼分得开，且同一代理终生同色；哈希用 `(h*31+ord)%100003` 走完整 id，前缀截断求和会聚簇（实测两个活代理撞同色）；调色板刻意排除绿/黄/亮红，那三色专属状态语义）——身份是行内最宽最靠左的字段，让它承载状态，一眼扫左边缘即知全队状况；与末尾的状态图标形成「形状+颜色」双编码 + 灰`(type)`（type 非空且≠身份文本时）+ 灰`·`+热度色 effort（仅显式存在时；数字型预算值用黄）+ 空格+状态图标：`●`运行绿32 / `○`pending|queued|starting 黄 / `✗`failed|error|cancelled|killed 亮红 / `✓`completed|done|finished **绿**（不是灰——灰在深色主题上如同无色）/ `?`未知黄。
1b. 模型独立列：青短名**恒显**（剥 `claude-` 前缀与 `-20`+6位日期后缀，尾部 `[1m]` 类容量标记**保留原样**——用户审美），紧随身份列之后（实现上用列索引 5 挂进显示序 `0,5,1,2,3,4`，免既有列重编号）；全面板无模型时整列被活跃列裁剪掉。majority_model 仍由 jq 产出以保 JL 标量位序，但完全不再用于显示。
2. 消耗：tokenCount 为数值即显示白`Nk` + 灰` tok`（**累计消耗**，不读 contextWindowSize、不做任何占用/百分比近似——tokenCount 是累计口径，画电池必然失真，用户明确宁精勿滥）。
3. 走势+速率（一段，与主行第 9 段同构）：走势**主源**=脚本自建 10s 采样——**紧凑趋势态文件** `~/.claude/statusline-subagent-trend.tsv`（可用 `STATUSLINE_SUBAGENT_TREND_FILE` 覆盖），**每任务一行** `task_id␟last_epoch␟末≤9个累计值csv`：每任务 ≥10s 推进一样（csv 尾追加、逗号计数裁到末 9），读写规模=活跃任务数、**永不随采样历史增长**（前一版"每样本一行追加日志"每帧重扫数百行——MSYS 下 bash 每条语句 ~20-40μs，实测吃掉面板大半帧预算，见硬性要求 0d）；≥30 分钟无更新的死任务行下次重写清除；`$$` 临时名原子重写、多会话读合并写、丢写自愈。**每格≈10s**；<2 个值时回退 tokenSamples 防御式解析（数字直接用；对象试 `.tokens//.tokenCount//.count//.value//.v`；<2 个数或解析失败→静默省略，取末 8 个）。两种源同走：非递减序列先转相邻差值，归一到 ▁-▆ 六档（封顶防行间粘连），着色随速率档、无速率回退青；速率=`tokenCount*60/(elapsed*100)` 十倍值（elapsed ≥60s 才显示），档色同主行。
4. 份额：预扫描全 tasks 的 tokenCount 总和；有 token 的任务 ≥2 个才显示：灰`Σ` + `N%`（本行/总量，<50灰/50–74黄/≥75亮红）。
5. 用时（**按时长分档**：<2min 灰90 / <10min 白37 / <30min 黄33 / ≥30min 亮红91——长跑代理值得一眼看见）：秒级——`<60s`→`42s`、`<1h`→`5m12s`、否则`1h23m45s`，白；+灰`@HH:MM:SS`（启动时刻）。
6. 描述：灰，宽度预算与 §2.8 同一权威公式：`columns（缺省 120）− 活跃列最大宽之和 − 3×活跃列数`（全面板统一，非按行；模型列活跃时即 6 列）；预算 <8 省略，超长按累计显示格数截到预算−1 格+`…`。

## 5. 验证（必须实际执行）

**首选**：仓库根目录 `bash test.sh --assert` —— 133 项断言（四行结构、各新段存在性、stash 段显隐、子代理 10s 采样、双层花费存储、追加优先裁剪触发、面板钩子 spool/缓存秒回/daemon 渲染、安装器本地模式/合并/幂等、**NBSP 分隔符列对齐（含断言活性自证——分隔符样式再变会红而不是断言静默失效）**、TSV 列序、空列裁剪、性能 <3s 门槛，及**对抗审查回归组**：@tsv 反斜杠单次反解码、C0 清洗不串位不坏 JSON、session_name 内嵌换行不降级、ctx 回退负值夹取/垃圾整段消失、主目录兄弟目录边界、daemon 挂死子进程超时截杀、时钟回拨不冻结采样、~500KiB transcript <2.5s 性能门、看门狗 vbs 纯 ASCII，及第 2/3 轮回归组：垃圾限额段消失、OSC 注入剥除、未来日 rollup 不虚增、空 dir 无 git 段、数字 id 无键、空渲染保帧、usage 失败负缓存且测试不碰真实 ~/.claude、坏帧连击清缓存诚实降级、陈旧心跳接管驱逐、毫秒 resets_at 半段消失；以及第 13 轮回归组：settled 日折叠与 400 行溢出合并均减午夜基线且 `_agg` 写满 7 列、溢出合并按位读 last_epoch（3h 内活行不被并走）、跨午夜会话 today 段不消失、daemon 将在途渲染子进程发布在 pid 第 4 行且钩子精确回收它），全 PASS 即基本达标；以下手工清单用于断言未覆盖的细节。

主状态栏（`fixtures/` 三份 + 状态文件人工历史；以下期望串均为隔离环境实测）：
- **full.json**：**四行**齐全；电池 `ctx ███░│ 66% 70k/200k`（**末格恒为 80% 压缩线 `│`**，仅满电 5 格时才无标记；占用 69671=68471+1200→70k，非 68k！）；`cache 92.3%` 绿（一位小数）；第 4 行 `5h …·t…% 7d …` + `wk` + `» my-session`。
- 把 window 改 1000000：token 文本变 `70k/1M`。
- **low-context.json**：`!█░░░│ 12% 176k/200k` 亮红（同样末格 `│`）；`$1.07` 黄；`5h` 青标签+`82%`亮红；`7d 45%` 绿。**注意 `→重置时刻` 与 `·t` 游标半段不会出现**：两个夹具的 `resets_at` 是硬编码的 1770000000/1770500000（2026-02-02），早已落在 §1.2 第 13 条自己规定的合理区间 [now-1天, now+窗口+1天] 之外，按规格两个半段就该整段消失——这正是区间闸在起作用，**不是 bug，更不要为了让它出现而拆掉区间闸**（那等于把 1970 时钟一类回归放回来）。要手工看重置时刻，照 test.sh 的做法现场把 `resets_at` 注入成 `now+7200` / `now+259200`。同理 `wk` 段需要 usage 缓存，隔离环境下不会出现。
- **minimal.json**：第 2 行消失（新会话无历史时），无悬空分隔符。
- 人工写 3 行同会话历史（epoch 递增、token 递增）再跑：出现青色走势+速率；花费速率 `$X.X/h`。
- 干净/脏 git 仓库两态：绿 `main` / 绿 `main`+黄`*`。

子代理行（`fixtures/subagent-tasks.json`，4 任务应输出 3 行有效 JSON；期望串为实测——夹具任务**均无 startTime**，故用时列与速率半段不可能出现）：
- t1：`▸ code-reviewer(general)·max ●`（身份色=按 id 哈希取的运行中色相，本夹具实测为**青 36**——不是固定紫；/灰/亮红/绿）、独立模型列 `fable-5` 青、`68k tok`、走势 `▃▆▁▁`（6 级封顶 ▆，无速率半段）、`Σ25%`、描述截断带 `…`。
- t2：`▸ researcher ✓`（`✓` **绿**）、`12k tok`、`Σ4%`；走势列为该行空占位（<2 样本）。
- t3：label 兜底 `verify:auth` + `·50000` 黄（数字预算 effort）+ `✗` 亮红；独立模型列 `haiku-4-5` 青；`185k tok`；对象形态 tokenSamples 走势 `▆▁▃`；`Σ69%`。
- 无 id 任务不产生输出行。
- **对齐**：多行输出剥掉全部转义后，所有 `NBSP|NBSP` 分隔符逐列竖向对齐（disp_width 真格数计宽，含 CJK 也精确对齐）；主状态栏四行同理。
- **链接**：full.json 渲染输出中 `\e]8;;` 出现 4 次（仓库、PR 各一对开闭）。

边界清单：remaining null、pr 无状态、单窗口限额、effort/thinking/repo/session_name 全缺、路径 3 层不折叠/4 层折叠、主目录=`~`、历史文件损坏行/不可写、tokenSamples 乱结构、startTime 毫秒与秒、19.6% 显示 20% 仍触发红档、stash 0/非仓库/git<2.35 隐藏而 detached 仍显示（≥5 亮红）。
