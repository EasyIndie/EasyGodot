#!/usr/bin/env bash
# ============================================================================
# gf-check-exec.sh — 检查 workflow/scripts/*.sh 在 git 索引里是否有执行位。
#
# 为什么需要这个自检：WSL/Windows 的 drvfs 挂载下 core.fileMode=false，
# git 根本记不住文件权限，所有新脚本都会入库为 100644；
# 本地跑没问题（文件系统上有执行位），但 CI 直接调用就会 Permission denied。
# 这个坑已经踩过两次（gf-test.sh、gf-web-inject.sh），所以改成机器检查。
#
# 用法: workflow/scripts/gf-check-exec.sh
# 退出码: 有脚本缺执行位则非 0，并打印修复命令。
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

missing=()
while read -r mode path; do
	[ "$mode" = "100755" ] || missing+=("$path")
done < <(git ls-files -s workflow/scripts/'*.sh' | awk '{print $1, $4}')

if [ ${#missing[@]} -gt 0 ]; then
	echo "以下脚本在 git 索引里缺少执行位（CI 会报 Permission denied）：" >&2
	for p in "${missing[@]}"; do echo "  - $p" >&2; done
	echo "" >&2
	echo "修复：git update-index --chmod=+x ${missing[*]}" >&2
	exit 1
fi
echo "workflow/scripts/*.sh 执行位检查通过"
