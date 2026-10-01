#!/usr/bin/env bash
# ============================================================================
# gf-android-verify.sh — 核验已导出的 Android 包（APK / AAB）。
#
# 为什么需要：商店的硬要求（包名、64 位、图标、签名）**只有在成品里才能验证**，
# 导出“成功”不等于“能上架”。这些检查我一开始是手工跑 aapt2 做的，
# 手工的事情就会忘 —— 所以固化成脚本，CI 里也能跑。
#
# 用法: workflow/scripts/gf-android-verify.sh [包路径，默认自动找 build/android/ 下的产物]
# 退出码: 0 全部通过；1 有必需项不通过；2 找不到包或缺 aapt2。
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="${GF_PROJECT:-games/puzzle-core}"

PKG="${1:-}"
if [ -z "$PKG" ]; then
	# 优先 AAB（上架产物），其次 APK
	for c in "$PROJECT/build/android/puzzle-core.aab" "$PROJECT/build/android/puzzle-core.apk"; do
		[ -f "$c" ] && PKG="$c" && break
	done
fi
if [ -z "$PKG" ] || [ ! -f "$PKG" ]; then
	echo "!! 找不到要核验的包（先跑 gf-export.sh … android / android-apk）" >&2
	exit 2
fi

# aapt2 / apksigner 在 Android SDK 的 build-tools 里；路径来自编辑器设置或环境变量
find_sdk() {
	if [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -d "$ANDROID_SDK_ROOT/build-tools" ]; then echo "$ANDROID_SDK_ROOT"; return; fi
	local f
	f="$(ls -1t "$HOME"/.config/godot/editor_settings-*.tres 2>/dev/null | head -1 || true)"
	if [ -n "$f" ]; then
		grep -o 'android/android_sdk_path = "[^"]*"' "$f" | sed 's/.*= "//; s/"$//'
	fi
}
SDK="$(find_sdk)"
BT=""
if [ -n "$SDK" ] && [ -d "$SDK/build-tools" ]; then
	BT="$(ls -1 "$SDK/build-tools" | sort -V | tail -1)"
fi
AAPT2="$SDK/build-tools/$BT/aapt2"
APKSIGNER="$SDK/build-tools/$BT/apksigner"

fail=0
note() { printf '  %-26s %s\n' "$1" "$2"; }
bad()  { printf '  %-26s \033[31m%s\033[0m\n' "$1" "$2"; fail=1; }

