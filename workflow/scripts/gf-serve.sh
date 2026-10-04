#!/usr/bin/env bash
# ============================================================================
# gf-serve.sh — 本地托管 Web 构建产物（自动定位目录，无需手动 cd）。
# 用法: workflow/scripts/gf-serve.sh [项目目录，默认 games/puzzle-core] [端口，默认 8000]
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="${1:-games/puzzle-core}"
PORT="${2:-8000}"
WEB_DIR="$ROOT/$PROJECT/build/web"

if [ ! -f "$WEB_DIR/index.html" ]; then
	echo "❌ 未找到 $WEB_DIR/index.html" >&2
	echo "   请先运行: workflow/scripts/gf-export.sh" >&2
	exit 1
fi

# 端口占用提示（脚本本身用多线程，卡死风险已消除）
if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
	echo "⚠️  端口 $PORT 已被占用。若是你之前启动的服务器，先 Ctrl+C 停掉；否则换端口：gf-serve.sh games/puzzle-core 8001" >&2
fi

PCK="$WEB_DIR/index.pck"
echo "=== 托管目录: $WEB_DIR ==="
if [ -f "$PCK" ]; then
	echo "=== index.pck 更新时间: $(date -r "$PCK" '+%Y-%m-%d %H:%M:%S') ==="
fi
echo "=== 浏览器打开: http://localhost:${PORT}（已禁用缓存，改完重新导出刷新即可）==="
echo "=== 停止: Ctrl+C ==="
cd "$WEB_DIR"
PY_SERVER="$SCRIPT_DIR/serve_nocache.py"
if [ -f "$PY_SERVER" ]; then
	exec python3 "$PY_SERVER" "$PORT" "$WEB_DIR"
else
	exec python3 -m http.server "$PORT"
fi
