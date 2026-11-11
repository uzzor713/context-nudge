# 测试公共函数。由各测试脚本 source。
# macOS 自带的 bash 3.2 里，[[ ]] 和 (( )) 失败不会触发 set -e，所以断言一律显式检查并退出。

_fail() { # $1 = 调用层级, $2 = 说明
  printf 'FAIL %s:%s: %s\n' "$(basename "${BASH_SOURCE[$1]}")" "${BASH_LINENO[$(($1 - 1))]}" "$2" >&2
  exit 1
}

# assert '<shell 条件>'，例如 assert '(( level == 1 ))'、assert '[[ -z $out ]]'
assert() { eval "$1" || _fail 2 "$1"; }

# assert_json "$json" '<jq 过滤器>'：过滤器结果必须为真
assert_json() { jq -e "$2" <<<"$1" >/dev/null 2>&1 || _fail 2 "jq $2 <<< ${1:-<空>}"; }

# assert_empty "$out"
assert_empty() { [[ -z "$1" ]] || _fail 2 "期望无输出，实际：$1"; }
