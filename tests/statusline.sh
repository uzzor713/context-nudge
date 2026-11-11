#!/usr/bin/env bash
# statusline：百分比颜色分档、行动提示读取 hook 档位、目录与 git 分支显示。
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

test_home=$(mktemp -d)
trap 'rm -rf "$test_home"' EXIT
script="$here/../scripts/statusline-context.sh"
state_dir="$test_home/.claude/state"
mkdir -p "$state_dir"

render() { # $1 = payload JSON
  HOME="$test_home" bash "$script" <<<"$1" 2>/dev/null
}
plain() { sed $'s/\033\\[[0-9;]*m//g'; }
payload() { # $1 = session, $2 = 百分比, $3 = 目录（可选）
  jq -nc --arg s "$1" --argjson p "$2" --arg d "${3:-$test_home}" \
    '{session_id:$s, model:{display_name:"Opus"}, context_window:{used_percentage:$p}, workspace:{current_dir:$d}}'
}

# 1. 没有状态文件：只显示百分比，没有行动提示
out=$(render "$(payload s-none 42)" | plain)
assert '[[ $out == *"ctx:42% "* && $out != *交接* && $out == Opus* ]]'

# 2. 行动提示跟随 hook 记录的档位
printf 'level=0\n' > "$state_dir/context-nudge-s0.state"
printf 'reminded_level=2\nlevel=1\n' > "$state_dir/context-nudge-s1.state"
printf 'level=2\n' > "$state_dir/context-nudge-s2.state"
out=$(render "$(payload s0 90)" | plain);  assert '[[ $out != *交接* ]]'
out=$(render "$(payload s1 20)" | plain);  assert '[[ $out == *"ctx:20% 建议交接"* ]]'
out=$(render "$(payload s2 20)" | plain);  assert '[[ $out == *"ctx:20% 立即交接"* ]]'

# 3. payload 不带 session_id 时不读状态文件
printf 'level=2\n' > "$state_dir/context-nudge-.state"
out=$(render '{"context_window":{"used_percentage":10}}' | plain)
assert '[[ $out != *交接* && $out == Claude* ]]'

# 4. 百分比颜色分档（40 / 65 / 85），小数四舍五入，缺省按 0
color_of() { render "$(payload s-none "$1")"; }
dim=$'\033[2m ctx:'; yellow=$'\033[1;30;48;2;255;235;130m ctx:'
orange=$'\033[1;30;48;2;255;140;0m ctx:'; red=$'\033[1;97;48;2;180;30;30m ctx:'
out=$(color_of 39);   assert '[[ $out == *"${dim}39%"* ]]'
out=$(color_of 40);   assert '[[ $out == *"${yellow}40%"* ]]'
out=$(color_of 64.6); assert '[[ $out == *"${orange}65%"* ]]'
out=$(color_of 85);   assert '[[ $out == *"${red}85%"* ]]'
out=$(render '{"session_id":"s-none"}' | plain)
assert '[[ $out == *"ctx:0% "* ]]'

# 5. 目录名和 git 分支
repo="$test_home/my-repo"
git init -q -b feature/x "$repo"
out=$(render "$(payload s-none 10 "$repo")" | plain)
assert '[[ $out == *"| my-repo (feature/x)" ]]'
mkdir -p "$test_home/plain-dir"
out=$(render "$(payload s-none 10 "$test_home/plain-dir")" | plain)
assert '[[ $out == *"| plain-dir" ]]'

printf 'statusline: ok\n'
