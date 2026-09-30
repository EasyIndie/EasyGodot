#!/usr/bin/env bash
# ============================================================================
# gf-export.sh — 一键导出构建（Web + Linux + Windows），复用 export_presets.cfg。
#
# 依赖：已安装 Godot 导出模板（~/.local/share/godot/export_templates/<版本>/）
# 用法: workflow/scripts/gf-export.sh [项目目录，默认 games/puzzle-core] [平台...]
#       平台可选：web linux windows（默认三个都导）
# 退出码: 任一平台导出失败则非 0。
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GODOT="$SCRIPT_DIR/../godot-bin/godot"
PROJECT="${1:-games/puzzle-core}"
NAME="$(basename "$PROJECT")"

shift || true
PLATFORMS=("$@")
if [ ${#PLATFORMS[@]} -eq 0 ]; then
	PLATFORMS=(web linux windows)
fi

cd "$ROOT"
export GODOT_SILENCE_ROOT_WARNING=1

for p in "${PLATFORMS[@]}"; do
	case "$p" in
		web)
			mkdir -p "$PROJECT/build/web"
			echo "=== 导出 Web ==="
			"$GODOT" --headless --no-header --path "$PROJECT" --export-release "Web" "build/web/index.html"
			# 附带静态辅助页（如 WebGL 诊断页）到站点根目录，随 Pages 一起发布
			if [ -d "$SCRIPT_DIR/../web" ]; then
				cp -r "$SCRIPT_DIR/../web/." "$PROJECT/build/web/"
				echo "    已附带静态页: $(ls "$SCRIPT_DIR/../web" | tr '\n' ' ')"
			fi
			;;
		linux)
			mkdir -p "$PROJECT/build/linux"
			echo "=== 导出 Linux ==="
			"$GODOT" --headless --no-header --path "$PROJECT" --export-release "Linux" "build/linux/$NAME.x86_64"
			;;
		windows)
			mkdir -p "$PROJECT/build/windows"
			echo "=== 导出 Windows ==="
			"$GODOT" --headless --no-header --path "$PROJECT" --export-release "Windows" "build/windows/$NAME.exe"
			;;
		*)
			echo "未知平台: $p（可选 web / linux / windows）" >&2
			exit 2
			;;
	esac
done

echo "=== 导出完成 ==="
echo "Web:     $PROJECT/build/web/"
echo "Linux:   $PROJECT/build/linux/$NAME.x86_64"
echo "Windows: $PROJECT/build/windows/$NAME.exe"
