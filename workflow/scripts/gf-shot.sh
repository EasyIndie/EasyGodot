#!/usr/bin/env bash
# ============================================================================
# gf-shot.sh — 渲染指定关卡并截图（视觉验证 / AI 视觉回归）。
# 需要显示环境（WSLg / X11）。用法:
#   gf-shot.sh [项目目录] [关卡 res 路径] [输出 PNG 绝对路径]
# 默认: games/puzzle-core, res://levels/level_01.json, <项目>/_shot.png
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GODOT="$SCRIPT_DIR/../godot-bin/godot"
PROJECT="${1:-games/puzzle-core}"
LEVEL="${2:-res://levels/level_01.json}"
OUT="${3:-$ROOT/$PROJECT/_shot.png}"

export GODOT_SILENCE_ROOT_WARNING=1
export DISPLAY="${DISPLAY:-:0}"

cd "$ROOT"
"$GODOT" --path "$PROJECT" --resolution 960x600 -s res://tools/screenshot.gd -- "$LEVEL" "$OUT" 2>&1 \
	| grep -E '"status"|ERROR|SCRIPT'
echo "截图已保存: $OUT"
