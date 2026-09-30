# 07 · MVP 状态与待办（交接文档）

> 用途：当前实现状态 + MVP 差距 + 下一步计划。
> 同时作为「压缩上下文后继续工作」的交接文档——需要精确细节时看这里。

---

## 1. 当前已实现（试点游戏 `games/puzzle-core`）

### 规则核心 `core/`（纯 GDScript，headless 可跑，与引擎解耦）
- `rotations.gd` 24 个整数旋转矩阵（列向量表示，确定性整数运算）
- `shape.gd` / `shapes.gd`（已注册：`domino`、`cube`）
- `puzzle_state.gd`（`canonical_key()` 用于求解去重）
- `moves.gd` 通用 PolyCube 翻滚：`roll_delta(shape, ori, d)` → `{orientation, delta, pivot}`
  （绕「前下边」旋转 90°，公式 `new_pos = pos + (I−M)·(pivot−pos)`）
- `board.gd` 网格 / **空洞** / 目标
  - **空洞 = 地面缺失**；`is_solid()` / `supports()` 是「脚下有没有地面」的**唯一依据**（越界与空洞同构）
  - `set_void(cell2d, on)` = 机关扩展点（实心 ↔ 空洞动态切换）
- `level_loader.gd` JSON 关卡；`puzzle_core.gd` 门面
- **形状：`domino` ✅ / `cube` ✅** —— cube 是单格形状；`resolve_orientation()` 对单格形状
  把任何语义描述符（`lying_x`/`lying_z`/`standing`）都映射到 `orientation = 0`

### Solver / 工具
- `solver/solver.gd` BFS 最优解 + 难度分级；`solver/validate.gd` 质检门
- `tools/level_generator.gd` + `generate_levels.gd`（固定种子可复现）、`validate_levels.gd`

### 视觉层 `scenes/`
- `game.gd`：渲染（每个世界单元一个立方体）+ 翻滚/坠落动画 + **踩空坠落**（`check_fall()`）
  - 坠落两类：**完全悬空** → 原地自由落体(+自旋)；**部分悬空** → 先绕支撑边缘倾倒 90°，脱离后再落体
  - `animate=false` → 全部同步执行（供 headless 测试确定性驱动）
- `main.gd`：斜 45° 等距相机、**渐变背景幕布**、方向光+阴影、HUD（圆角半透明面板 / 进度条 / 步数 chip）、
  通关反馈（**灯光脉冲**，方块**不变色、不上升**）、换关过渡（棋盘下沉 + 暗幕，居中显示「关卡 N / M」）
- 空洞渲染 = **不铺地面**（透出背景）

### 关卡 / 测试 / 导出
- `levels/level_01..20.json`：**20 关**（其中 4 个 cube 关），3~21 步，难度曲线 easy → expert
- `tools/build_level_set.gd`：按声明式曲线**可复现地重建整个关卡集**
- `meta/`（元游戏层，与规则层解耦、可 headless 单测）：
  - `progress.gd`：进度持久化（`user://progress.json`）——已完成 / 最佳步数 / **最佳回放** / 本机榜；存档路径可注入
  - `leaderboard.gd`：本地榜与总成绩汇总 + 远端提交载荷接缝
  - `level_select.gd`：选关界面（顺序解锁 / 最佳与参考步数 / 本机榜 / 重置需两次确认）
- `tests/`：core 84 + e2e 157 + generator 48 + leaderboard 35 + progress 54 + solver 26 = **404 项全绿**
- `export_presets.cfg`：**Web + Linux**（无 Windows）

### 工作流 `workflow/` + pi 扩展
- `gf-run.sh` / `gf-test.sh` / `gf-serve.sh` / `gf-shot.sh` / `gf-export.sh`；`serve_nocache.py`
- pi 斜杠命令（用户级扩展 `~/.pi/agent/extensions/game-factory.ts`）：
  `/serve` `/stop` `/shot` `/test` `/games` —— **游戏无关**，自动发现 `games/*/`
- 文档 `workflow/docs/01..06`；技能 `.agents/skills/godot-game-factory/SKILL.md`

---

## 2. MVP 对照（立项文档「十一、MVP 方案 → MVP 包含」）

| 必须项 | 状态 | 说明 |
|---|---|---|
| 3D 方块滚动 | ✅ | 通用翻滚 + 动画 |
| Domino | ✅ | 竖立/横躺/四向 |
| **Cube** | ✅ | 单格形状；第 8 / 12 / 16 / 20 关为 cube 关 |
| **20 个关卡** | ✅ | easy×4 → medium×5 → hard×9 → expert×2 |
| JSON 关卡系统 | ✅ | + 生成器 + 质检 |
| Solver | ✅ | |
| **Replay** | ✅ | 通关记录移动序列；`V` 回放最佳记录 |
| **排行榜基础** | ✅ | 本地榜：每关前 5 条成绩 + 总成绩/已最优汇总；远端载荷接缝已预留 |
| Web 版本 | ✅ | 已导出 |
| **Steam Demo** | ✅ | Windows/Linux 预设 + `gf-package.sh` 出 SteamPipe 分发包（**Steamworks SDK 未接入**） |

补：阶段二「UI」的**关卡选择界面** ✅ 已实现；MVP 排除项（多人 / UGC / 移动端 / AI 大规模生成 / 商店 / 剧情）确认未做 ✅

---

## 3. 执行计划