echo "=== 核验 $PKG ==="
note "包大小" "$(du -h "$PKG" | cut -f1)"
case "$PKG" in
	*.aab)
		# ── AAB：ABI 与签名 ──
		abis="$(unzip -l "$PKG" | grep -oE "lib/[a-z0-9_-]+/" | sed 's|lib/||; s|/||' | sort -u | tr '\n' ' ')"
		note "ABI" "${abis:-（无）}"
		case "$abis" in
			*arm64-v8a*) : ;;
			*) bad "ABI" "缺少 arm64-v8a —— Google Play 要求 64 位，这包不能上架" ;;
		esac
		if command -v jarsigner >/dev/null 2>&1; then
			if jarsigner -verify "$PKG" 2>&1 | grep -q "jar verified"; then
				note "签名" "jar verified（可用 Play App Signing 上传）"
			else
				bad "签名" "jarsigner 校验未通过（发布包必须签名）"
			fi
		else
			note "签名" "跳过（没有 jarsigner，装 JDK 后可校验）"
		fi
		# AAB 的清单在 base/manifest/，用 aapt2 读不了 → 提示用 bundletool，不在这里假装检查
		note "清单" "AAB 清单为 protobuf（base/manifest/AndroidManifest.xml）"
		;;
	*)
		if [ ! -x "$AAPT2" ]; then
			echo "!! 找不到 aapt2（Android SDK build-tools）。装好 SDK 后重试。" >&2
			exit 2
		fi
		badging="$("$AAPT2" dump badging "$PKG" 2>/dev/null)"
		# 统一用 grep -oE 取值：sed 的 BRE + 引号在脚本里出过一次“取不到值”的怪事
		# （单独跑同样的表达式是好的），换成 grep 后行为稳定、也更好读。
		field() { printf '%s\n' "$badging" | grep -oE "$1" | head -1 | cut -d"'" -f2; }
		pkgname="$(printf '%s\n' "$badging" | grep -oE "^package: name='[^']*'" | cut -d"'" -f2)"
		verc="$(printf '%s\n' "$badging" | grep -oE "versionCode='[^']*'" | head -1 | cut -d"'" -f2)"
		vern="$(printf '%s\n' "$badging" | grep -oE "versionName='[^']*'" | head -1 | cut -d"'" -f2)"
		# aapt2 的 badging 里 minSdk 那行**两种拼写都出现过**：`sdkVersion:'24'` 与
		# `minSdkVersion:'24'`（取决于包，实测同一工具对不同构建输出不同）。
		# 只匹配一种就会静默取到空值 —— 所以两种都接受（^ 锚定 + 二选一，顺便排除 targetSdk）。
		mins="$(printf '%s\n' "$badging" | grep -oE "^(min)?[sS]dkVersion:'[^']*'" | head -1 | cut -d"'" -f2)"
		tgts="$(field "^targetSdkVersion:'[^']*'")"
		label="$(field "^application-label:'[^']*'")"
		abis="$(printf '%s\n' "$badging" | grep -oE "^native-code: .*" | sed 's/^native-code: //')"
		perms="$(printf '%s\n' "$badging" | grep -c "^uses-permission")"

		# 期望包名从预设里取：保证「配置」与「成品」一致
		expect="$(grep -m1 -o 'package/unique_name="[^"]*"' "$PROJECT/export_presets.cfg" | sed 's/^[^=]*=//; s/"//g')"
		note "包名" "${pkgname:-（读不到）}"
		if [ -n "$expect" ] && [ "$pkgname" != "$expect" ]; then
			bad "包名一致性" "成品是 $pkgname，预设是 $expect（上架后包名不可改）"
		else
			[ -n "$expect" ] && note "包名一致性" "与预设一致 ✓"
		fi
		note "版本" "versionCode=$verc versionName=$vern"
		note "SDK" "min=$mins target=$tgts"
		note "应用名" "${label:-（读不到）}"
		note "ABI" "${abis:-（无）}"
		case "$abis" in
			*arm64-v8a*) : ;;
			*) bad "ABI" "缺少 arm64-v8a（真机装不上）" ;;
		esac
		printf '%s\n' "$badging" | grep -q "^application-icon" && note "图标" "已包含" || bad "图标" "缺少应用图标"
		if [ "$perms" = "0" ]; then
			note "权限" "无（对隐私表单最省事）"
		else
			note "权限" "$perms 项：$(printf '%s\n' "$badging" | grep '^uses-permission' | sed "s/uses-permission: name='//; s/'//" | tr '\n' ' ')"
		fi
		# 方向：fullUser(13)/fullSensor(10)/sensor(4) 都表示横竖屏都允许
		orient="$("$AAPT2" dump xmltree --file AndroidManifest.xml "$PKG" 2>/dev/null \
			| grep -o 'screenOrientation(0x0101001e)=[0-9]*' | head -1 | cut -d= -f2)"
		note "方向" "screenOrientation=${orient:-未设置}（10/13 = 横竖屏都允许）"
		if [ -x "$APKSIGNER" ]; then
			"$APKSIGNER" verify "$PKG" >/dev/null 2>&1 && note "签名" "apksigner 校验通过" || bad "签名" "apksigner 校验失败"
		fi
		;;
esac

if [ "$fail" = "0" ]; then
	echo "=== 核验通过 ==="
else
	echo "=== 核验失败（见上面标红项）===" >&2
fi
exit "$fail"
