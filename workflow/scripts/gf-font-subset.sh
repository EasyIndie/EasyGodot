#!/usr/bin/env bash
# ============================================================================
# gf-font-subset.sh — 按项目**实际用字**裁剪内置字体（体积 + 运行时内存优化）。
#
# 为什么需要：
#   Noto Sans SC 完整字体 16MB+。Web 端用户要下载它；移动端还要常驻内存，
#   而 iOS Safari 对单个标签页的内存非常敏感（WebGL 上下文被回收的常见诱因）。
#   本项目 UI 文案只用到几百个字符 → 子集化后约 300KB（缩小约 50 倍）。
#
# 做法：从会渲染 UI 文本的源码里抽取所有字符，用 HarfBuzz（subset-font）裁剪。
# 守卫：tests/test_font.gd 会扫描同样的源码，确保每个字符都有字形
#       （避免新增文案静默变成「豆腐块」）。
#
# 用法:
#   workflow/scripts/gf-font-subset.sh [项目目录，默认 games/puzzle-core]
#   FULL_FONT=/path/to/NotoSansSC-Regular.otf workflow/scripts/gf-font-subset.sh
#
# 完整字体查找顺序:
#   1) $FULL_FONT 环境变量
#   2) .tools/fonts/NotoSansSC-Regular.otf
#   3) 自动下载 Noto CJK 官方 SubsetOTF（约 8MB）
#
# 依赖: python3（抽字符）、node + npm（subset-font，缺则自动安装到 .tools/fontsubset）
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="${1:-games/puzzle-core}"
FONT="$ROOT/$PROJECT/fonts/NotoSansSC-Regular.otf"
WORK="$ROOT/.tools/fontsubset"
FULL="${FULL_FONT:-$ROOT/.tools/fonts/NotoSansSC-Regular.otf}"
UPSTREAM="https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf"

cd "$ROOT"

# ── node 解析（WSL 里 node 可能只在 Windows 侧）─────────────────────────────
NODE_BIN=""
for c in node node.exe "/mnt/c/Program Files/nodejs/node.exe"; do
	if command -v "$c" >/dev/null 2>&1; then NODE_BIN="$(command -v "$c")"; break; fi
	if [ -x "$c" ]; then NODE_BIN="$c"; break; fi
done
if [ -z "$NODE_BIN" ]; then
	echo "✗ 找不到 node。请安装 Node.js 后重试。" >&2
	exit 2
fi
# Windows 版 node 需要 Windows 风格路径
native() {
	if [[ "$NODE_BIN" == *.exe ]]; then wslpath -w "$1"; else printf '%s' "$1"; fi
}
NPM_BIN=""
for c in npm npm.cmd "/mnt/c/Program Files/nodejs/npm.cmd"; do
	if command -v "$c" >/dev/null 2>&1; then NPM_BIN="$(command -v "$c")"; break; fi
	if [ -x "$c" ]; then NPM_BIN="$c"; break; fi
done

echo "=== 1/4 准备完整字体 ==="
if [ ! -f "$FULL" ]; then
	echo "    本地无完整字体，下载官方 SubsetOTF ..."
	mkdir -p "$(dirname "$FULL")"
	curl -fsSL -o "$FULL" "$UPSTREAM"
fi
echo "    来源: $FULL ($(du -h "$FULL" | cut -f1))"

echo "=== 2/4 准备 subset-font ==="
mkdir -p "$WORK"
if [ ! -d "$WORK/node_modules/subset-font" ]; then
	if [ -z "$NPM_BIN" ]; then
		echo "✗ 未安装 subset-font 且找不到 npm。请先执行: cd $WORK && npm install subset-font" >&2
		exit 2
	fi
	echo '{"name":"gf-fontsubset","private":true}' > "$WORK/package.json"
	( cd "$WORK" && "$NPM_BIN" install subset-font --no-audit --no-fund >/dev/null 2>&1 )