### P0 ✅ 已完成
1. ✅ **修 cube 方向 bug**：`core/shapes.gd::resolve_orientation` 对单格形状返回 0。
2. ✅ **扩到 20 关**：新增 `tools/build_level_set.gd`（声明式曲线 + 可复现种子 + 写盘后终检）。
3. ✅ **Cube 关卡**：第 8/12/16/20 关；测试 171 → **295 项**全绿。

### P1 ✅ 已完成
4. ✅ **Replay**：通关记录方向标签序列 → `V` 重演（仅保存最佳步数的那次）。
5. ✅ **关卡选择界面**：`L` / `Esc` 打开；卡片显示形状 + 最佳/参考步数；顺序解锁。
   （两者共用新增的 `meta/` 元游戏层与 `user://progress.json`）

### P2 ✅ 已完成
6. ✅ **排行榜基础**：每关前 5 条本机榜 + **总成绩**（各关最佳之和）/ **已最优** 关数；
   `leaderboard.gd::submit_payload()` 预留了将来 POST 给后端的载荷形状（服务端尚未接）。
7. ✅ **Steam Demo**：新增 Windows 导出预设；`gf-package.sh` 一键出
   Windows/Linux 双平台分发包 + `steam_appid.txt` + `steamcmd/app_build_*.vdf`（zip 约 91MB）。

### 待拍板
- Cube 的形态：**A** 先做独立 Cube 关卡（省事）；**B** 实现 Shape Gate 机关（Domino ↔ Cube，贴合文档但要动 `mechanism`）。

---

## 4. 常用命令

```bash
workflow/scripts/gf-test.sh                    # 跑 171 项测试
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/validate_levels.gd
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/generate_levels.gd \
  --count 20 --difficulty medium --grid 6x6 --holes 12 --min-moves 2 --seed 42
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/build_level_set.gd  # 重建 20 关正式关卡集
workflow/scripts/gf-export.sh                  # 导出 Web + Linux
workflow/scripts/gf-shot.sh games/puzzle-core res://levels/level_01.json
workflow/scripts/gf-serve.sh                   # 本地预览（多线程 + 禁缓存）
```

pi 里：`/test` `/serve` `/shot` `/games`

---

## 5. 已知坑（省时间）

- **`gl_compatibility` 不渲染 `BG_SKY`/`ProceduralSkyMaterial`**（实测改成红/黄天空背景依旧全黑）
  → 背景改用**跟随相机的渐变幕布**（unshaded quad）。
- `roll_delta` 的 `pivot` 用「单元中心在整数格」坐标，而渲染把方块抬高 0.5 贴地
  → `pivot_world` 必须 **+0.5**，否则绕「底面下方 0.5」旋转，看着发扁。
- 空洞/越界同为「无支撑」；坠落分**完全悬空**与**部分悬空**两类（见上）。
- 单线程 HTTP server（`python -m http.server`）会被一次中断的下载**永久卡死** → 必须多线程。
- 浏览器对 `index.pck` 缓存极顽固 → 用 `gf-serve.sh`（`Cache-Control: no-store`）。
- Godot 4 坑：`Vector3i` 无 `dot()`；`Array.sort()` 不能排 `Vector3i`（用 `sort_custom`）；
  版本头污染 stdout（用 `--no-header`）；默认字体无中文字形（已内置 Noto Sans SC）。
- **WSL 的 drvfs 挂载下 `core.fileMode=false`**：git 无法记录执行位，所有文件都入库为 `100644`，
  于 CI 里直接调用 `workflow/scripts/gf-test.sh` 会报 `Permission denied`（真实踩过）。
  解决：`git update-index --chmod=+x workflow/scripts/*.sh` 显式标注。
- **GitHub Pages 无法自定义响应头**：因此只能托管 Godot 的**单线程** Web 导出
  （`variant/thread_support=false`）；另外**免费版组织**的 Pages 只能从**公开仓库**发布。
  首次启用 Pages 需管理员显式调用 `gh api -X POST repos/<o>/<r>/pages -f build_type=workflow`
  （工作流的 `GITHUB_TOKEN` 没有 admin，`configure-pages` 的 `enablement` 开不了）。
- **Safari 的 WebGL 内存上限远紧于 Chrome**：`canvas_resize_policy=2`（绘图缓冲 = 窗口×DPR）
  在 Retina 上会直接爆掉并报 `WebGL context lost`。已改为策略 1（固定 1280×720）+ 注入 CSS 铺满窗口；
  诊断页 `/diag.html` 可现场测出真实 GPU 与帧缓冲容量。

---

## 6. 关键文件

```
games/puzzle-core/
  core/{rotations,shape,shapes,puzzle_state,moves,board,level_loader,puzzle_core,util}.gd
  solver/{solver,validate}.gd
  scenes/{game,main}.gd  +  main.tscn
  tools/{level_generator,generate_levels,build_level_set,validate_levels,screenshot}.gd
  meta/{progress,leaderboard,level_select}.gd   # 元游戏层：进度/回放/本地榜 + 选关界面
  levels/level_01..20.json   # 20 关（含 4 关 cube）
  tests/{test_core,test_solver,test_e2e,test_generator,test_progress,test_leaderboard,fixtures}.gd
workflow/scripts/gf-*.sh  +  serve_nocache.py
workflow/docs/01..07
workflow/pi-extensions/game-factory.ts
```
