# 03 · 求解器与关卡质检门（阶段 2 沉淀）

> 求解器 + 质检门是「AI 生成关卡」流水线的核心：任何关卡（人工或 AI 生成）
> 都要通过「合法性 → 可解性 → 难度」三道关卡，产出结构化报告。

---

## 1. 求解器（solver/solver.gd）

**算法**：BFS，从起点按 4 个方向扩展，状态去重用 `canonical_key()`
（世界单元排序后的字符串，保证「同一世界位置」只算一次）。

**输出**（结构化 JSON）：

| 字段 | 含义 |
|---|---|
| `solvable` | 是否可解 |
| `optimal_moves` | 最少步数（BFS 天然保证最短） |
| `solution` | 解路径，人类可读方向名（right/left/forward/backward） |
| `reachable_states` | 可达状态总数（复杂度指标） |
| `difficulty` | 难度分级 |

**难度分级**（阈值可调，当前以最优步数为主）：

```
≤ 4 步 → easy      5~9 步 → medium
10~16 步 → hard    > 16 步 → expert
```

---

## 2. 关卡质检门（solver/validate.gd + tools/validate_levels.gd）

三道关卡：

```
关卡 JSON
   │
   ├─ 1. 合法性（Schema）：结构可解析、起点在实心格、目标非空且在实心格、洞在界内
   │       └─ 失败 → status=invalid
   │
   ├─ 2. 可解性（Solver）
   │       └─ 失败 → status=unsolvable
   │
   └─ 3. 难度（grade）
           └─ 成功 → status=valid + 难度/最优解/路径
```

**CLI 用法**（自动质检 `levels/` 下全部关卡，或指定关卡）：

```bash
# 质检全部
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/validate_levels.gd

# 质检指定关卡（支持绝对路径）
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/validate_levels.gd res://levels/level_01.json
```

**门禁语义**：存在 `invalid` 或 `unsolvable` 关卡时退出码非 0 —— CI/智能体可直接据此拦截。

---

## 3. 运行测试

```bash
# 单个套件
workflow/scripts/gf-run.sh -p games/puzzle-core res://tests/test_core.gd

# 全部套件
workflow/scripts/gf-test.sh
```

---

## 4. 阶段 2 沉淀的最佳实践

1. **移动逻辑单一来源**：`puzzle_core.apply_move_on(board, state, d)` 为纯函数，
   求解器与门面共用，避免「合法移动」判定在多处漂移。
2. **BFS + 规范键去重**：去重键必须基于 `world_cells()`（不变式），而非内部编码。
3. **质检门 = 可执行契约**：关卡质量不用口头约定，而是 `validate` 脚本 + 退出码，
   让 AI 生成关卡能自动闭环（生成 → 质检 → 不过就重试/丢弃）。
4. **方向名可读化**：解路径用 right/left/forward/backward，直接可作 Replay/排行榜/Ghost 数据。
5. **测试金字塔第 3 层（Level Test）落地**：`test_solver` 覆盖可解/非法/不可解三类，
   并验证「解路径真实可达目标」（replay 校验）。

---

## 5. 下一步（阶段 3）

视觉层：3D 场景消费同一套规则核心，Godot Headless E2E（启动场景 + 注入输入序列 + 验证结果）。
