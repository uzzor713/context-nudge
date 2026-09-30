#!/usr/bin/env bash
# Claude Code statusline: context 用量 + 行动提示。
# 可独立使用，也可集成到已有 statusline 脚本中。
set -uo pipefail

# --- 可调参数（与 stop hook 保持一致）--------------------------------------
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

# Context 颜色和行动提示
if (( ctx_pct >= CTX_THRESHOLD_HIGH )); then
  ctx_color=$'\033[1;97;48;2;180;30;30m'
  action=' 立即交接'
elif (( ctx_pct >= CTX_THRESHOLD_MID )); then
  ctx_color=$'\033[1;30;48;2;255;140;0m'
  action=' 准备交接'
elif (( ctx_pct >= CTX_THRESHOLD_LOW )); then
  ctx_color=$'\033[1;30;48;2;255;235;130m'
  action=' 留意用量'
else
  ctx_color=$'\033[2m'
  action=''
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
