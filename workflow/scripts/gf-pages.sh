#!/usr/bin/env bash
# ============================================================================
# gf-pages.sh — 生成「GitHub Pages 可直接托管」的静态站点目录，并可一键推送到 gh-pages 分支。
#
# 为什么 Godot Web 能上 GitHub Pages：
#   GitHub Pages **不能自定义 HTTP 响应头**（无法发 COOP/COEP），
#   这只会影响 Godot 的**多线程**导出（需要 SharedArrayBuffer）。
#   本项目 export_presets.cfg 里 variant/thread_support=false（单线程），
#   因此无需跨源隔离，可直接托管；资源路径也是相对的，能放在 /<仓库>/ 子路径下。
#
# 用法:
#   workflow/scripts/gf-pages.sh [项目目录]              # 只生成 dist/pages/
#   workflow/scripts/gf-pages.sh [项目目录] --deploy     # 生成后强推 dist/pages/ 到 gh-pages
#
# 说明: --deploy 需要当前目录是 git 仓库且已配置 origin 远程。
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="games/puzzle-core"
DEPLOY=0

for a in "$@"; do
	case "$a" in
		--deploy) DEPLOY=1 ;;
		*) PROJECT="$a" ;;
	esac
done

cd "$ROOT"
STAGE="$ROOT/dist/pages"
WEB="$ROOT/$PROJECT/build/web"

echo "=== 1/3 导出 Web 构建 ==="
"$SCRIPT_DIR/gf-export.sh" "$PROJECT" web >/dev/null
echo "    完成"

echo "=== 2/3 生成 Pages 站点目录 ==="
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -r "$WEB/." "$STAGE/"
# Jekyll 会处理/忽略部分文件，直接关掉最省事
touch "$STAGE/.nojekyll"
echo "    完成: $STAGE"
echo "    内容:"
( cd "$STAGE" && find . -type f | sort | sed 's/^/      /' )

echo "=== 3/3 部署 ==="
if [ "$DEPLOY" -eq 0 ]; then
	echo "    未指定 --deploy，仅生成目录。"
	echo ""
	echo "    两种发布方式任选其一："
	echo "    A) 提交本目录并在仓库设置里选择分支（把 dist/pages 内容放到仓库的 docs/ 或用 gh-pages 分支）"
	echo "    B) 用 GitHub Actions 自动构建部署：推送到 main 后由 .github/workflows/pages.yml 完成"
	echo "       仓库 Settings → Pages → Source 选择 \"GitHub Actions\""
	echo ""
	echo "    本地预览（模拟 Pages 的静态托管，无任何自定义响应头）："
	echo "      python3 -m http.server 8080 --directory $STAGE"
	echo "      → http://localhost:8080"
	exit 0
fi

if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	echo "    ✗ 当前不是 git 仓库，无法部署。请先 git init 并配置 origin。" >&2
	exit 2
fi
ORIGIN="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
if [ -z "$ORIGIN" ]; then
	echo "    ✗ 未配置 origin 远程仓库，无法部署。" >&2
	exit 2
fi

cd "$STAGE"
git init -q
git checkout -q -B gh-pages
git add -A
git -c user.name="gf-pages" -c user.email="gf-pages@local" commit -qm "deploy: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git remote add origin "$ORIGIN" 2>/dev/null || git remote set-url origin "$ORIGIN"
git push -f origin gh-pages

echo "    完成 → $ORIGIN (gh-pages)"
echo "    仓库 Settings → Pages → Source 选 \"Deploy from a branch\" → gh-pages / (root)"
