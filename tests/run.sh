#!/usr/bin/env bash
# 依次运行 tests/ 下的全部测试，任一失败则以非零退出。
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
failed=0
for t in "$here"/*.sh; do
  case "$(basename "$t")" in run.sh|lib.sh) continue ;; esac
  bash "$t" || failed=1
done
exit "$failed"
