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
	# 捕获输出后**同时**检查三件事（不是只看退出码）：
	#   1) 退出码
	#   2) 套件自报的 failures
	#   3) 输出里有没有 SCRIPT ERROR / 载入失败
	# 第 3 条是真实踩过的坑：GDScript 的运行期错误会让协程**静默中断**，
	# 套件照样打印 status:ok（断言数变少但没失败），CI 全绿却什么都没测。
	# 所以「有没有报错」必须由流水线来判，不能只信套件自己的结论。
	out="$("$SCRIPT_DIR/gf-run.sh" -p "$PROJECT" "res://$rel" 2>&1)"
	rc=$?
	echo "$out"
	if [ $rc -ne 0 ]; then
		fail=1
	fi
	if echo "$out" | grep -qE 'SCRIPT ERROR|Failed to load script|Parse Error'; then
		echo "!!! $rel 有脚本错误（上面的 SCRIPT ERROR）"
		fail=1
	fi
	if echo "$out" | grep -q '"failures":0'; then
		:
	elif echo "$out" | grep -q '"failures":'; then
		echo "!!! $rel 自报有失败断言"
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
