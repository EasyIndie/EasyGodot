#!/usr/bin/env bash
# ============================================================================
# gf-test.sh — 运行游戏实例的所有测试套件（tests/test_*.gd）。
# 用法: workflow/scripts/gf-test.sh [项目目录，默认 games/puzzle-core]
# 退出码: 任一测试套件失败则非 0。
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="${1:-games/puzzle-core}"

cd "$ROOT"

fail=0
total=0
for f in "$PROJECT"/tests/test_*.gd; do
	[ -e "$f" ] || continue
	rel="${f#"$PROJECT"/}"
	total=$((total + 1))
	echo "=== $rel ==="
	"$SCRIPT_DIR/gf-run.sh" -p "$PROJECT" "res://$rel" 2>&1
	if [ $? -ne 0 ]; then
		fail=1
	fi
	echo ""
done

echo "=== 汇总: $total 个测试套件 ==="
if [ $fail -eq 0 ]; then
	echo "全部通过 ✅"
else
	echo "存在失败 ❌"
fi
exit $fail
