# context-nudge

Claude Code 的 context 用量感知 + 会话交接工具。

自动压缩（compact）腾不出空间的时候**轻推提醒**你该交接了。只要压缩还管用就不打扰；提醒跟着你的下一条消息一起交给 Agent，由它在正常回答末尾顺带提一句，不会单独多回一轮。

基于 [pwolbrycht/claude-code-handoff](https://github.com/pwolbrycht/claude-code-handoff)（MIT）改造，去掉了项目特定的功能，改为通用的中文提醒。

## 组成

| 文件 | 作用 |
|------|------|
| `scripts/prompt-hook-context-nudge.sh` | **UserPromptSubmit hook** — 每次你发消息时看压缩次数和压缩后基线，到档时把提醒附给 Agent |
| `scripts/statusline-context.sh` | **Statusline** — 底栏常驻显示 context 百分比，到档时附上行动提示 |
| `skills/handoff/SKILL.md` | **`/handoff` skill** — 生成交接摘要并复制到剪贴板 |

## 什么时候提醒

每轮请求都会把系统提示、工具定义、CLAUDE.md 和整段对话历史重新发一遍，所以「当前 context」就是每轮带给 Agent 的总量。compact 会把它降回一个**基线**（固定开销 + 历史摘要 + 压缩后带回的文件、todo 等），之后接着涨。基线一次比一次高时，压缩能腾出的空间越来越少——这才是该换新对话的信号。第一次 compact 之前压缩还能兜底，不需要提醒。

| 档位 | 条件（任一满足） | 提示 |
|------|----------------|------|
| 不提醒 | 还没 compact 过，或压缩后基线低 | — |
| 建议交接 | 已 compact 2 次，或压缩后基线 ≥ 30% | 回答末尾建议在合适的节点 `/handoff` |
| 立即交接 | 已 compact 3 次，或压缩后基线 ≥ 50% | 建议做完当前一小步就 `/handoff`，不再接新的大任务 |

- **压缩后基线**：最近一次 compact 后第一次请求的 token 用量，占模型完整窗口的百分比。
- 每档只提醒一次，升档时再提醒一次。
- 以 `/` 开头的消息（比如 `/handoff`）不插话，留到下一条普通消息。
- 关闭了自动压缩的会话不会触发提醒，只靠状态栏的百分比颜色。

每个 Session 的状态保存在 `~/.claude/state/context-nudge-<session-id>.state`：`level` 是当前档位，`reminded_level` 是已提醒过的最高档，`compact_count`、`floor_pct`、`ctx_pct` 是最近一次的读数，`trigger_count` / `reminder_count` 是 hook 调用次数和实际提醒次数。

运行 `bash tests/run.sh` 跑全部测试：`tests/prompt-hook.sh` 覆盖档位判定、提醒次数、基线取值、窗口判定和异常输入，`tests/statusline.sh` 覆盖颜色分档、行动提示和目录分支显示。

## 安装

### 前置依赖

- `jq`（macOS: `brew install jq`，Linux: `apt install jq`）
- `bash`

### 1. 复制文件

```bash
# hook 脚本
mkdir -p ~/.claude/scripts
cp scripts/prompt-hook-context-nudge.sh ~/.claude/scripts/
chmod +x ~/.claude/scripts/prompt-hook-context-nudge.sh

# handoff skill
mkdir -p ~/.claude/skills/handoff
cp skills/handoff/SKILL.md ~/.claude/skills/handoff/

# statusline（可选 — 如果你已有自己的 statusline，参考下面的集成方式）
cp scripts/statusline-context.sh ~/.claude/scripts/
chmod +x ~/.claude/scripts/statusline-context.sh
```

### 2. 配置 settings.json

在 `~/.claude/settings.json`（全局）或项目的 `.claude/settings.json` 中添加：

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/scripts/prompt-hook-context-nudge.sh\"",
            "timeout": 10
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "bash \"$HOME/.claude/scripts/statusline-context.sh\""
  }
}
```

如果你已有其他 hook 或 statusline，合并进去即可。

### 3. 集成到已有 statusline（可选）

如果你有自己的 statusline 脚本，不需要替换，只需读 hook 写的档位，在百分比后面加上行动提示：

```bash
# 在你的 statusline.sh 中加上（statusline 的 payload 带 session_id）：
session_id=$(jq -r '.session_id // empty' <<<"$input")
ctx_action=""
nudge_state="$HOME/.claude/state/context-nudge-${session_id}.state"
if [ -n "$session_id" ] && [ -f "$nudge_state" ]; then
    case "$(sed -n 's/^level=//p' "$nudge_state")" in
        1) ctx_action=" 建议交接" ;;
        2) ctx_action=" 立即交接" ;;
    esac
fi
# 然后在输出中追加 $ctx_action
```

### 4. 会话聚焦规则（可选）

在 `~/.claude/CLAUDE.md` 中加一句，让 Claude 在识别到偏离主线的杂活时建议开新对话：

```markdown
## 会话聚焦

当用户在一个有明确主线的会话中插入不相关的杂活或小任务时，建议用户开一个新对话去处理，以免浪费当前会话的 context。
```

## 自定义

### 调整阈值

编辑 `prompt-hook-context-nudge.sh` 顶部的变量：

```bash
FLOOR_PCT_MID=30    # 压缩后基线达到多少进「建议交接」
FLOOR_PCT_HIGH=50   # 压缩后基线达到多少进「立即交接」
COMPACTS_MID=2      # compact 几次进「建议交接」
COMPACTS_HIGH=3     # compact 几次进「立即交接」
```

`statusline-context.sh` 顶部的 `CTX_THRESHOLD_*` 只决定百分比的颜色。

### 修改提示语

编辑 hook 里的 `user_msg=` 和 `agent_msg=`。`user_msg` 是终端里给你看的 `systemMessage`；`agent_msg` 是附给 Agent 的 `additionalContext`。

## 工作原理

1. **UserPromptSubmit hook** 在你每次发消息时触发。脚本从 transcript 里找出真正的 `compact_boundary` 记录（对话内容里出现这个词不算），得到压缩次数；取最近一次 compact 后第一条主线回复的 token 用量（`input + cache_creation + cache_read`，跳过合成回复；还没有回复时用 `compactMetadata.postTokens`）作为基线，再按模型的完整窗口大小换算成百分比。`CLAUDE_CODE_DISABLE_1M_CONTEXT` 生效时按 200k，其他情况下按模型后缀和用量推测 200k 或 1M
2. 进入新档位时，向 stdout 输出终端可见的 `systemMessage` 和附在你这条消息上的 `hookSpecificOutput.additionalContext`。Agent 处理你的消息时一并看到提醒，在回答末尾顺带一句，不会额外开一轮
3. **Statusline** 持续显示当前 context 百分比，并读取状态文件里的档位显示行动提示
4. **`/handoff` skill** 由用户手动触发，AI 盘点变更后生成交接摘要并复制到剪贴板

## 致谢

- [pwolbrycht/claude-code-handoff](https://github.com/pwolbrycht/claude-code-handoff) — 原始设计和 hook 机制
- [legacybridge-tech/steady-hand](https://github.com/legacybridge-tech/claude-plugins/tree/main/steady-hand) — context 监控思路

## License

MIT