fi
echo "    已就绪: $WORK/node_modules/subset-font"

echo "=== 3/4 抽取项目实际用字 ==="
GLYPHS="$WORK/glyphs.txt"
python3 - "$ROOT" "$PROJECT" "$GLYPHS" <<'PY'
import io, glob, os, re, sys
root, project, out = sys.argv[1], sys.argv[2], sys.argv[3]
# ── UI 文案来源（必须与 tests/test_font.gd 的扫描范围一致！）────────────
# 只取字符串字面量：注释与标识符永远不会被渲染，不该逼迫字体包含它们里面的
# 生僻符号（如注释里的 ∘、—— 未必存在于 Noto Sans SC）。
STRING_RE = re.compile(r'"[^"\n]*"|\'[^\'\n]*\'')
# core/ 必须包含：它虽然不画界面，但会提供**显示用文案**（如 shapes.gd 的形状名
# 「骨牌」）。真实踩过：把形状名从 meta/ 搬进 core/ 之后，扫描范围没跟着变，
# 这两个字形被移出子集，卡片上直接变成豆腐块。
UI_SOURCES = ["scenes/*.gd", "meta/*.gd", "core/*.gd", "*.tscn", "*.godot"]

chars = set(chr(c) for c in range(0x20, 0x7F))     # ASCII 可见字符打底
base = os.path.join(root, project)
files = []
for pat in UI_SOURCES:
    files += sorted(glob.glob(os.path.join(base, pat)))
for f in files:
    text = io.open(f, encoding="utf-8", errors="ignore").read()
    for lit in STRING_RE.findall(text):
        chars.update(lit)
# 关卡 JSON 目前无文案，但一旦加上就应被覆盖，故全量扫描（JSON 无注释）
for f in sorted(glob.glob(os.path.join(base, "levels/*.json"))):
    files.append(f)
    chars.update(io.open(f, encoding="utf-8", errors="ignore").read())
io.open(out, "w", encoding="utf-8").write("".join(sorted(chars)))
cjk = sum(1 for c in chars if ord(c) > 0x2000)
print("    扫描 %d 个文件 -> %d 个字符（其中 CJK/符号 %d）" % (len(files), len(chars), cjk))
PY

echo "=== 4/4 子集化 ==="
DRIVER="$WORK/subset-run.cjs"
cat > "$DRIVER" <<'JS'
const subsetFont = require('subset-font');
const fs = require('fs');
(async () => {
  const [, , inp, out, textFile] = process.argv;
  const text = fs.readFileSync(textFile, 'utf8');
  const src = fs.readFileSync(inp);
  const buf = await subsetFont(src, text, { preserveNameIds: [1, 2, 3, 4, 5, 6] });
  fs.writeFileSync(out, buf);
  console.log(`    ${src.length} -> ${buf.length} bytes (${(src.length / buf.length).toFixed(1)}x smaller)`);
})().catch((e) => { console.error('✗ 子集化失败:', e); process.exit(1); });
JS

TMP_OUT="$FONT.tmp"
"$NODE_BIN" "$(native "$DRIVER")" "$(native "$FULL")" "$(native "$TMP_OUT")" "$(native "$GLYPHS")"
mv "$TMP_OUT" "$FONT"

# 关键：Godot 运行时读的是 .godot/imported/ 里的导入缓存，而 headless 运行
# 不会自动重新导入。不刷新就会出现「字体明明换了、游戏里还是旧字形」。
GODOT="$SCRIPT_DIR/../godot-bin/godot"
if [ -x "$GODOT" ]; then
	"$GODOT" --headless --no-header --path "$PROJECT" --import >/dev/null 2>&1 || true
fi

echo "=== 完成 ==="
echo "    字体: $FONT ($(du -h "$FONT" | cut -f1))"
echo "    校验: workflow/scripts/gf-run.sh -p $PROJECT res://tests/test_font.gd"
