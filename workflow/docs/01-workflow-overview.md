# 01 · Game Factory 工作流总览

> 目标：建立一套 **AI + Godot 自动化游戏制作工作流**，让每个新游戏都能复用同一套
> 平台（脚本/模板/测试/导出/智能体编排），并在此过程中持续沉淀最佳实践。
> Puzzle Core 是第一个试点游戏，用来跑通全流程。
>
> **命名约定**：`gf` = **Game Factory**（本工作流平台的简称）。
> 平台脚本统一以 `gf-<用途>` 命名（`gf-run.sh` / `gf-test.sh` / `gf-export.sh` / `gf-serve.sh` / `gf-shot.sh`），
> pi 里的调试斜杠命令（`/serve`、`/stop`、`/shot`、`/test`、`/games`）同源于此。

---

## 1. 核心设计原则

1. **规则与引擎解耦**：游戏规则写成纯 GDScript，不依赖场景/节点，可直接 headless 运行。
2. **内容模型声明化**：关卡/配置用 JSON 描述，配 Schema 校验。
3. **结构化输出协议**：所有自动化脚本统一「stdout 只输出 JSON + 退出码表意」。
4. **可复用平台 vs 游戏实例分离**：`workflow/` 跨游戏复用，`games/<name>/` 是具体游戏。

---

## 2. 目录结构

```
EasyGodot/
├── workflow/                       # ★ 可复用工作流平台
│   ├── godot-bin/                  #   Godot 可执行文件（含 godot 符号链接）
│   ├── scripts/                    #   通用自动化脚本（跨游戏复用）
│   │   ├── gf-run.sh               #     标准运行器（封装结构化输出协议）
│   │   └── hello.gd                #     最小闭环验证脚本
│   ├── templates/                  #   项目模板 / 关卡 Schema / Playbook 模板
│   ├── mcp/                        #   MCP 配置（预留，后续接入 gda/godot-mcp）
│   └── docs/                       #   ★ 最佳实践沉淀处
│       └── 01-workflow-overview.md
│
├── .agents/skills/                 #   Pi 可发现的 Agent Skills
│   └── godot-game-factory/SKILL.md
│
└── games/                          # ★ 游戏实例
    └── puzzle-core/                #   第一个试点：3D 几何滚动解谜
        ├── project.godot
        ├── core/                   #   规则核心（纯逻辑）
        ├── solver/                 #   求解器（可解性/最优解/难度）
        ├── levels/                 #   关卡 JSON
        ├── tests/                  #   测试脚本
        ├── scenes/                 #   视觉层
        └── tools/                  #   关卡生成器等
```

---

## 3. 结构化输出协议（最佳实践 #1，已验证 ✅）

**约定**：脚本通过 `print(JSON.stringify(result))` 输出**单行 JSON 到 stdout**；
日志/警告走 stderr；成功退出码 `0`，失败非 `0`。

**关键**：运行 Godot 时必须加 `--headless --no-header`，否则引擎版本头会污染 stdout。

```bash
# ✅ 正确：stdout 只有 JSON
godot --headless --no-header -s script.gd
# 输出: {"status":"ok", ...}

# ❌ 错误：stdout 混入引擎版本头
godot --headless -s script.gd
# 输出: Godot Engine v4.7.2... (污染)
```

**脚本模板**（headless 脚本统一 `extends SceneTree`）：

```gdscript
extends SceneTree

func _init() -> void:
    var result := {"status": "ok", "message": "..."}
    print(JSON.stringify(result))
    quit(0)   # 失败时 quit(1)
```

---

## 4. 标准运行器 gf-run.sh

统一封装上述协议，智能体/CI 无需记忆 Godot 参数：

```bash
# 运行独立脚本
workflow/scripts/gf-run.sh workflow/scripts/hello.gd

# 在指定项目上下文中运行 res:// 脚本
workflow/scripts/gf-run.sh -p games/puzzle-core res://tests/project_info.gd
```

运行器已固化：`--headless` + `--no-header` + 静默 root 警告 + 退出码透传。

---

## 5. 当前状态

### 阶段 0（已完成）

- [x] 下载 Godot 4.7.2 Linux 二进制到 `workflow/godot-bin/`
- [x] 建立工作流/游戏骨架目录
- [x] 打通「智能体 → Godot headless → JSON」最小闭环（独立 + 项目两种模式）
- [x] 固化结构化输出协议与标准运行器
- [x] 沉淀本总览文档 + 首个 Agent Skill

### 阶段 1（已完成）

- [x] 实现 Puzzle Core 规则核心（纯逻辑，7 个模块）
- [x] 通用翻滚模型（对任意 PolyCube 成立，精确复现 Bloxorz 规则）
- [x] 关卡 JSON 内容模型 + 加载器
- [x] 76 项单元/状态测试全部通过
- [x] BFS 冒烟：level_01 可解（最优 8 步）
- [x] 沉淀 `02-puzzle-core-design.md`

### 阶段 2（已完成）

- [x] BFS 求解器（可解性/最优解/状态空间/难度）
- [x] 关卡质检门（合法性 → 可解性 → 难度，退出码门禁）
- [x] 批量质检 CLI（自动扫描 levels/）
- [x] 26 项求解器测试通过；总 102 项测试全绿
- [x] 测试聚合脚本 `gf-test.sh`
- [x] 沉淀 `03-solver-and-qc.md`

### 阶段 3（已完成）

- [x] 视觉层（通用 PolyCube 渲染，消费同一套 core）
- [x] 主场景（摄像机 + 光照 + Game + 输入桥接）
- [x] Headless E2E 测试（Game 直驱 + 输入映射 + 场景实例化）
- [x] 真实 headless 启动主场景冒烟通过
- [x] 总 127 项测试全绿（3 个套件）
- [x] 沉淀 `04-visual-and-e2e.md`

### 阶段 4（已完成）

- [x] 关卡生成器（生成 → 质检门 → 难度筛选 闭环，固定种子可复现）
- [x] 导出管线（Web + Linux 一键构建，export_presets + gf-export.sh）
- [x] 导出过滤开发产物（tests/tools/build 不入包）
- [x] 实测：生成 15 关、Web/Linux 导出成功、导出二进制可运行
- [x] 总 155 项测试全绿（4 个套件）
- [x] 沉淀 `05-generation-and-export.md`

## 6. 常用命令速查

```bash
# 测试
workflow/scripts/gf-test.sh

# 关卡质检（门禁）
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/validate_levels.gd

# 关卡生成
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/generate_levels.gd --count 20 --difficulty medium

# 导出
workflow/scripts/gf-export.sh
```

## 7. 全部阶段已完成（0-4）

试点游戏 Puzzle Core 已跑通完整工作流，详见 `02`～`05` 各阶段文档。
