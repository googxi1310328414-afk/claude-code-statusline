# AI 复刻指导：Claude Code 三行彩色状态栏 + 子代理面板行

> **用法**：把本文件全文发给 Claude Code（或任何能读写文件、执行 shell 的 AI agent），说"按这份指导配置状态栏"。本文是完整规格：数据契约、每段的格式/颜色/阈值、状态文件、健壮性要求、安装与验证。仓库根目录有参考实现（`statusline-command.sh`、`subagent-statusline.sh`），但你（AI）应按规格在目标机器上适配重建，而不是盲目复制。

## 0. 前置检查

1. 环境：bash ≥ 4（Windows 用 Git Bash），`jq`、`git` 可用；`locale charmap` 应为 UTF-8（否则多字节字符宽度计数会提前截断）。
2. 确认目标机器**主目录**，目录缩写逻辑用它，不要硬编码别人的路径。
3. `date -d "@epoch"` 是 GNU 语法（Git Bash/Linux）；macOS/BSD 用 `date -r epoch`。
4. **Windows 陷阱**：Windows 版 jq 输出 CRLF。`$(...)` 命令替换在 MSYS bash 会剥掉尾部 `\r`，**但 `mapfile`/`read` 逐行读不会**——凡逐行读 jq 输出，必须管过 `tr -d '\r'`，否则数值校验全部静默失败。
5. 刷新机制：状态栏是**事件驱动**（会话状态变化时重跑脚本，约 300ms 防抖），无定时器。秒级时钟空闲时不走、"实时"效果只在模型活动期间成立——这是宿主行为，提前告知用户。
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

**铁律**：任何字段都可能缺失或为 null；取值一律 `// empty` + 数值校验；缺数据的段整段消失，绝不显示 null、不留悬空分隔符。

### 1.2 输出：三行主题式布局

每行独立拼装，段间分隔符为灰色 ` | `（前后 reset），行尾补一次 reset；**一行内无任何段时该行不打印**（第 1 行有时钟兜底恒在）。

**第 1 行 · 身份与位置**
1. 时钟：`date +%H:%M:%S`，亮白。
2. 模型：名称亮青 + 灰`·` + 档位热度色（low灰/medium绿/high黄/xhigh亮紫/max亮红/未知黄）+ 灰`·` + `think` 紫（仅 `.thinking.enabled == true`）。各部分独立可缺。
3. 目录：显示副本三步变换——主目录前缀（大小写不敏感，反斜杠/正斜杠都匹配）→`~`；`/`→`\`；组件数>3 折叠为 `首\…\倒数第二\末尾`。末级组件亮蓝，其余（含所有 `\` 和 `…`）蓝；单组件整体亮蓝。**git 命令必须用原始未变换路径**。
4. worktree：`.worktree.name` 存在才显示：灰`⎇ ` + 名称亮蓝 + （branch 存在时）灰`→` + 分支绿。
5. 仓库：owner 与 name 都存在才显示：owner青 + `/`灰 + name亮青。
6. 分支：`git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null` 非空才显示，名称恒绿；脏检测（`status --porcelain | head -c1` 非空）追加独立黄`*`。
7. PR：`.pr.number` 存在才显示：`PR#N` 紫；有 review_state 加空格+状态词（approved绿/changes_requested亮红/draft灰/其他黄）。

**第 2 行 · 上下文引擎**
8. 上下文电池：灰`ctx ` 标签起段。**主路径**（total_input_tokens 与 context_window_size 均为正数）：`occupied = total_input_tokens + total_output_tokens(数值时)`，`used=occupied*100/window` 夹 0–100，`remaining=100-used` 统一驱动一切——五格电池（实格数 `(remaining+10)/20` 夹 0–5，实格`█`、空格`░`灰）、档色（≥50绿/20–49黄/<20亮红且加亮红`!`前缀）、百分比数字；token 文本 `占用/窗口`，各数字独立格式化：<1000k 用 `(n+500)/1000` 取 k；≥1000k 用 M（`m10=(n+50000)/100000`，小数为零省略：`1M`、`1.5M`），白`294k`+灰`/1M`。**回退路径**（token 字段不可用但 remaining_percentage 非 null）：按百分比驱动电池，无 token 文本，显示值 `printf '%.0f'`，阈值判断用整数截断（floor）。
9. 走势+速率（一段，两半各自可选，空格连接）：走势=历史文件同会话行 token 列的相邻差值（负值夹 0，取最近 ≤9 行→≤8 个差值，≥2 个才显示），min..max 归一到 `▁▂▃▄▅▆▇█`（全等→全`▄`），青色；速率=最新 token 值减 5 分钟窗口内最旧值 / 时距（需时距 ≥60s 且差值非负），≥1000/min 显示一位小数 k（整数算法 `delta*60/(span*100)` 得十倍值再拆），否则 `N/m`；档色 <5000灰/5000–14999黄/≥15000亮红。
10. 缓存命中：`.context_window.current_usage` 的 r=cache_read、w=cache_creation、i=input，denom=i+w+r>0 才显示：灰`cache ` + `N%`（r*100/denom）档色 ≥80绿/50–79黄/<50亮红。

