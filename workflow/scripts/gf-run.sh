#!/usr/bin/env bash
# ============================================================================
# gf-run.sh — Game Factory 标准运行器
#
# 统一封装 Godot headless 调用，固化「结构化输出协议」：
#   * stdout 只输出脚本的 JSON（通过 --no-header 抑制版本头）
#   * 日志/警告/错误走 stderr，不污染结果
#   * 退出码透传，供智能体/CI 判断成功失败
#
# 用法:
#   gf-run.sh <script.gd> [args...]                    # 运行独立脚本
#   gf-run.sh -p <project_dir> <script.gd> [args...]   # 以某项目为根运行脚本
#
# 示例:
#   workflow/scripts/gf-run.sh workflow/scripts/hello.gd
#   workflow/scripts/gf-run.sh -p games/puzzle-core res://tests/run_all.gd
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT="$SCRIPT_DIR/../godot-bin/godot"

# 在容器/root 环境下运行时的 root 警告属于噪音，静默之
export GODOT_SILENCE_ROOT_WARNING=1

# 解析可选 --path/-p 参数
PROJECT_DIR=""
if [[ "${1:-}" == "-p" || "${1:-}" == "--path" ]]; then
	PROJECT_DIR="$2"
	shift 2
fi

if [[ $# -lt 1 ]]; then
	echo "用法: gf-run.sh [-p <project_dir>] <script.gd> [args...]" >&2
	exit 2
fi

SCRIPT="$1"
shift

ARGS=()
if [[ -n "$PROJECT_DIR" ]]; then
	ARGS+=(--path "$PROJECT_DIR")
fi

# 核心：headless + 无版本头 + 静默 root 警告
# 用户参数统一放到 -- 之后，脚本内用 OS.get_cmdline_user_args() 读取
if [[ $# -gt 0 ]]; then
	exec "$GODOT" --headless --no-header "${ARGS[@]}" -s "$SCRIPT" -- "$@"
else
	exec "$GODOT" --headless --no-header "${ARGS[@]}" -s "$SCRIPT"
fi
