# context-nudge

Claude Code 的 context 用量感知 + 会话交接工具。

在 context 快用完之前**轻推提醒**你该交接了——不硬 block，不靠 AI 自觉，而是通过 hook 注入提示词 + 终端可视化双管齐下。

基于 [pwolbrycht/claude-code-handoff](https://github.com/pwolbrycht/claude-code-handoff)（MIT）改造，去掉了项目特定的功能，改为通用的中文提醒。

## 组成

| 文件 | 作用 |
|------|------|
| `scripts/stop-hook-context-nudge.sh` | **Stop hook** — 每次 AI 回复后检查 context 百分比，超阈值打彩色药丸 + 注入 systemMessage |
| `scripts/statusline-context.sh` | **Statusline** — 底栏常驻显示 context 百分比和行动提示 |
| `skills/handoff/SKILL.md` | **`/handoff` skill** — 生成交接摘要并复制到剪贴板 |

## 三档提醒

| 阈值 | 药丸颜色 | 提示 | AI 行为 |
|------|---------|------|---------|
| 40% | 浅黄 | 留意用量 | 大任务时建议开新对话 |
| 65% | 橙色 | 准备交接 | 提醒用户 `/handoff` |
| 85% | 红色 | 立即交接 | 催促交接，拒绝接大任务 |

每档最多提醒 3 次，不会无限骚扰。升到更高档时重新开始计数。

## 安装

### 前置依赖

- `jq`（macOS: `brew install jq`，Linux: `apt install jq`）
- `bash`

### 1. 复制文件

```bash
# hook 脚本
mkdir -p ~/.claude/scripts
cp scripts/stop-hook-context-nudge.sh ~/.claude/scripts/
chmod +x ~/.claude/scripts/stop-hook-context-nudge.sh

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
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/scripts/stop-hook-context-nudge.sh\"",
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

如果你有自己的 statusline 脚本，不需要替换，只需在显示 context 百分比的地方加上行动提示：

```bash
# 在你的 statusline.sh 中，计算出 pct_used 之后加上：
ctx_action=""
if [ "$pct_used" -ge 85 ]; then
    ctx_action=" 立即交接"
elif [ "$pct_used" -ge 65 ]; then
    ctx_action=" 准备交接"
elif [ "$pct_used" -ge 40 ]; then
    ctx_action=" 留意用量"
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

编辑 `stop-hook-context-nudge.sh` 和 `statusline-context.sh` 顶部的变量：

```bash
CTX_THRESHOLD_LOW=40   # 第一档
CTX_THRESHOLD_MID=65   # 第二档
CTX_THRESHOLD_HIGH=85  # 第三档
```

### 调整提醒次数

在 hook 脚本中搜索 `< 3`，改成你想要的次数。

### 修改提示语

直接编辑 `pill=` 和 `sys_msg=` 行。`pill` 是给你看的终端提示，`sys_msg` 是注入给 AI 的系统消息。

## 工作原理

1. **Stop hook** 在每次 Claude 回复后触发。Stop hook 的 payload 不带 context 百分比，脚本从 transcript 末尾取最后一条主线回复的 token 用量（`input + cache_creation + cache_read`，与 statusline 口径一致；compact 之后取压缩后的用量），再按窗口大小换算：`settings.json` 的 `model` 或 `ANTHROPIC_MODEL` 带 `[1m]` 后缀按 1M 算，否则按 200k
2. 超过阈值时，向 stderr 输出彩色药丸（你在终端看到），向 stdout 输出 JSON `{systemMessage: "..."}` （Claude 读到）
3. **Statusline** 每次 prompt 时重新渲染，持续显示当前 context 百分比
4. **`/handoff` skill** 由用户手动触发，AI 盘点变更后生成交接摘要并复制到剪贴板

两路提醒：药丸是主动弹出的告警，statusline 是被动的环境感知。systemMessage 让 AI 也知道 context 紧张，会在回复中配合提醒。

## 致谢

- [pwolbrycht/claude-code-handoff](https://github.com/pwolbrycht/claude-code-handoff) — 原始设计和 hook 机制
- [legacybridge-tech/steady-hand](https://github.com/legacybridge-tech/claude-plugins/tree/main/steady-hand) — context 监控思路

## License

MIT
