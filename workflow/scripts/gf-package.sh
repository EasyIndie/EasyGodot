#!/usr/bin/env bash
# ============================================================================
# gf-package.sh — 打包「Steam Demo」分发包（Windows + Linux，可只打一个平台）。
#
# 产出 dist/<name>-steam-demo-dir/：
#   steam_appid.txt            本地调试用（Steam 客户端按此 appid 启动）
#   windows/<name>.exe + .pck  可直接双击运行（无需 Steam）
#   linux/<name>.x86_64 + .pck 可直接运行
#   steamcmd/app_build_*.vdf   SteamPipe 上传配置模板（改完 appid 即可 steamcmd 上传）
#   README.txt                 运行/上传/上架说明
# 再打成 dist/<name>-steam-demo.zip
#
# 用法: workflow/scripts/gf-package.sh [项目目录] [--appid N] [--platforms "windows linux"]
#       --appid 默认 480（Valve 的 Spacewar，官方指定的联调测试 appid；正式上架请换成自己的）
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="games/puzzle-core"
APPID="480"
PLATFORMS="windows linux"

while [ $# -gt 0 ]; do
	case "$1" in
		--appid) APPID="$2"; shift 2 ;;
		--platforms) PLATFORMS="$2"; shift 2 ;;
		*) PROJECT="$1"; shift ;;
	esac
done

NAME="$(basename "$PROJECT")"
VERSION="$(grep -m1 'config/version=' "$ROOT/$PROJECT/project.godot" | cut -d'"' -f2 || echo "0.0.0")"
DIST="$ROOT/dist"
PKG="$DIST/$NAME-steam-demo-dir"
ZIP="$DIST/$NAME-steam-demo.zip"

cd "$ROOT"

echo "=== 1/4 导出构建（$PLATFORMS）==="
"$SCRIPT_DIR/gf-export.sh" "$PROJECT" $PLATFORMS >/dev/null
echo "    完成"

echo "=== 2/4 组装分发包 ==="
rm -rf "$PKG"
mkdir -p "$PKG/steamcmd"
echo "$APPID" > "$PKG/steam_appid.txt"

copy_platform() {
	local plat="$1" src="$2" bin="$3"
	mkdir -p "$PKG/$plat"
	cp "$ROOT/$PROJECT/$src/$bin" "$PKG/$plat/"
	cp "$ROOT/$PROJECT/$src/$NAME.pck" "$PKG/$plat/"
	# 每个平台目录也放一份 appid，方便单独拷贝出去调试
	cp "$PKG/steam_appid.txt" "$PKG/$plat/steam_appid.txt"
	# 上传配置：contentroot / buildoutput 均写成**绝对路径**，避免 SteamPipe 相对路径歧义
	cat > "$PKG/steamcmd/app_build_$plat.vdf" <<EOF
// SteamPipe 上传配置模板 —— 用法：
//   steamcmd +login <账号> +run_app_build "$PKG/steamcmd/app_build_$plat.vdf" +quit
// 注意：appid / depot id 必须替换成自己 Steamworks 后台的真实值。
"appbuild"
{
	"appid" "$APPID"
	"desc" "$NAME $VERSION ($plat)"
	"buildoutput" "$DIST/output_$plat"
	"contentroot" "$PKG/$plat"
	"setlive" ""
	"preview" "0"
	"local" ""
	"depots"
	{
		"$APPID"
		{
			"FileMapping"
			{
				"LocalPath" "*"
				"DepotPath" "."
				"recursive" "1"
			}
			"FileExclusion" "steam_appid.txt"
		}
	}
}
EOF
}

for p in $PLATFORMS; do
	case "$p" in
		windows) copy_platform "windows" "build/windows" "$NAME.exe" ;;
		linux)   copy_platform "linux" "build/linux" "$NAME.x86_64" ;;
		*) echo "未知平台: $p" >&2; exit 2 ;;
	esac
done

cat > "$PKG/README.txt" <<EOF
$NAME — Steam Demo 分发包
版本 $VERSION    AppID（占位）: $APPID

■ 直接运行（不需要 Steam）
  Windows : windows/$NAME.exe
  Linux   : linux/$NAME.x86_64   （chmod +x 后运行）

■ 通过 Steam 客户端运行（本地联调）
  把 steam_appid.txt 与可执行文件放在同一目录，从 Steam 客户端启动该 appid 即可。

■ 上传到 Steam（SteamPipe）
  1. 在 Steamworks 后台创建 App / Depot，拿到真实 appid 与 depot id
  2. 替换 steamcmd/app_build_*.vdf 里的 "$APPID"
  3. 执行：
       steamcmd +login <账号> +run_app_build <绝对路径>/app_build_windows.vdf +quit
  4. 在后台把 depot 挂到对应启动项（Windows / Linux 各一条）

■ 说明
  - 构建产物由 workflow/scripts/gf-export.sh 生成，可随时重新执行本脚本刷新。
  - 每个平台的 .pck 与可执行文件必须放在同一目录。
  - Steamworks SDK（成就 / 云存档 / 排行榜）尚未接入，见 workflow/docs/07-mvp-status.md。
EOF

echo "    完成: $PKG"

echo "=== 3/4 打 zip ==="
rm -f "$ZIP"
( cd "$DIST" && \
  if command -v zip >/dev/null 2>&1; then
	zip -qr "$(basename "$ZIP")" "$(basename "$PKG")"
  elif command -v python3 >/dev/null 2>&1; then
	python3 -m zipfile -c "$(basename "$ZIP")" "$(basename "$PKG")"
  else
	tar czf "$(basename "$ZIP").tar.gz" "$(basename "$PKG")"
  fi )
if [ -f "$ZIP" ]; then
	echo "    完成: $ZIP ($(du -h "$ZIP" | cut -f1))"
else
	echo "    完成: $ZIP.tar.gz ($(du -h "$ZIP.tar.gz" | cut -f1))（本机无 zip，退回 tar.gz）"
fi

echo "=== 4/4 内容清单 ==="
( cd "$PKG" && find . -type f | sort | sed 's/^/    /' )
echo "=== 打包完成 ==="
