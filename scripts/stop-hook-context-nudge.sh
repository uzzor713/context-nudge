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

# Stop hook 的 payload 目前不带 context_window，主路径是读 transcript 里的真实用量：
# 最后一条主线 assistant 消息的 usage（input + cache_creation + cache_read，与状态栏口径一致）；
# 若其后出现 compact_boundary，则取 compactMetadata.postTokens。
ctx_pct=$(jq -r '.context_window.used_percentage // empty' <<<"$payload")
if [[ -z "$ctx_pct" ]]; then
  ctx_pct=0
  transcript_path=$(jq -r '.transcript_path // empty' <<<"$payload")
  if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    tokens=$(tail -n 500 "$transcript_path" | jq -n -R -r '
      reduce (inputs | fromjson? | objects) as $e (0;
        if $e.type == "system" and $e.subtype == "compact_boundary" then
          ($e.compactMetadata.postTokens // 0)
        elif $e.type == "assistant" and ($e.isSidechain | not) and $e.message.usage then
          ($e.message.usage | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
        else . end)' 2>/dev/null)
    [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=0

    # 窗口大小：模型带 [1m] 后缀或用量已超 200k 时按 1M 算
    window=200000
    model_setting=$(jq -r '.model // empty' "${HOME}/.claude/settings.json" 2>/dev/null)
    [[ "$model_setting" == *"[1m]"* || "${ANTHROPIC_MODEL:-}" == *"[1m]"* ]] && window=1000000
    (( tokens > window )) && window=1000000

    ctx_pct=$(( tokens * 100 / window ))
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
