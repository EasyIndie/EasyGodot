# EasyGodot

[![Deploy Web (GitHub Pages)](https://github.com/EasyIndie/EasyGodot/actions/workflows/pages.yml/badge.svg)](https://github.com/EasyIndie/EasyGodot/actions/workflows/pages.yml)

> **AI + Godot 自动化游戏生产工作流**（Game Factory）+ 用它做出来的第一款游戏。

核心想法：把「做游戏」拆成**可复现、可验证、可自动化**的流水线——
规则与引擎解耦、关卡由 AI 生成并自动质检、视觉层保持薄、全部环节 headless 可测。
第一款游戏（3D 几何翻滚解谜）用来验证整条流水线，而不是为了做一款游戏而搭一套框架。

---

## ▶ 在线试玩

**<https://easyindie.github.io/EasyGodot/>**

Godot Web 单线程导出，打开即玩（无需安装）。方向键 / WASD 移动 · `R` 重开 · `L` 选关 · `V` 看最佳回放。

---

## 目录结构

```
games/<name>/            单个游戏的完整实例
  core/                  纯逻辑规则核心（RefCounted，不依赖场景/节点，headless 可跑）
  solver/                求解器（可解性 / 最优解 / 难度分级）
  levels/                关卡 JSON
  scenes/                视觉层（Godot 节点）
  meta/                  元游戏层（进度 / 回放 / 本地榜 / 选关界面）
  tests/                 headless 测试套件
  tools/                 内容生成器 / 质检 / 截图
workflow/                跨游戏复用的平台（脚本、文档、pi 扩展）——不放游戏专属逻辑
  scripts/               gf-*.sh 统一入口
  docs/                  设计沉淀文档 01..07
  pi-extensions/         pi 斜杠命令扩展
.agents/skills/          AI Agent 技能（Godot Game Factory）
.github/workflows/       自动构建 + 测试 + 发布
```

## 试点游戏：puzzle-core

3D 几何翻滚解谜（灵感来自 Bloxorz）：**翻滚骨牌（Domino）与方块（Cube）**，
把指定形态**恰好**停在目标格上，掉出棋盘或踩空即失败。

- **20 关**，难度曲线 easy → expert，含 4 个 Cube 关
- 斜 45° 等距视角、翻滚/坠落物理动画、空洞即「地面缺失」
- 选关界面（顺序解锁）、通关回放、最佳步数与本机榜
- 求解器 BFS 出**最优解**，用作关卡质检门禁

**操作**：方向键 / WASD 移动 · `R` 重开 · `L` 选关 · `V` 看最佳回放

---

## 快速开始

```bash
# 跑全部测试（6 个套件 / 400+ 断言）
workflow/scripts/gf-test.sh

# 本地预览 Web 版（多线程 + 禁用缓存，避免「改了代码页面没变」）
workflow/scripts/gf-serve.sh          # → http://localhost:8000

# 关卡质检（非法 / 不可解时退出码非 0）
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/validate_levels.gd

# 按难度曲线可复现地重建正式关卡集
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/build_level_set.gd

# 导出构建（Web + Linux + Windows）
workflow/scripts/gf-export.sh

# 打 Steam Demo 分发包 / 生成 GitHub Pages 站点
workflow/scripts/gf-package.sh
workflow/scripts/gf-pages.sh
```

> Godot 二进制放在 `workflow/godot-bin/godot`（未入库，需自行下载对应版本）。

## 文档
| 文档 | 内容 |
|---|---|
| [01 工作流总览](workflow/docs/01-workflow-overview.md) | 结构化输出协议、目录约定、运行器 |
| [02 规则核心设计](workflow/docs/02-puzzle-core-design.md) | 坐标系、数据模型、通用 PolyCube 翻滚公式 |
| [03 求解器与质检](workflow/docs/03-solver-and-qc.md) | BFS 最优解 + 「生成 → 质检 → 筛选」闭环 |
| [04 视觉层与 E2E](workflow/docs/04-visual-and-e2e.md) | 视觉层薄化、输入映射、选关与回放、headless E2E |
| [05 生成与导出](workflow/docs/05-generation-and-export.md) | 关卡生成、导出管线、Steam 打包、GitHub Pages |
| [06 新游戏手册](workflow/docs/06-new-game-playbook.md) | 用同一套平台做下一款游戏 |
| [07 MVP 状态](workflow/docs/07-mvp-status.md) | MVP 对照表、待办、坑与交接说明 |

## CI / 发布

推送到 `main` 会自动触发 [`.github/workflows/pages.yml`](.github/workflows/pages.yml)：
安装 Godot `4.7.2` + 导出模板（带缓存）→ 导入资源 → **跑全部测试与关卡质检** →
导出 Web → 上传 Pages 产物。

> **已上线**：仓库已转为公开，Pages 使用 **workflow 构建源**，
> 部署地址 <https://easyindie.github.io/EasyGodot/>。
> 推送 `main` 后约 1 分钟自动更新（构建 → 测试 → 质检 → 导出 → 部署）。

本地也可手动发布 / 预览：

```bash
workflow/scripts/gf-pages.sh games/puzzle-core              # 生成 dist/pages/
python3 -m http.server 8080 --directory dist/pages          # 当 GitHub Pages 跑一遍
workflow/scripts/gf-pages.sh games/puzzle-core --deploy     # 强推到 gh-pages 分支
```

## 第三方资源

- [Godot Engine](https://godotengine.org/) 4.7.2（MIT）
- [Noto Sans SC](https://fonts.google.com/noto/specimen/Noto+Sans+SC)（SIL OFL 1.1）
