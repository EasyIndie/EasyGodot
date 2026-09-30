#!/usr/bin/env bash
# ============================================================================
# gf-web-inject.sh — 把 workflow/web/head_include.html 写进 export_presets.cfg
#
# 为什么要有这一步：Godot 的导出预设只能把 head 注入代码存成**一行转义字符串**，
# 直接手改那一行极易出错（曾经用带 \n 的替换写出过字面换行，把 cfg 弄坏）。
# 于是把它变成「源文件 + 生成」：
#   源: workflow/web/head_include.html      （可读、可 diff）
#   目标: export_presets.cfg 的 html/head_include="..."
#
# 用法: workflow/scripts/gf-web-inject.sh [项目目录]
# 退出码: 找不到源文件或预设行则非 0。
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$SCRIPT_DIR/../web/head_include.html"
PROJECT="${1:-games/puzzle-core}"
CFG="$ROOT/$PROJECT/export_presets.cfg"

[ -f "$SRC" ] || { echo "缺少 $SRC" >&2; exit 1; }
[ -f "$CFG" ] || { echo "缺少 $CFG" >&2; exit 1; }

python3 - "$SRC" "$CFG" <<'PY'
import io, sys
src, cfg = sys.argv[1], sys.argv[2]
html = io.open(src, encoding="utf-8").read()
# Godot 的 cfg 字符串转义：反斜杠、双引号、换行
esc = html.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
lines = io.open(cfg, encoding="utf-8").read().split("\n")
out, hit = [], 0
for line in lines:
    if line.startswith("html/head_include="):
        out.append('html/head_include="%s"' % esc)
        hit += 1
    else:
        out.append(line)
if hit == 0:
    sys.stderr.write("export_presets.cfg 里没有 html/head_include= 这一行\n")
    sys.exit(1)
io.open(cfg, "w", encoding="utf-8").write("\n".join(out))
print("    已注入 head_include: %d 行 / %d 字节" % (html.count("\n") + 1, len(html)))
PY
