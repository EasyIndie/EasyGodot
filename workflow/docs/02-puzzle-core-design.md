# 02 · Puzzle Core 规则核心设计（阶段 1 沉淀）

> 这是「游戏工厂」的第一个规则核心实现，验证了**规则与引擎解耦**这条地基原则。
> 核心位于 `games/puzzle-core/core/`，全部为纯 GDScript，无 Node/场景依赖，可 headless 运行。

---

## 1. 坐标系约定（重要）

- 世界/局部坐标统一用 `Vector3i`（整数网格），分量顺序为 **(x, y, z)**，**y = 向上**。
- 棋盘是平面：实心单元 y=0，方块的「占地」只看 (x, z)，忽略高度。
- ⚠️ 易错点：`Vector3i(1, 0, 1)` 表示占地 (x=1, z=1)；不要写成 `(1, 1, 0)`（那是 y=1）。

---

## 2. 核心数据模型

| 概念 | 文件 | 说明 |
|---|---|---|
| 旋转系统 | `rotations.gd` | 24 个保定向轴对齐旋转，**整数矩阵**（避免浮点误差） |
| 形状 PolyCube | `shape.gd` | id + 局部单元集合（规范化到原点） |
| 形状注册表 | `shapes.gd` | 登记 domino/cube，解析方向描述符 |
| 状态 | `puzzle_state.gd` | shape + orientation + position + mechanism |
| 移动 | `moves.gd` | 通用「绕前下边旋转」翻滚 |
| 棋盘 | `board.gd` | 网格 + 洞 + 目标 + 合法性/胜负判定 |
| 关卡加载 | `level_loader.gd` | JSON → {board, start} |
| 门面 | `puzzle_core.gd` | 组合操作，供求解器/测试/视觉层/AI 共用 |
| 工具 | `util.gd` | 确定性排序等 |
| 元游戏层 | `meta/progress.gd`、`meta/level_select.gd` | 进度/回放持久化 与 选关界面（与规则层解耦，不依赖 Board/State） |

**机关（mechanic）**：目前实现了 `ice`（冰面打滑）—— 一次「移动」= 沿该方向连续翻滚，
直到再滚一格就会踩空为止。它**不引入累积状态**，所以规范键/求解器/状态空间都不用改；
但把 cube 从「一条直线走到目标」变成了真正需要规划的解谜。
状态里的 `mechanism` 会参与 `canonical_key()`（否则位置相同、机关不同的状态会被错误合并）。

**状态唯一不变式**：一切判定（合法性/胜负/求解去重）只依赖 `world_cells()`（世界单元集合），
不依赖内部 orientation/position 编码——因为同一世界单元集合可能对应多种编码（如横躺可正向/反向表示）。

---

## 3. 通用翻滚公式（对任意 PolyCube 成立）

翻滚 = 绕「前下边」旋转 90°：

```
new_orientation = M ∘ orientation
new_position    = position + (I - M) · (pivot - position)
```

其中 `M` 是绕轴 `(d × up)` 的 **-90°** 旋转（使顶部向移动方向 d 倾倒），
pivot 为前下边（底面 `min_y - 0.5`，移动方向前缘面 `leading + 0.5`）。

**验证结果**：该公式精确复现 Bloxorz 规则——
- 竖立 → 滚 → 横躺（覆盖 p+d 与 p+2d）
- 横躺 → 沿长轴滚 → 竖立（前移 2 格）
- 横躺 → 垂直滚 → 侧移 1 格仍横躺

全部 69 项翻滚断言 + 可逆性断言通过。

---

## 4. 关卡 JSON 内容模型

```json
{
  "id": "level_01",
  "grid": { "x": 6, "z": 6 },
  "holes": [[2, 2], [2, 3], [3, 2]],
  "goal": [[5, 5]],
  "start": { "shape": "domino", "orientation": "lying_x", "position": [0, 0, 0] }
}
```

- `orientation` 支持整数索引或语义化描述符：`standing` / `lying_x` / `lying_z`
- 胜负判定：方块占地集合 == 目标集合（骨牌需**竖立**在目标格上）

---

## 5. 求解器接口（阶段 2 已预演）

BFS 冒烟验证：`level_01` 可解，最优 8 步，状态空间 41。求解去重用 `canonical_key()`
（世界单元排序后的字符串）。阶段 2 将把 BFS 正式化为 `solver/` 模块并计算难度。

---

## 6. 阶段 1 沉淀的最佳实践

1. **规则与引擎解耦**：核心脚本 `extends RefCounted`（非 Node），用 `preload()` 引用而非
   `class_name`——因为 `class_name` 依赖全局类缓存，headless CI 下不可靠。
2. **确定性整数运算**：旋转用整数矩阵而非 `Basis`（浮点），保证求解器可复现。
3. **只测不变式**：测试断言 `world_cells()`，不测内部编码（编码非唯一）。
4. **Godot 4.7 陷阱**：`Vector3i` 无 `dot()`；`Array.sort()` 不能排 `Vector3i`（需 `sort_custom`）。
5. **统一 headless 协议**：所有脚本 `extends SceneTree` + `print(JSON)` + `quit(0/1)`。
