#!/usr/bin/env bash
# UserPromptSubmit hook: 自动压缩不再腾得出空间时，提醒交接并开新会话。
# 提醒随用户这条消息一起交给 Agent，由 Agent 在正常回答里顺带提一句，不额外占一轮。
# 基于 pwolbrycht/claude-code-handoff (MIT) 改造。
# -e 故意省略：jq 偶尔解析失败应降级而非阻塞用户提交。
set -uo pipefail

# --- 可调参数 ---------------------------------------------------------------
# 「压缩后基线」= 每次 compact 后第一次请求的 context 用量，占模型完整窗口的百分比。
# 只在至少 compact 过一次之后才判定；任一条件满足即进入该档。
FLOOR_PCT_MID=30    # 第一档：建议交接
FLOOR_PCT_HIGH=50   # 第二档：立即交接
COMPACTS_MID=2
COMPACTS_HIGH=3
# ---------------------------------------------------------------------------

payload=$(cat)
session_id=$(jq -r '.session_id // "unknown"' <<<"$payload")
transcript_path=$(jq -r '.transcript_path // empty' <<<"$payload")
prompt=$(jq -r '.prompt // ""' <<<"$payload")

mkdir -p "${HOME}/.claude/state"
state_file="${HOME}/.claude/state/context-nudge-${session_id}.state"
level=0
reminded_level=0
compact_count=0
floor_pct=0
ctx_pct=0
trigger_count=0
reminder_count=0
last_trigger_at=0
last_reminder_at=0
# shellcheck disable=SC1090
[[ -f "$state_file" ]] && . "$state_file"
trigger_count=$((trigger_count + 1))
last_trigger_at=$(date +%s)

# 主线 assistant 消息的真实请求量：input + cache_creation + cache_read（与状态栏口径一致）。
USAGE_JQ='select(.type == "assistant" and (.isSidechain | not) and .message.model != "<synthetic>" and .message.usage)
  | .message.usage | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)'

compact_count=0
floor_tokens=0
ctx_tokens=0
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
  # 先用 grep 粗筛，再用 jq 确认是真正的 compact_boundary 记录（对话内容里出现这个词不算）。
  boundaries=$(grep -n '"compact_boundary"' "$transcript_path" 2>/dev/null | jq -R -r '
    capture("^(?<n>[0-9]+):(?<j>.*)$") as $l
    | ($l.j | fromjson? | objects) as $e
    | select($e.type == "system" and $e.subtype == "compact_boundary")
    | "\($l.n) \($e.compactMetadata.postTokens // 0)"' 2>/dev/null)
  start_line=1
  if [[ -n "$boundaries" ]]; then
    compact_count=$(wc -l <<<"$boundaries" | tr -d ' ')
    read -r last_line post_tokens <<<"$(tail -n 1 <<<"$boundaries")"
    start_line=$((last_line + 1))
    # 基线取 compact 后第一次真实请求的用量（含压缩后重新带回的文件、todo 等）；还没有请求时用 postTokens。
    floor_tokens=$(tail -n +"$start_line" "$transcript_path" | head -n 500 \
      | jq -n -R -r "first(inputs | fromjson? | objects | $USAGE_JQ) // empty" 2>/dev/null)
    [[ "$floor_tokens" =~ ^[0-9]+$ ]] || floor_tokens=${post_tokens:-0}
    [[ "$floor_tokens" =~ ^[0-9]+$ ]] || floor_tokens=0
  fi
  ctx_tokens=$(tail -n +"$start_line" "$transcript_path" | tail -n 500 \
    | jq -n -R -r "reduce (inputs | fromjson? | objects | $USAGE_JQ) as \$t (null; \$t) // empty" 2>/dev/null)
  [[ "$ctx_tokens" =~ ^[0-9]+$ ]] || ctx_tokens=$floor_tokens
fi

# 百分比以模型完整窗口为分母。环境变量取进程环境，没有再取 settings.json 的 env 段。
settings="${HOME}/.claude/settings.json"
window=200000
disable_1m="${CLAUDE_CODE_DISABLE_1M_CONTEXT:-$(jq -r '.env.CLAUDE_CODE_DISABLE_1M_CONTEXT // empty' "$settings" 2>/dev/null)}"
if [[ -z "$disable_1m" ]]; then
  model_setting=$(jq -r '.model // empty' "$settings" 2>/dev/null)
  [[ "$model_setting" == *"[1m]"* || "${ANTHROPIC_MODEL:-}" == *"[1m]"* ]] && window=1000000
  (( ctx_tokens > window || floor_tokens > window )) && window=1000000
fi
floor_pct=$(( floor_tokens * 100 / window ))
ctx_pct=$(( ctx_tokens * 100 / window ))

level=0
if (( compact_count > 0 )); then
  (( compact_count >= COMPACTS_MID  || floor_pct >= FLOOR_PCT_MID  )) && level=1
  (( compact_count >= COMPACTS_HIGH || floor_pct >= FLOOR_PCT_HIGH )) && level=2
fi

user_msg=""
agent_msg=""
# 每档只提醒一次。用户正在执行斜杠命令（比如 /handoff）时不插话，留到下一条普通消息。
if (( level > reminded_level )) && [[ "$prompt" != /* ]]; then
  facts="本会话已自动压缩 ${compact_count} 次，压缩后基线占窗口 ${floor_pct}%，当前 ${ctx_pct}%"
  case "$level" in
    1)
      user_msg="⚠️ Context 已压缩 ${compact_count} 次，压缩后基线 ${floor_pct}% · 建议 /handoff 后开新对话"
      agent_msg="[context-nudge] ${facts}，再压缩能腾出的空间有限。先正常处理用户这条消息，在回答末尾用一句话建议用户在合适的节点 /handoff 并开新会话。不要为此单独回复，也不要打断当前任务。"
      ;;
    2)
      user_msg="🚨 Context 已压缩 ${compact_count} 次，压缩后基线 ${floor_pct}% · 强烈建议立即 /handoff 并开新对话"
      agent_msg="[context-nudge] ${facts}，自动压缩已基本腾不出空间。先正常处理用户这条消息，在回答末尾用一句话建议用户完成当前这一小步后立即 /handoff 并开新会话；不要再主动接新的大任务。不要为此单独回复。"
      ;;
  esac
  reminded_level=$level
  reminder_count=$((reminder_count + 1))
  last_reminder_at=$last_trigger_at
fi

{
  echo "level=$level"
  echo "reminded_level=$reminded_level"
  echo "compact_count=$compact_count"
  echo "floor_pct=$floor_pct"
  echo "ctx_pct=$ctx_pct"
  echo "trigger_count=$trigger_count"
  echo "reminder_count=$reminder_count"
  echo "last_trigger_at=$last_trigger_at"
  echo "last_reminder_at=$last_reminder_at"
} > "$state_file"

if [[ -n "$agent_msg" ]]; then
  jq -nc --arg u "$user_msg" --arg a "$agent_msg" \
    '{systemMessage: $u, hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $a}}'
fi

exit 0
