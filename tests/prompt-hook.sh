#!/usr/bin/env bash
# prompt hook：档位判定、每档只提醒一次、斜杠命令不插话、基线取值、窗口判定、异常输入。
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

test_home=$(mktemp -d)
trap 'rm -rf "$test_home"' EXIT
script="$here/../scripts/prompt-hook-context-nudge.sh"
settings="$test_home/.claude/settings.json"
mkdir -p "$test_home/.claude"
printf '%s\n' '{"env":{"CLAUDE_CODE_DISABLE_1M_CONTEXT":"1"}}' > "$settings"

# usage 行：$1 = 总 token 数（窗口 200k，1% = 2000）
usage() { printf '{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":%d}}}\n' "$(( $1 - 1 ))"; }
boundary() { printf '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","postTokens":%d}}\n' "$1"; }
# 清掉会影响窗口判定的环境变量，避免测试结果随运行者的 shell 变化；额外环境变量用 RUN_ENV 传入。
hook() { # stdin = payload
  # shellcheck disable=SC2086
  env -u CLAUDE_CODE_DISABLE_1M_CONTEXT -u ANTHROPIC_MODEL HOME="$test_home" ${RUN_ENV:-} bash "$script" 2>/dev/null
}
run() { # $1 = session, $2 = transcript, $3 = prompt（可选）
  jq -nc --arg s "$1" --arg t "$2" --arg p "${3:-继续}" '{session_id:$s, transcript_path:$t, prompt:$p}' | hook
}
state() { # shellcheck disable=SC1090
  . "$test_home/.claude/state/context-nudge-$1.state"; }

# 1. 没 compact 过：用量再高也不提醒
t="$test_home/no-compact.jsonl"
{ usage 100000; usage 180000; } > "$t"
assert_empty "$(run no-compact "$t")"
state no-compact
assert '(( level == 0 && compact_count == 0 && ctx_pct == 90 ))'

# 2. compact 一次且基线低：compact 仍然有效，不提醒
t="$test_home/low-floor.jsonl"
{ usage 170000; boundary 15000; usage 20000; usage 120000; } > "$t"
assert_empty "$(run low-floor "$t")"
state low-floor
assert '(( level == 0 && compact_count == 1 && floor_pct == 10 && ctx_pct == 60 ))'

# 3. compact 一次但基线 ≥30%：第一档，只提醒一次
t="$test_home/high-floor.jsonl"
{ usage 170000; boundary 50000; usage 70000; usage 90000; } > "$t"
out=$(run high-floor "$t")
assert_json "$out" '.hookSpecificOutput | .hookEventName == "UserPromptSubmit" and (.additionalContext | contains("基线占窗口 35%，当前 45%"))'
assert_json "$out" '.systemMessage | contains("已压缩 1 次") and contains("建议 /handoff")'
assert_empty "$(run high-floor "$t")"
state high-floor
assert '(( level == 1 && reminded_level == 1 && reminder_count == 1 && trigger_count == 2 ))'
assert '(( last_reminder_at > 0 && last_trigger_at >= last_reminder_at ))'

# 4. 基线取 compact 后第一次真实请求；还没有请求时退回 postTokens
t="$test_home/post-only.jsonl"
{ usage 170000; boundary 64000; } > "$t"
run post-only "$t" >/dev/null
state post-only
assert '(( floor_pct == 32 && ctx_pct == 32 && level == 1 ))'
usage 30000 >> "$t"
run post-only "$t" >/dev/null
state post-only
assert '(( floor_pct == 15 ))'

# 5. 第二次 compact：基线虽低也进第一档；第三次升到第二档，再次提醒
t="$test_home/many.jsonl"
{ usage 170000; boundary 10000; usage 20000; usage 170000; boundary 12000; usage 24000; } > "$t"
assert_json "$(run many "$t")" '.systemMessage | contains("已压缩 2 次")'
{ usage 170000; boundary 14000; usage 28000; } >> "$t"
assert_json "$(run many "$t")" '.hookSpecificOutput.additionalContext | contains("立即 /handoff")'
assert_empty "$(run many "$t")"
state many
assert '(( level == 2 && compact_count == 3 && floor_pct == 14 && reminder_count == 2 ))'

# 6. 斜杠命令不插话，也不消耗本档提醒
t="$test_home/slash.jsonl"
{ usage 170000; boundary 80000; usage 80000; } > "$t"
assert_empty "$(run slash "$t" /handoff)"
state slash
assert '(( level == 1 && reminded_level == 0 ))'
assert_json "$(run slash "$t")" '.systemMessage | length > 0'

