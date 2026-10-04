#!/usr/bin/env bash
# 测试 → 关卡质检 → 可选 Web 导出；仅生成首发候选，不部署。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="games/puzzle-core"
WEB=0
for arg in "$@"; do
	case "$arg" in
		--web) WEB=1 ;;
		-*) echo "未知参数: $arg" >&2; exit 2 ;;
		*) PROJECT="$arg" ;;
	esac
done
cd "$ROOT"
"$SCRIPT_DIR/gf-test.sh" "$PROJECT"
"$SCRIPT_DIR/gf-run.sh" -p "$PROJECT" res://tools/validate_levels.gd
if [ "$WEB" -eq 1 ]; then
	"$SCRIPT_DIR/gf-export.sh" "$PROJECT" web
	[ -s "$PROJECT/build/web/index.html" ]
	[ -s "$PROJECT/build/web/index.pck" ]
	[ -s "$PROJECT/build/web/index.wasm" ]
	[ -s "$PROJECT/build/web/privacy.html" ]
fi
echo "首发候选自动检查通过；真机与商店验收见 workflow/docs/11-first-release-plan.md。"
