#!/usr/bin/env bash
# Claude Code statusline: context 用量 + 行动提示。
# 可独立使用，也可集成到已有 statusline 脚本中。
set -uo pipefail

# --- 可调参数 ---------------------------------------------------------------
# 只决定百分比的颜色；「建议交接 / 立即交接」由 prompt hook 判定后写进状态文件。
CTX_THRESHOLD_LOW=40
CTX_THRESHOLD_MID=65
CTX_THRESHOLD_HIGH=85
# ---------------------------------------------------------------------------

payload=$(cat)
ctx_pct=$(jq -r '.context_window.used_percentage // 0' <<<"$payload")
ctx_pct=$(printf '%.0f' "$ctx_pct" 2>/dev/null || echo 0)
model=$(jq -r '.model.display_name // "Claude"' <<<"$payload")
cwd=$(jq -r '.workspace.current_dir // "."' <<<"$payload")
dirname=$(basename "$cwd")
session_id=$(jq -r '.session_id // empty' <<<"$payload")

# Git branch
branch=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null || echo "")
fi

# Colors
blue=$'\033[34m'
green=$'\033[32m'
cyan=$'\033[38;2;86;182;194m'
dim=$'\033[2m'
reset=$'\033[0m'
sep=" ${dim}|${reset} "

# Context 颜色
if (( ctx_pct >= CTX_THRESHOLD_HIGH )); then
  ctx_color=$'\033[1;97;48;2;180;30;30m'
elif (( ctx_pct >= CTX_THRESHOLD_MID )); then
  ctx_color=$'\033[1;30;48;2;255;140;0m'
elif (( ctx_pct >= CTX_THRESHOLD_LOW )); then
  ctx_color=$'\033[1;30;48;2;255;235;130m'
else
  ctx_color=$'\033[2m'
fi

# 行动提示：读 prompt hook 记录的档位（compact 后基线过高或压缩次数过多才会出现）
action=''
nudge_state="${HOME}/.claude/state/context-nudge-${session_id}.state"
if [[ -n "$session_id" && -f "$nudge_state" ]]; then
  nudge_level=$(sed -n 's/^level=//p' "$nudge_state")
  case "$nudge_level" in
    1) action=' 建议交接' ;;
    2) action=' 立即交接' ;;
  esac
fi

out="${blue}${model}${reset}"
out+="${sep}"
out+="${ctx_color} ctx:${ctx_pct}%${action} ${reset}"
out+="${sep}"
out+="${cyan}${dirname}${reset}"
if [[ -n "$branch" ]]; then
  out+=" ${green}(${branch})${reset}"
fi

printf '%s' "$out"
