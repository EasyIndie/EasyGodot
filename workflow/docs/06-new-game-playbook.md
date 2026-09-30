# 06 · 新游戏 Playbook（可复用工作流的最终交付物）

> 读完本文，你就能用这套「游戏工厂」开一个新游戏，复用 Puzzle Core 验证过的全部自动化能力。

---

## 1. 复用边界（最重要）

```
workflow/            ← ★ 可复用平台：脚本 + 模板 + 文档 + Skill（换游戏不动）
games/<name>/        ← 游戏实例：规则 + 内容 + 场景（每个游戏重写）
.agents/skills/      ← 智能体技能（跨游戏复用）
```

**换新游戏时，你只写 `games/<name>/` 里的这几样**：

| 文件/目录 | 内容 | 是否重写 |
|---|---|---|
| `core/` | 规则核心（纯逻辑，无 Node） | ✅ 重写 |
| `levels/*.json` | 内容模型 | ✅ 重写 |
| `scenes/` | 视觉层（消费 core） | ✅ 重写 |
| `solver/` | 求解/验证（依赖 core） | 🔶 适配 |
| `tools/` | 生成器等 | 🔶 适配 |
| `tests/` | 测试 | ✅ 重写 |
| `project.godot` / `export_presets.cfg` | 项目配置 | 🔶 微调 |

`workflow/`（gf-run / gf-test / gf-export / docs / Skill）**原样复用**。

---

## 2. 游戏实例必须遵守的「契约」

这是可复用平台的约定，新游戏满足它即可接入整套自动化：

1. **规则与引擎解耦**：`core/` 用 `extends RefCounted`（非 Node），`preload()` 引用，
   headless 可直接 `-s` 运行。
2. **结构化输出协议**：所有 headless 脚本 `extends SceneTree` + `print(JSON.stringify(结果))`
   + `quit(0/1)`，stdout 只输出 JSON。
3. **内容模型声明化**：关卡/配置用 JSON，配 `level_loader` 解析。
4. **统一测试入口**：测试脚本放 `tests/test_*.gd`，`gf-test.sh` 自动发现。
5. **统一移动入口**：`apply_move_on(board, state, dir)` 纯函数（求解器/视觉层/测试共用）。

---

## 3. 创建新游戏的步骤

```bash
# 1. 复制骨架
cp -r games/puzzle-core games/my-game

# 2. 删掉试点专属内容，保留结构
#    （core/ 换成你的规则，levels/ 换成你的内容，scenes/ 换成你的视觉）

# 3. 改项目名
#    games/my-game/project.godot → config/name="My Game"

# 4. 写规则核心 + 测试，跑通
workflow/scripts/gf-test.sh games/my-game

# 5. 内容 + 求解/质检（如有）
workflow/scripts/gf-run.sh -p games/my-game res://tools/validate_levels.gd

# 6. 导出
workflow/scripts/gf-export.sh games/my-game
```

> 注：`gf-test.sh` / `gf-export.sh` 已支持传项目目录参数。

---

## 4. 命令速查

| 命令 | 作用 |
|---|---|
| `workflow/scripts/gf-run.sh -p <game> res://script.gd [args]` | 跑任意 headless 脚本 |
| `workflow/scripts/gf-test.sh [game]` | 跑全部测试套件 |
| `workflow/scripts/gf-run.sh -p <game> res://tools/validate_levels.gd` | 关卡质检门禁 |
| `workflow/scripts/gf-run.sh -p <game> res://tools/generate_levels.gd ...` | 关卡生成（候选池） |
| `workflow/scripts/gf-run.sh -p <game> res://tools/build_level_set.gd` | 按曲线重建正式关卡集 |
| `workflow/scripts/gf-serve.sh [game] [port]` | 本地托管 Web 构建（禁用缓存） |
| `workflow/scripts/gf-shot.sh [game] [level]` | 关卡截图（需要显示环境） |
| `workflow/scripts/gf-export.sh [game] [平台...]` | 一键导出（Web + Linux + Windows） |
| `workflow/scripts/gf-package.sh [game] [--appid N]` | 打 Steam Demo 分发包（zip + SteamPipe 配置） |
| `workflow/scripts/gf-pages.sh [game] [--deploy]` | 生成 / 发布 GitHub Pages 静态站点 |
| `workflow/scripts/gf-font-subset.sh [game]` | 按项目实际用字重建字体子集（体积/内存优化） |

**pi 斜杠命令**（装 `workflow/pi-extensions/game-factory.ts` 后，免开终端）：

| 命令 | 作用 |
|---|---|
| `/serve [game] [port]` · `/stop` | 预览服务启停 |
| `/shot [game] [level]` | 关卡截图 |
| `/test [game]` | 跑全部测试 |
| `/games` | 列出发现的游戏 |

> **游戏可无限扩展**：所有脚本与 pi 命令都以 `<game>`（项目目录）为参数，
> pi 扩展会自动发现 `games/*/`。因此新增 `games/<name>/` 后**无需重写任何命令**。

---

## 5. 最佳实践索引

- `01-workflow-overview.md` — 结构化输出协议、目录结构、运行器
- `02-puzzle-core-design.md` — 规则核心模式（坐标系/数据模型/通用翻滚公式）
- `03-solver-and-qc.md` — 求解器 + 质检门（内容生产闭环）
- `04-visual-and-e2e.md` — 视觉层薄化 + Headless E2E
- `05-generation-and-export.md` — AI 生成 + 导出管线
- `07-mvp-status.md` — MVP 对照表 + 待办 + 交接文档

---

## 6. 已知限制与下一步

- 棋盘目前是平面（无高度差/叠放），多形态（Bar/L/T/PolyCube）与机关（Shape Gate）待扩展
- 视觉层已含 HUD / **选关界面** / 翻滚与坠落动画；尚无音效、关卡编辑 UI
- **可复用元游戏层** `meta/`：`progress.gd`（进度/回放持久化，路径可注入）+ `level_select.gd`（选关）
  ——换游戏时只需传入 `entries`（关卡元数据），无需改 UI 代码
- 排行榜（服务端）/挑战链接需后端；Replay 已在本地跑通（`V` 回放最佳记录）
- 若需 AI 智能体实时操作场景树，可接 MCP（gda / godot-mcp，见立项讨论）
