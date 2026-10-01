#!/usr/bin/env bash
# ============================================================================
# gf-export.sh — 一键导出构建，复用 export_presets.cfg。
#
# 依赖：已安装 Godot 导出模板（~/.local/share/godot/export_templates/<版本>/）
# 用法: workflow/scripts/gf-export.sh [项目目录，默认 games/puzzle-core] [平台...]
#       平台可选：web linux windows android android-apk ios
#       （默认 web linux windows）
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

# Android 前置检查：Godot 的 SDK / JDK 路径存在 **编辑器设置** 里（不是工程设置，也不读环境变量），
# 所以这里先查一遍并给出可执行的修复命令，而不是让导出在半路报一句难懂的错。
_android_precheck() {
	local kind="$1"
	local settings="${GODOT_EDITOR_SETTINGS:-$HOME/.config/godot/editor_settings-4.tres}"
	local sdk_tmp="" java_tmp=""
	[ -f "$settings" ] && {
		sdk_tmp="$(grep -o 'android/android_sdk_path = "[^"]*"' "$settings" | sed 's/.*= "//; s/"$//')"
		java_tmp="$(grep -o 'android/java_sdk_path = "[^"]*"' "$settings" | sed 's/.*= "//; s/"$//')"
	}
	if [ -z "${sdk_tmp:-}" ] && [ -z "${ANDROID_SDK_ROOT:-}" ]; then
		echo "!! 没有配置 Android SDK 路径，导出会失败。" >&2
		echo "   1) 安装 Android SDK（cmdline-tools + platform-tools + build-tools）与 OpenJDK 17" >&2
		echo "   2) 写进编辑器设置：" >&2
		echo "      $settings" >&2
		echo '      export/android/android_sdk_path = "<你的 Android SDK 目录>"' >&2
		echo '      export/android/java_sdk_path  = "<你的 JDK17 目录>"' >&2
		echo "   3) 或用 workflow/scripts/gf-android-env.sh 自动写入（见 09-mobile-distribution.md）" >&2
		exit 4
	fi
	if [ "$kind" = "aab" ] && [ ! -d "$PROJECT/android/build" ]; then
		echo "!! 还没有安装 Android 构建模板（res://android/build），AAB 需要它。" >&2
		echo "   修复：$GODOT --headless --path $PROJECT --install-android-build-template" >&2
		exit 5
	fi
}

for p in "${PLATFORMS[@]}"; do
	case "$p" in
		web)
			mkdir -p "$PROJECT/build/web"
			echo "=== 导出 Web ==="
			# 先把 head_include 源文件同步进 export_presets.cfg（见 gf-web-inject.sh 的说明）
			"$SCRIPT_DIR/gf-web-inject.sh" "$PROJECT"
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
		android|aab)
			# Google Play 现在只收 AAB（新应用必须用 AAB 才能上架）。
			# AAB 需要 Gradle 构建 → 必须先装 Android 构建模板 + 配好 Android SDK / JDK
			# （见 workflow/docs/09-mobile-distribution.md）。
			echo "=== 导出 Android (AAB) ==="
			_android_precheck aab
			mkdir -p "$PROJECT/build/android"
			"$GODOT" --headless --no-header --path "$PROJECT" --export-release "Android (AAB)" "build/android/$NAME.aab"
			;;
		android-apk)
			# 本机装到手机上试玩用的 APK（debug 签名）。
			echo "=== 导出 Android (APK, debug) ==="
			_android_precheck apk
			mkdir -p "$PROJECT/build/android"
			"$GODOT" --headless --no-header --path "$PROJECT" --export-debug "Android (APK)" "build/android/$NAME.apk"
			;;
		ios)
			# iOS **只能在 macOS 上导出**（Godot 官方文档明确要求 macOS + Xcode）。
			# 这里不假装能跨平台：在非 macOS 上直接给出清晰指引，避免出现“导出成功但产物不可用”。
			echo "=== 导出 iOS ==="
			if [ "$(uname -s)" != "Darwin" ]; then
				echo "!! iOS 导出必须在 macOS 上执行（Godot 官方要求 macOS + Xcode）。" >&2
				echo "   可选方案：把仓库放到 macOS 上构建 / 用 GitHub Actions 的 macos runner（公开仓库免费）。" >&2
				echo "   preset 已就绪（iOS / com.easyindie.puzzlecore），在 macOS 上直接跑同一条命令即可。" >&2
				echo "   详见 workflow/docs/09-mobile-distribution.md" >&2
				exit 3
			fi
			mkdir -p "$PROJECT/build/ios"
			"$GODOT" --headless --no-header --path "$PROJECT" --export-release "iOS" "build/ios/$NAME.ipa"
			;;
		*)
			echo "未知平台: $p（可选 web / linux / windows / android / android-apk / ios）" >&2
			exit 2
			;;
	esac
done

echo "=== 导出完成 ==="
echo "Web:     $PROJECT/build/web/"
echo "Linux:   $PROJECT/build/linux/$NAME.x86_64"
echo "Windows: $PROJECT/build/windows/$NAME.exe"
