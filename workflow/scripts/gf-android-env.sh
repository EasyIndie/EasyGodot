#!/usr/bin/env bash
# ============================================================================
# gf-android-env.sh — 把 Android SDK / JDK 路径写进 Godot 的**编辑器设置**。
#
# 为什么需要这个脚本：Godot 的 Android 导出路径来自编辑器设置
# （export/android/android_sdk_path、export/android/java_sdk_path），
# 它**不读** ANDROID_SDK_ROOT / JAVA_HOME 这类环境变量，也没有命令行开关。
# 所以 CI 与首次配置都得写一次设置文件 —— 手改容易写坏，这里做成一键 + 自动备份。
#
# 用法：
#   workflow/scripts/gf-android-env.sh                 # 自动探测（ANDROID_SDK_ROOT / JAVA_HOME / 常见路径）
#   workflow/scripts/gf-android-env.sh <SDK目录> <JDK目录>
#   GODOT_EDITOR_SETTINGS=/path/to/file.tres workflow/scripts/gf-android-env.sh ...   # 指定设置文件
#
# 退出码：0 成功；2 探测失败（需要显式传参）。
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GODOT="$SCRIPT_DIR/../godot-bin/godot"

# 设置文件位置：优先环境变量 → 已有的版本化文件 → 默认名
SETTINGS="${GODOT_EDITOR_SETTINGS:-}"
if [ -z "$SETTINGS" ]; then
	# 取 mtime 最新的一个（Godot 不同小版本可能用不同文件名）
	SETTINGS="$(ls -1t "$HOME"/.config/godot/editor_settings-*.tres 2>/dev/null | head -1 || true)"
	[ -z "$SETTINGS" ] && SETTINGS="$HOME/.config/godot/editor_settings-4.tres"
fi

SDK="${1:-}"
JDK="${2:-}"

# ── 自动探测 ──
if [ -z "$SDK" ]; then
	for c in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$HOME/Android/Sdk" "$HOME/android-sdk" "/usr/lib/android-sdk"; do
		[ -n "$c" ] && [ -d "$c/build-tools" ] && SDK="$c" && break
	done
fi
if [ -z "$JDK" ]; then
	for c in "${JAVA_HOME:-}" /usr/lib/jvm/java-17-openjdk-amd64 /usr/lib/jvm/java-21-openjdk-amd64 \
		/usr/lib/jvm/temurin-17-jdk-amd64; do
		[ -n "$c" ] && [ -x "$c/bin/keytool" ] && JDK="$c" && break
	done
	# 退一步：从 PATH 里的 java 反推
	if [ -z "$JDK" ] && command -v java >/dev/null 2>&1; then
		local_java="$(readlink -f "$(command -v java)" || true)"
		[ -n "$local_java" ] && JDK="$(dirname "$(dirname "$local_java")")"
	fi
fi

if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
	echo "!! 找不到 Android SDK 目录。请显式传入：gf-android-env.sh <SDK目录> [JDK目录]" >&2
	exit 2
fi
if [ -z "$JDK" ] || [ ! -d "$JDK" ]; then
	echo "!! 找不到 JDK 目录（需要含 bin/keytool，建议 JDK 17）。请显式传入。" >&2
	exit 2
fi

# ── 写入（幂等 + 备份）──
mkdir -p "$(dirname "$SETTINGS")"
if [ -f "$SETTINGS" ]; then
	cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
	echo "    已备份原设置 → $SETTINGS.bak.*"
else
	printf '[gd_resource type="EditorSettings" format=3]\n\n[resource]\n' > "$SETTINGS"
	echo "    新建设置文件 $SETTINGS"
fi

python3 - "$SETTINGS" "$SDK" "$JDK" <<'PY'
import io, re, sys
path, sdk, jdk = sys.argv[1], sys.argv[2], sys.argv[3]
lines = io.open(path, encoding="utf-8").read().splitlines(True)
want = {
    "export/android/android_sdk_path": sdk,
    "export/android/java_sdk_path": jdk,
}
found = set()
out = []
for ln in lines:
    m = re.match(r'^(export/android/(?:android|java)_sdk_path)\s*=\s*"(.*)"\s*$', ln)
    if m:
        key = m.group(1)
        out.append('%s = "%s"\n' % (key, want[key]))
        found.add(key)
    else:
        out.append(ln)
for key, val in want.items():
    if key not in found:
        out.append('%s = "%s"\n' % (key, val))
io.open(path, "w", encoding="utf-8").write("".join(out))
PY

echo "=== 已写入编辑器设置 ==="
echo "    文件: $SETTINGS"
echo "    android_sdk_path = $SDK"
echo "    java_sdk_path    = $JDK"
echo
echo "下一步："
echo "  1) 需要 Gradle 构建（AAB）时先装构建模板："
echo "     $GODOT --headless --path $ROOT/games/puzzle-core --install-android-build-template"
echo "  2) 导出 APK 试玩：workflow/scripts/gf-export.sh games/puzzle-core android-apk"