# 7. 对话内容里出现 compact_boundary 字样不算一次 compact
t="$test_home/mention.jsonl"
{ usage 50000
  # 嵌套在工具结果里的同名字段能通过 grep 粗筛，必须被 jq 那一层排除
  printf '%s\n' '{"type":"user","toolUseResult":{"type":"system","subtype":"compact_boundary"}}'
  usage 160000; } > "$t"
assert_empty "$(run mention "$t")"
state mention
assert '(( compact_count == 0 && ctx_pct == 80 ))'

# 8. 基线 ≥50% 直接进第二档，只提醒一次
t="$test_home/jump.jsonl"
{ usage 170000; boundary 110000; usage 110000; } > "$t"
assert_json "$(run jump "$t")" '.systemMessage | contains("立即 /handoff")'
assert_empty "$(run jump "$t")"
state jump
assert '(( level == 2 && reminded_level == 2 && reminder_count == 1 ))'

# 9. 子代理消息和合成消息不计入基线和当前用量
t="$test_home/sidechain.jsonl"
{ usage 170000; boundary 10000
  printf '%s\n' '{"type":"assistant","isSidechain":true,"message":{"model":"claude-opus-5-5","usage":{"input_tokens":150000}}}'
  printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":150000}}}'
  usage 20000
  printf '%s\n' '{"type":"assistant","isSidechain":true,"message":{"model":"claude-opus-5-5","usage":{"input_tokens":190000}}}'
  printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":190000}}}'
} > "$t"
assert_empty "$(run sidechain "$t")"
state sidechain
assert '(( floor_pct == 10 && ctx_pct == 10 && level == 0 ))'

# 10. 窗口判定：默认 200k；settings 的 model 带 [1m]、ANTHROPIC_MODEL 带 [1m]、或用量超过 200k 时按 1M；
#     CLAUDE_CODE_DISABLE_1M_CONTEXT（进程环境或 settings 的 env 段）强制 200k
t="$test_home/window.jsonl"
{ usage 170000; boundary 100000; usage 100000; } > "$t"
printf '%s\n' '{}' > "$settings"
run window-default "$t" >/dev/null; state window-default
assert '(( floor_pct == 50 ))'
printf '%s\n' '{"model":"opus[1m]"}' > "$settings"
run window-setting "$t" >/dev/null; state window-setting
assert '(( floor_pct == 10 && level == 0 ))'
printf '%s\n' '{}' > "$settings"
RUN_ENV='ANTHROPIC_MODEL=claude-opus-5-5[1m]' run window-env "$t" >/dev/null; state window-env
assert '(( floor_pct == 10 ))'
printf '%s\n' '{"model":"opus[1m]"}' > "$settings"
RUN_ENV='CLAUDE_CODE_DISABLE_1M_CONTEXT=1' run window-disable "$t" >/dev/null; state window-disable
assert '(( floor_pct == 50 ))'
printf '%s\n' '{"model":"opus[1m]","env":{"CLAUDE_CODE_DISABLE_1M_CONTEXT":"1"}}' > "$settings"
run window-disable-settings "$t" >/dev/null; state window-disable-settings
assert '(( floor_pct == 50 ))'
printf '%s\n' '{}' > "$settings"
t2="$test_home/window-big.jsonl"
{ usage 400000; boundary 300000; usage 300000; } > "$t2"
run window-big "$t2" >/dev/null; state window-big
assert '(( floor_pct == 30 && ctx_pct == 30 ))'
printf '%s\n' '{"env":{"CLAUDE_CODE_DISABLE_1M_CONTEXT":"1"}}' > "$settings"

# 11. transcript 缺失、不存在或有坏行时安全退出
out=$(jq -nc '{session_id:"no-transcript"}' | hook); rc=$?
assert '(( rc == 0 ))'
assert_empty "$out"
state no-transcript
assert '(( level == 0 && trigger_count == 1 ))'
out=$(run missing-file "$test_home/does-not-exist.jsonl"); rc=$?
assert '(( rc == 0 ))'
assert_empty "$out"
t="$test_home/garbage.jsonl"
{ printf '%s\n' 'not json' '{"type":"system","subtype":"compact_boundary"' '[]'
  usage 170000; boundary 70000; printf '%s\n' '{broken'; usage 70000; } > "$t"
assert_json "$(run garbage "$t")" '.hookSpecificOutput.hookEventName == "UserPromptSubmit"'
state garbage
assert '(( compact_count == 1 && floor_pct == 35 && level == 1 ))'

# 12. 状态按 session 隔离
assert '[[ -f $test_home/.claude/state/context-nudge-high-floor.state && -f $test_home/.claude/state/context-nudge-jump.state ]]'
state low-floor
assert '(( level == 0 && trigger_count == 1 ))'

printf 'prompt-hook: ok\n'