**第 3 行 · 开销与限额**
11. 花费：`$` 不着色（终端默认色）+ 金额 `printf '%.2f'` 档色（整数部分 <1灰/1–4黄/≥5亮红）+ 空格 + `$X.X/h` 速率（历史文件 60 分钟窗口，纯 bash 分转换：整数部分*100+前两位小数，需时距 ≥120s 且差值非负，`cents*3600/span` 得每小时分数，按整美元档色同金额）。速率半独立可缺。
12. 行数：任一字段存在即显示（缺的按 0）：`+A`绿 `/`不着色 `-R`红。
13. 限额：两窗口独立可选，空格连接。每窗口：标签 `5h`/`7d` **青**（与动态百分比、白色重置时间三分）+ 百分比 `%.0f` 档色（floor 值 <50绿/50–79黄/≥80亮红）+ `resets_at` 过 `^[0-9]+$` 校验后 `→时刻`白（5h 用 `%H:%M`，7d 用 `%m-%d`）。
14. 会话名：`.session_name` 存在才显示：灰`» 名称`。

### 1.3 状态文件（走势/速率/花费速率的数据源）

`~/.claude/statusline-history.tsv`，TSV 行：`epoch<TAB>session_id<TAB>tokens<TAB>cost`（tokens 记**占用**=输入+输出，主路径不可用时记 input-only；缺值存空串）。每次调用：同会话最后一行不存在或 ≥5 秒旧才追加；追加后 `tail -n 200` 到临时文件再 `mv` 截断。所有读取按会话过滤、要求恰好 4 列 + 逐列数值校验，损坏/并发行静默跳过；全部文件操作 `2>/dev/null` 包裹，文件不可写绝不能影响其余段。

## 2. 硬性要求（两个脚本通用）

1. 无浮点：比较一律"截断小数→整数比"（非负数等价 floor）；显示另行 printf。
2. printf/算术前必须 `[ -n ]` + `[[ =~ ^[0-9]+$ ]]` 守卫。
3. 先判段非空再包颜色，禁止"只有颜色码的空段"进入拼装。
4. git 全部 `--no-optional-locks` + stderr 静默；目录非法时整段静默消失。
5. stdin 只读一次进变量，jq 取值用 `printf '%s' "$input" | jq -r`（不用 echo）。
6. **逐行读 jq/awk 输出必须 `| tr -d '\r'`**（见前置检查 4）。
7. 两脚本 shebang 后第一句 `export LC_ALL=C.UTF-8`——所有 `${#}` 长度、`${var:0:N}` 切片、正则类按**字符**而非字节算，对齐才成立。
8. **列对齐**：每段维护无转义纯文本孪生串（颜色与 OSC 8 序列不计宽）。主状态栏三行按列索引取最大宽度补空格成网格（每行最后一格不垫）；子代理面板两遍法——第一遍算出所有行 5 个定位列的内容与宽度并取列最大值，第二遍统一垫宽后输出（缺中间列的行垫空格占位，尾部缺列丢弃；描述列共用统一预算 = columns − 各列最大宽及分隔符 − 15）。CJK 字符占两格的近似误差如实文档化。
9. **OSC 8 超链接**（`\e]8;;URL\e\\文本\e]8;;\e\\`，零宽、不计入纯文本宽度）：PR 段的 `PR#N` 链到 `.pr.url`；仓库段整体链到 `https://<.workspace.repo.host // "github.com">/<owner>/<name>`；URL 含空白或 ESC 时放弃链接回退纯文本。

## 3. 安装

两脚本写入 `~/.claude/`；`~/.claude/settings.json` **合并**（勿覆盖其他键）：

```json
{
  "statusLine":         { "type": "command", "command": "bash ~/.claude/statusline-command.sh" },
  "subagentStatusLine": { "type": "command", "command": "bash ~/.claude/subagent-statusline.sh" }
}
```

保存即生效，无需重启。

## 4. 子代理面板行（subagentStatusLine）

### 4.1 契约（与主状态栏不同！）

