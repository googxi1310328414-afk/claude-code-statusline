# claude-code-statusline

Claude Code 的信息密集型彩色状态栏（Windows / Git Bash）。一行显示 11 段信息，数据缺失的段自动隐藏，关键指标随状态动态变色。

```
14:32 | Fable 5·max·think | ~\proj\webapp | acme/webapp | main* | PR#42 approved | ███░░ 66% 68k/200k | $0.42 | +156/-23 | 5h 37%→09:00 7d 12%→08-15 | my-session
```

上下文吃紧时：

```
09:15 | Fable 5 | ~\…\b\c | !█░░░░ 12% 176k/200k | $1.07 | +10/-2 | 5h 82%→10:40 7d 45%
```

新会话最小形态：

```
14:32 | Fable 5 | ~ | $0.00 | +0/-0
```

## 11 段一览

| # | 段 | 内容 | 颜色 |
|---|---|---|---|
| 1 | 时间 | 本地时钟 `HH:MM` | 亮白 |
| 2 | 模型 | 模型名 `·` 思考等级 `·` think 标记 | 亮青 / 热度渐变 / 紫 |
| 3 | 目录 | 主目录缩写为 `~`，深路径折叠为 `首\…\尾两级` | 父路径蓝 + 末级亮蓝 |
| 4 | 仓库 | origin 的 `owner/name` | 青 / 灰 / 亮青 |
| 5 | 分支 | 分支名 + 未提交改动标记 `*` | 绿 + 黄`*` |
| 6 | PR | 当前分支 PR 号与评审状态 | 紫 + 状态动态色 |
| 7 | 上下文 | 五格电池条 + 剩余百分比 + `已用k/总量k` | 电池条与百分比动态色，空格灰 |
| 8 | 花费 | 本会话估算费用（USD） | `$`无色 + 金额动态色 |
| 9 | 行数 | 本会话代码行增减 | `+`绿 `/` `-`红 |
| 10 | 限额 | 5 小时 / 7 天窗口用量与重置时间 | 标签青，百分比动态色，重置时间白 |
| 11 | 会话名 | 自定义 / AI 生成的会话名 | 灰 |

## 动态颜色规则

| 段 | 绿 | 黄 | 亮红 | 其他 |
|---|---|---|---|---|
| 思考等级 | medium | high | max | low 灰、xhigh 亮紫 |
| 分支 | 名字恒绿 | 脏标记 `*` | — | — |
| PR 状态 | approved | 待审/未知 | changes_requested | draft 灰 |
| 上下文剩余 | ≥50% | 20–49% | <20%（加 `!` 前缀） | — |
| 花费 | — | $1–4 | ≥$5 | <$1 灰 |
| 限额（每窗口独立） | <50% | 50–79% | ≥80% | — |

## 依赖

- Claude Code（状态栏由它以 JSON 通过 stdin 驱动）
- Git Bash（Git for Windows 自带；bash ≥ 4）
- `jq`、`git`（Git Bash 环境内可用）

## 安装

1. 把 `statusline-command.sh` 复制到 `~/.claude/statusline-command.sh`。
2. **改两行**：脚本第 82–83 行的 `home_bs` / `home_fs` 硬编码了原机器的主目录（`C:\Users\Administrator`），改成你自己的主目录路径（分别是反斜杠和正斜杠写法）。
3. 在 `~/.claude/settings.json` 里合并进 `settings-snippet.json` 的内容（只添加 `statusLine` 键，别覆盖已有配置）：

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
```

状态栏每次刷新都会重新执行脚本，保存后立即生效，无需重启。

### 让 AI 替你装（推荐）

把 [`AI-GUIDE.md`](AI-GUIDE.md) 的内容整个发给 Claude Code（或其他会写 shell 的 AI agent），它会按规格在你的机器上重建、适配并验证整套状态栏——这份指导文件就是本仓库的核心。

## 子代理面板行（subagentStatusLine）

Claude Code 的底部状态栏永远显示主会话数据（官方没有让它跟随子代理视图的机制），但代理面板里每个子代理的那一行可以完全接管。`subagent-statusline.sh` 把它渲染成与主状态栏同一套视觉语言、又刻意做了区分的瘦身版：

```
▸ code-reviewer·max | running | ███░░ 66% 68k/200k | 5m | Review the auth module for c…
```

- 行首灰色 `▸` + **亮紫**名称——主状态栏的身份色是亮青，一眼分清主/子
- `·max` 仅当该子代理被显式指定思考档位时出现（缺省继承主会话，不显示）
- 状态动态色：running 绿 / 排队 黄 / failed 亮红 / completed 灰
- 电池条是**该子代理自己**的上下文余量（`tokenCount`/`contextWindowSize`，需 Claude Code ≥ 2.1.205）
- 用时 + 按面板宽度（`columns`）预算截断的描述
- 机制与主状态栏不同：每次刷新 stdin 收到一个 `{"columns":N,"tasks":[…]}`，脚本对每行输出一条 `{"id":…,"content":…}` JSON 来接管渲染；无 `id` 的任务保持默认渲染

安装：把 `subagent-statusline.sh` 复制到 `~/.claude/`，settings.json 合并 `subagentStatusLine` 键（`settings-snippet.json` 已含两个键）。

## 测试

```bash
bash test.sh          # 渲染全部测试夹具（终端里直接看颜色效果）
bash test.sh --codes  # 把 ANSI 转义显示为 \e[..m，便于核对颜色代码
```

`test.sh` 会额外创建一个临时 git 仓库演示干净/脏分支两种状态，并渲染子代理面板行（含动态用时）。

## 移植注意

- 重置时间用的 `date -d "@epoch"` 是 GNU date 语法（Git Bash 自带）；macOS/BSD 需改为 `date -r epoch`。
- `rate_limits`、`pr`、`session_name`、`effort` 等字段并非每个会话都存在，脚本对所有可选字段做了 `// empty` 守卫，缺什么就少显示什么，不会报错。
