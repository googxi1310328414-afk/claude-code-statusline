# AI 复刻指导：Claude Code 彩色状态栏

> **用法**：把本文件全文发给 Claude Code（或任何能读写文件、执行 shell 的 AI agent），并说"按这份指导给我配置状态栏"。本文包含完整规格：数据契约、11 段的精确格式与颜色、动态阈值、健壮性要求、安装与验证步骤。参考实现见仓库根目录 `statusline-command.sh`，但你（AI）应按本规格在目标机器上适配重建，而不是盲目复制。

## 0. 前置检查

1. 确认环境：脚本运行于 **bash**（Windows 上是 Git Bash；bash ≥ 4，需要 `${var,,}` 小写化）。`jq`、`git` 必须可用。
2. 确认目标机器的**主目录**（如 `C:\Users\<用户名>` 或 `/home/<用户名>`），第 3 段的缩写逻辑要用它，不要硬编码别人机器的路径。
3. 时间格式化：`date -d "@epoch"` 是 GNU date（Git Bash / Linux）；macOS/BSD 用 `date -r epoch`。
4. Claude Code 通过 **stdin 传入一个 JSON**（每次状态栏刷新执行一次脚本），脚本把最终的一行文本输出到 stdout。ANSI 颜色受支持。

## 1. stdin JSON 数据契约（只列用到的字段）

```jsonc
{
  "session_name": "my-session",            // 可选：会话名
  "model":   { "display_name": "Fable 5" },
  "effort":  { "level": "max" },           // 可选：low|medium|high|xhigh|max
  "thinking":{ "enabled": true },          // 可选
  "workspace": {
    "current_dir": "C:\\Users\\me\\proj\\webapp",
    "repo": { "owner": "acme", "name": "webapp" }   // 可选：来自 origin 远程
  },
  "pr": { "number": 42, "review_state": "approved" }, // 可选；review_state 可能缺失
  "context_window": {
    "remaining_percentage": 65.8,          // 可能为 null
    "total_input_tokens": 68471,           // 可选
    "context_window_size": 200000          // 可选
  },
  "cost": {                                // 整个对象可能缺失
    "total_cost_usd": 0.4231,
    "total_lines_added": 156,
    "total_lines_removed": 23
  },
  "rate_limits": {                         // 可选；两个窗口各自独立可选
    "five_hour": { "used_percentage": 37.4, "resets_at": 1770000000 },
    "seven_day": { "used_percentage": 12.1, "resets_at": 1770500000 }
  }
}
```

**铁律**：任何字段都可能缺失或为 null。取值一律 `jq -r '<path> // empty'`；某段没有数据就整段消失，绝不显示 "null"、不留空段、不产生多余分隔符。

## 2. 输出规格：11 段，按序拼接

分隔符为灰色 ` | `（前后各带 reset）。整行末尾追加一次 reset。

颜色一律用基础 16 色 ANSI（30–37 / 90–97），以 bash ANSI-C quoting 定义常量（如 `GREEN=$'\e[32m'`），字符串里直接嵌入真实 ESC 字节，最终 `printf '%s\n'` 输出（**永远不用 `%b`**）。每个着色 token 单独 reset。

本文颜色记号：灰=90、红=31、绿=32、黄=33、蓝=34、紫=35、青=36、白=37、亮蓝=94、亮紫=95、亮青=96、亮红=91、亮白=97。

| # | 段 | 规格 |
|---|---|---|
| 1 | 时间 | `date +%H:%M`（不来自 stdin）。**亮白**。 |
| 2 | 模型 | `模型名·思考等级·think`，三部分独立着色：模型名**亮青**；`·` 分隔点**灰**；思考等级按档位热度：low **灰**、medium **绿**、high **黄**、xhigh **亮紫**、max **亮红**、未知值**黄**；`think` 标记（仅当 `.thinking.enabled == true`）**紫**。没有 effort 就没有 `·effort`，thinking 非 true 就没有 `·think`，只剩模型名时就单独显示亮青名字。 |
| 3 | 目录 | 显示用副本做三步变换：① 前缀等于主目录（大小写不敏感，反斜杠/正斜杠两种写法都要匹配）→ 替换为 `~`；② 所有 `/` 统一为 `\`；③ 按 `\` 拆分后组件数 > 3 → 折叠为 `首\…\倒数第二\末尾`。着色：末级组件**亮蓝**，之前的一切（盘符或 `~`、`…`、所有反斜杠）**蓝**；单组件路径（如 `~`）整体亮蓝。**git 命令必须用原始未变换路径**，显示文本只管显示。 |
| 4 | 仓库 | `.workspace.repo` 的 owner 和 name 都存在才显示：owner **青** + `/` **灰** + name **亮青**。 |
| 5 | 分支 | `git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null`，非空才继续。分支名恒**绿**；脏检测 `git -C "$dir" --no-optional-locks status --porcelain 2>/dev/null | head -c1` 非空 → 追加一个独立的**黄**色 `*`。脏检测只在已确认有分支后执行。 |
| 6 | PR | `.pr.number` 存在才显示。`PR#<号>` **紫**；有 `review_state` 再加空格 + 状态词，状态色：approved **绿**、changes_requested **亮红**、draft **灰**、pending 及其他**黄**。 |
| 7 | 上下文 | `remaining_percentage` 存在才显示。格式：`[!]<电池条> N% [Xk/Yk]`，如 `███░░ 66% 68k/200k`、`!█░░░░ 12% 176k/200k`。电池条固定 5 格：实格数 = `(remaining_int + 10) / 20`（整数运算，等于四舍五入到五分位），夹在 0–5；实格用 `█`（U+2588），空格用 `░`（U+2591）。阈值判断用**整数截断**（`remaining_int="${v%%.*}"`，等价于 floor）：<20 → 前缀独立**亮红** `!` 且实格与百分比**亮红**；20–49 → 实格与百分比**黄**；≥50 → 实格与百分比**绿**；空格恒**灰**。百分比显示值用 `printf '%.0f'` 四舍五入（显示与阈值判断分离，允许 19.6 显示为 20% 但仍触发警告）。token 数：`total_input_tokens` 与 `context_window_size` 都存在且为纯数字才显示，各自 `(n+500)/1000` 整数运算取 k：`68k` **白** + `/200k`（含斜杠）**灰**。脚本文件须为 UTF-8，方块字符直接字面嵌入。 |
| 8 | 花费 | `.cost.total_cost_usd` 存在才显示。`$` **灰**；金额 `printf '%.2f'`，色由整数部分定：<1 **灰**、1–4 **黄**、≥5 **亮红**。 |
| 9 | 行数 | added/removed 任一存在就显示（缺的按 0）：`+A` **绿** + `/`（不着色）+ `-R` **红**。 |
| 10 | 限额 | 两个窗口各自独立可选，窗口间以普通空格连接。每窗口一个动态色，由该窗口自己的 floor(used_percentage) 决定：<50 **绿**、50–79 **黄**、≥80 **亮红**；标签 `5h`/`7d` 和百分比**共用**这个动态色（同一个颜色变量驱动，不允许不一致）；百分比显示 `printf '%.0f'`；`resets_at` 通过 `^[0-9]+$` 校验后才交给 date——5h 窗口 `→HH:MM`（本地时间）、7d 窗口 `→MM-DD`，箭头和时间**青**（低调但非灰）。 |
| 11 | 会话名 | `.session_name` 存在才显示，**灰**。 |