每次刷新 stdin 收到**一个**JSON：`{"columns": <可用宽度>, "tasks": [<每个子代理一个对象>]}`。实测：只有常规 Agent 子代理（type=`local_agent`，身份在 `label` 字段、通常无 `name`）会出现；workflow/ultracode 编队渲染在 /workflows 专属 UI，不经过此钩子。任务字段：`id`、`name`、`type`、`status`、`description`、`label`、`startTime`（Unix 时间戳，**可能是毫秒**：>10^12 则除以 1000）、`tokenCount`（**累计消耗**，可远超窗口！）、`model`、`contextWindowSize`（≥2.1.205）、`effort`（≥2.1.214，缺席=继承主会话）、`tokenSamples`（结构未文档化）。对 `.tasks[]` 每个元素向 stdout 输出一行紧凑 JSON `{"id":…,"content":…}`（`jq -cn --arg` 构造）；无 `id` 跳过（保持默认渲染）；tasks 空则无输出。

### 4.2 行规格（6 段，同款分隔符/守卫）

1. 身份：灰`▸ ` + name/label/type 三选一**亮紫**（区别于主行的亮青）+ 灰`(type)`（type 非空且≠身份文本时）+ 灰`·`+青·短模型名（**仅当该行模型 ≠ 面板多数模型**；短名=剥 `claude-` 前缀和 `-20`+6位日期后缀，预扫描 `group_by` 求多数）+ 灰`·`+热度色 effort（仅显式存在时；数字型预算值用黄）+ 空格+状态图标：`●`运行绿32 / `○`pending|queued|starting 黄 / `✗`failed|error|cancelled|killed 亮红 / `✓`completed|done|finished **绿**（不是灰——灰在深色主题上如同无色）/ `?`未知黄。
2. 消耗：tokenCount 为数值即显示白`Nk` + 灰` tok`（**累计消耗**，不读 contextWindowSize、不做任何占用/百分比近似——tokenCount 是累计口径，画电池必然失真，用户明确宁精勿滥）。
3. 走势+速率（一段，与主行第 9 段同构）：走势=tokenSamples 防御式解析（数字直接用；对象试 `.tokens//.tokenCount//.count//.value//.v`；<2 个数或解析失败→静默省略），取末 8 个，非递减序列先转相邻差值，归一到 8 档青色；速率=`tokenCount*60/(elapsed*100)` 十倍值（elapsed ≥60s 才显示），档色同主行。
4. 份额：预扫描全 tasks 的 tokenCount 总和；有 token 的任务 ≥2 个才显示：灰`Σ` + `N%`（本行/总量，<50灰/50–74黄/≥75亮红）。
5. 用时：秒级——`<60s`→`42s`、`<1h`→`5m12s`、否则`1h23m45s`，白；+灰`@HH:MM:SS`（启动时刻）。
6. 描述：灰，宽度预算 = columns（缺省 120）−前五段纯文本长度（含 `▸ ` 与分隔符）−3；预算 <8 省略，超长截到预算−1 字符+`…`。

## 5. 验证（必须实际执行）

主状态栏（`fixtures/` 三份 + 状态文件人工历史）：
- **full.json**：三行齐全；电池 `ctx ███░░ 66% 70k/200k`（占用 69671=68471+1200→70k，非 68k！）；`cache 92%` 绿；`» my-session`。
- 把 window 改 1000000：token 文本变 `70k/1M`。
- **low-context.json**：`!█░░░░ 12% 176k/200k` 亮红；`$1.07` 黄；`5h` 青标签+`82%`亮红+白重置；`7d 45%` 绿无重置。
- **minimal.json**：第 2 行消失（新会话无历史时），无悬空分隔符。
- 人工写 3 行同会话历史（epoch 递增、token 递增）再跑：出现青色走势+速率；花费速率 `$X.X/h`。
- 干净/脏 git 仓库两态：绿 `main` / 绿 `main`+黄`*`。

子代理行（`fixtures/subagent-tasks.json`，4 任务应输出 3 行有效 JSON）：
- t1：`▸ code-reviewer(general)·max ●`（紫/灰/亮红/绿）、`68k tok`、走势`▄█▁▁`+速率、`Σ`份额、秒级用时`@HH:MM:SS`、描述截断。
- t2：`12k tok`；`✓` **绿**；分钟级速率 `131/m`。
- t3：label 兜底 + `·haiku-4-5` 青（少数派）+ `·50000` 黄 + `✗` 亮红 + `185k tok`；对象形态 tokenSamples 走势正常。
- 无 id 任务不产生输出行。
- **对齐**：多行输出剥掉全部转义后，所有 ` | ` 分隔符逐列竖向对齐（纯 ASCII 列必须精确对齐）；主状态栏三行同理。
- **链接**：full.json 渲染输出中 `\e]8;;` 出现 4 次（仓库、PR 各一对开闭）。

边界清单：remaining null、pr 无状态、单窗口限额、effort/thinking/repo/session_name 全缺、路径 3 层不折叠/4 层折叠、主目录=`~`、历史文件损坏行/不可写、tokenSamples 乱结构、startTime 毫秒与秒、19.6% 显示 20% 仍触发红档。
