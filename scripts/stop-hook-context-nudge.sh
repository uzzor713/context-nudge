#!/usr/bin/env bash
# Stop hook: context 用量超阈值时打彩色药丸提醒 + 注入 systemMessage。
# 三档阈值，每档最多提醒 3 次。
# 基于 pwolbrycht/claude-code-handoff (MIT) 改造。
# -e 故意省略：jq 偶尔解析失败应降级而非阻塞 Claude 回合。
set -uo pipefail

# --- 可调参数 ---------------------------------------------------------------
CTX_THRESHOLD_LOW=40
CTX_THRESHOLD_MID=65
CTX_THRESHOLD_HIGH=85
# ---------------------------------------------------------------------------

payload=$(cat)
session_id=$(jq -r '.session_id // "unknown"' <<<"$payload")

mkdir -p "${HOME}/.claude/state"
state_file="${HOME}/.claude/state/claude-stop-hook-${session_id}.state"
last_level=0
level1_count=0
level2_count=0
level3_count=0
# shellcheck disable=SC1090
[[ -f "$state_file" ]] && . "$state_file"

# 优先读 Claude Code payload 里的 live ctx %；兜底用 transcript 字节估算。
ctx_pct=$(jq -r '.context_window.used_percentage // empty' <<<"$payload")
if [[ -z "$ctx_pct" ]]; then
  transcript_path=$(jq -r '.transcript_path // empty' <<<"$payload")
  if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    bytes=$(stat -f%z "$transcript_path" 2>/dev/null || stat -c%s "$transcript_path" 2>/dev/null || echo 0)
    ctx_pct=$(( bytes / 110000 ))
  else
    ctx_pct=0
  fi
fi
ctx_pct=$(printf '%.0f' "$ctx_pct" 2>/dev/null || echo 0)

level=0
(( ctx_pct >= CTX_THRESHOLD_LOW ))  && level=1
(( ctx_pct >= CTX_THRESHOLD_MID ))  && level=2
(( ctx_pct >= CTX_THRESHOLD_HIGH )) && level=3

# 药丸样式
PILL_LOW=$'\033[1;30;48;2;255;235;130m'   # 浅黄底黑字
PILL_MID=$'\033[1;30;48;2;255;140;0m'     # 橙底黑字
PILL_HIGH=$'\033[1;97;48;2;180;30;30m'    # 红底白字
N=$'\033[0m'

pill=""
sys_msg=""
case "$level" in
  1)
    if (( level1_count < 3 )); then
      pill="${PILL_LOW} 💡 Context ${ctx_pct}% · 留意用量，适时考虑开新对话 ${N}"
      sys_msg="[系统提醒] 当前 context 已用 ${ctx_pct}%。如果接下来的任务较重，可以建议用户考虑开新对话。"
      level1_count=$((level1_count + 1))
    fi
    ;;
  2)
    if (( level2_count < 3 )); then
      pill="${PILL_MID} ⚠️  Context ${ctx_pct}% · 建议准备交接，考虑 /handoff 后开新对话 ${N}"
      sys_msg="[系统提醒] 当前 context 已用 ${ctx_pct}%，空间不多了。请在合适时机提醒用户使用 /handoff 进行交接，然后开新对话继续。"
      level2_count=$((level2_count + 1))
    fi
    ;;
  3)
    if (( level3_count < 3 )); then
      pill="${PILL_HIGH} 🚨 Context ${ctx_pct}% · 强烈建议立即 /handoff 并开新对话 ${N}"
      sys_msg="[系统提醒] 当前 context 已用 ${ctx_pct}%，即将耗尽。请立即提醒用户使用 /handoff 生成交接摘要，然后开新对话。不要再接大任务。"
      level3_count=$((level3_count + 1))
    fi
    ;;
esac

(( level > last_level )) && last_level=$level
{
  echo "last_level=$last_level"
  echo "level1_count=$level1_count"
  echo "level2_count=$level2_count"
  echo "level3_count=$level3_count"
} > "$state_file"

if [[ -n "$pill" ]]; then
  printf '%s\n' "$pill" >&2
  jq -nc --arg m "$sys_msg" '{systemMessage: $m}'
fi

exit 0