## 3. 实现硬性要求

1. **无浮点运算**：不用 `bc`/`awk` 做比较。阈值判断一律"截断小数部分 → 整数比较"（对非负数等价于 floor）；显示值另行 `printf '%.0f'` / `'%.2f'`。
2. **printf 守卫**：任何送进 `printf` 数字格式或 bash 算术的值，先用 `[ -n ... ]` 与 `[[ =~ ^[0-9]+$ ]]` 校验，空串/非数字绝不触发格式化。
3. **着色不改变存在性判断**：先判断段有无内容，再包颜色——不能出现"只有颜色码的空段"混进最终拼接，那会产生悬空分隔符。
4. **git 调用**：全部 `--no-optional-locks`、stderr 静默；目录不存在或非仓库时整段静默消失；传给 git 的是原始路径而非显示用缩写。
5. stdin 只读一次（`input=$(cat)`），后续用 `printf '%s' "$input" | jq -r ...` 取值（不要用 `echo`，防止反斜杠被解释）。
6. 输出单行，`printf '%s\n'` 收尾，行尾补一次 reset。

## 4. 安装

1. 脚本写入 `~/.claude/statusline-command.sh`。
2. 在 `~/.claude/settings.json` **合并**（不要覆盖其他已有键）：

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
```

3. 状态栏每次刷新重新执行脚本，保存即生效。

## 5. 验证（必须实际执行）

用仓库 `fixtures/` 下三份 JSON 喂给脚本验证（`bash statusline-command.sh < fixtures/full.json`），或直接 `bash test.sh`。核对以下要点：

- **full.json**（全字段）：11 段齐全、顺序正确；电池条为绿色 `███░░`（66% → 3 实格）；`68471→68k`、`0.4231→$0.42`、百分比四舍五入正确；重置时间 `→HH:MM`/`→MM-DD` 为青色。
- **minimal.json**（新会话、主目录、无仓库）：只剩 `时间 | 模型 | ~ | $0.00 | +0/-0`，无多余分隔符。
- **low-context.json**（剩 12.3%）：`!` 前缀出现且亮红，电池条为红色 `█░░░░`（1 实格）；`~\proj\webapp` 父/末级两色；`$1.07` 黄；`5h 82%` 标签与百分比同为亮红、重置时间青色；`7d 45%` 标签与百分比同为绿、不带重置时间。
- **电池条档位**：用 jq 把剩余百分比改成 95 / 35.5 / 5，分别得到 `█████`（绿满格）、`██░░░`（黄 2 格）、`░░░░░`（红 0 格带 `!`）。
- **分支两态**：把 `current_dir` 指向一个真实临时 git 仓库（`git init -b main`），干净时绿色 `main`；写入一个未跟踪文件后重跑，出现黄色 `*`。
- **思考档位**：用 jq 把 `.effort.level` 依次改成 low/medium/high/xhigh/max，确认五档颜色（灰/绿/黄/亮紫/亮红）。
- **颜色码核对**：输出管过 `sed 's/\x1b/\\e/g'` 逐段比对上表颜色编号。

边界清单：`remaining_percentage` 为 null（段消失）、`pr` 无 `review_state`（只显示紫色 PR#N）、`rate_limits` 只有一个窗口、`effort`/`thinking`/`session_name`/`repo` 全缺、路径恰好 3 层（不折叠）与 4 层（折叠）、主目录本身（显示 `~`）。
