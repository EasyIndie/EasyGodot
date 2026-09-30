---
name: godot-game-factory
description: Build, validate, test, and export Godot games through the reusable Game Factory workflow. Use when working on any Godot project in this repo, running headless GDScript, validating puzzle levels with the solver, adding tests, or exporting Web/Steam builds.
---

# Godot Game Factory

在本仓库中操作 Godot 项目时，遵循以下可复用工作流。目标是让每个新游戏都复用同一套自动化平台，并沉淀最佳实践。

## 关键位置

- Godot 可执行文件：`workflow/godot-bin/godot`（Godot 4.7.2 stable，Linux x86_64）
- 标准运行器：`workflow/scripts/gf-run.sh`
- 工作流文档：`workflow/docs/`（先读 `01-workflow-overview.md`）
- 游戏实例：`games/puzzle-core/`（试点游戏）
- 本技能所在目录：`.agents/skills/godot-game-factory/`

## 结构化输出协议（必须遵守）

所有 headless 脚本：
1. 用 `extends SceneTree` + `_init()` 编写
2. 通过 `print(JSON.stringify(result))` 输出**单行 JSON 到 stdout**
3. 成功 `quit(0)`，失败 `quit(1)`
4. 运行必须经 `gf-run.sh`（它已封装 `--headless --no-header` 等参数，保证 stdout 纯净）

```bash
# 独立脚本
workflow/scripts/gf-run.sh workflow/scripts/hello.gd

# 项目上下文脚本（res:// 路径）
workflow/scripts/gf-run.sh -p games/puzzle-core res://tests/project_info.gd
```

读取结果时：解析 stdout 的 JSON；错误信息看 stderr；退出码判断成败。

## 目录约定

- `workflow/`：跨游戏复用的平台（脚本/模板/文档），**不要**放游戏专属逻辑
- `games/<name>/`：单个游戏的完整实例
  - `core/`：纯逻辑规则核心（不依赖场景/节点，可直接 headless 运行）
  - `solver/`：求解器（可解性/最优解/难度）
  - `levels/`：关卡 JSON
  - `tests/`：测试脚本
  - `scenes/`：视觉层
  - `meta/`：元游戏层（进度/回放持久化、选关界面）——与规则层解耦，可 headless 单测
  - `tools/`：内容生成器等

## 运行测试

```bash
# 全部测试套件
workflow/scripts/gf-test.sh

# 单个套件
workflow/scripts/gf-run.sh -p games/puzzle-core res://tests/test_core.gd
```

stdout 输出 `{"checks":N,"failures":M,"status":"ok|fail"}`，失败时退出码非 0，错误信息在 stderr。

## 关卡质检（门禁）

```bash
# 质检 levels/ 下全部关卡（非法/不可解时退出码非 0）
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/validate_levels.gd

# 质检指定关卡
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/validate_levels.gd res://levels/level_01.json
```

## 关卡生成

```bash
# 候选池（不覆盖正式关卡）
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/generate_levels.gd \
  --count 20 --difficulty medium --grid 6x6 --holes 12 --min-moves 2 --seed 42

# 正式关卡集：按声明式难度曲线可复现地重建 levels/level_01..20.json
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/build_level_set.gd
```

形状通过 `--shape domino|cube` 指定（默认 domino）。

## 导出构建

```bash
workflow/scripts/gf-export.sh                     # Web + Linux + Windows，产物在 games/puzzle-core/build/
workflow/scripts/gf-export.sh games/puzzle-core windows   # 只导指定平台
workflow/scripts/gf-package.sh                    # 打 Steam Demo 分发包（dist/*.zip）
```

## 发布到 GitHub Pages

```bash
workflow/scripts/gf-pages.sh games/puzzle-core             # 生成 dist/pages/（Pages 就绪）
workflow/scripts/gf-pages.sh games/puzzle-core --deploy    # 强推到 gh-pages 分支
```

单线程 Web 导出（`variant/thread_support=false`）**不需要** COOP/COEP 跨源隔离，
而 GitHub Pages 恰好无法自定义响应头——所以本项目可以直接托管。
另外提供了 `.github/workflows/pages.yml`（Actions 构建 + 测试 + 部署）。

## 本地预览（浏览器）

```bash
workflow/scripts/gf-serve.sh    # → http://localhost:8000，已禁用缓存
```

> 重要：`index.pck`/`index.wasm` 很大，浏览器极易用旧缓存导致「改了代码但页面没变」。
> `gf-serve.sh` 用 `serve_nocache.py` 发 `Cache-Control: no-store`。若用其他服务器，务必硬刷新
> （Ctrl+Shift+R）或 DevTools → Network → Disable cache。

## Pi 斜杠命令（不用另开终端）

把调试操作暴露为 pi 命令：`workflow/pi-extensions/game-factory.ts` → 复制到 pi 扩展目录后 `/reload`。

| 命令 | 作用 |
|---|---|
| `/serve [game] [port]` | 启动/重启 Web 预览（后台 + 禁用缓存） |
| `/stop` | 停止预览服务器 |
| `/shot [game] [level]` | 关卡截图 |
| `/test [game]` | 运行该游戏全部测试 |
| `/games` | 列出发现的游戏 |

**游戏无关**：命令自动确定当前游戏（显式参数 → cwd 所在 `games/<name>/` → 唯一游戏），
新增游戏无需改扩展；底层脚本本就是以项目目录为参数。

## 视觉截图（需要显示环境）

```bash
workflow/scripts/gf-shot.sh games/puzzle-core res://levels/level_01.json
```

## 工作流循环

写代码 → `gf-run.sh` 跑校验/测试 → 读 stdout JSON 与退出码 → 修复 → 再跑。

新增通用能力时，优先考虑：是否该进 `workflow/`（可复用）还是留在游戏内（游戏专属）。
并把结论写进 `workflow/docs/`。

## 参考

- 完整背景：`workflow/docs/01-workflow-overview.md`
- 规则核心设计（坐标系/数据模型/翻滚公式/最佳实践）：`workflow/docs/02-puzzle-core-design.md`
- 求解器与质检门：`workflow/docs/03-solver-and-qc.md`
- 视觉层与 Headless E2E：`workflow/docs/04-visual-and-e2e.md`
- AI 关卡生成与导出管线：`workflow/docs/05-generation-and-export.md`
- 项目立项讨论：`Godot_AI_Puzzle_Game_Project_Discussion_Summary.md`
