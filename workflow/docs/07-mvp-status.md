# 07 · MVP 状态与待办（交接文档）

> 用途：当前实现状态 + MVP 差距 + 下一步计划。
> 同时作为「压缩上下文后继续工作」的交接文档——需要精确细节时看这里。

---

## 1. 当前已实现（试点游戏 `games/puzzle-core`）

### 规则核心 `core/`（纯 GDScript，headless 可跑，与引擎解耦）
- `rotations.gd` 24 个整数旋转矩阵（列向量表示，确定性整数运算）
- `shape.gd` / `shapes.gd` —— **形状是数据登记**：`REGISTRY`（id → 单元集合）+
  `ORIENTATIONS`（id → {语义名: 单元集合}）+ `DISPLAY_NAMES`。
  加新形状 = 加两行数据，不需要在任何地方写 `if id == "xxx"`。
  **已注册形状：只有 `domino`（骨牌 1×2）**
- `puzzle_state.gd`（`canonical_key()` = 世界单元集合排序序列化，用于求解去重）
- `moves.gd` 通用 PolyCube 翻滚：`roll_delta(shape, ori, d)` → `{orientation, delta, pivot}`
  （绕「前下边」旋转 90°，公式 `new_pos = pos + (I−M)·(pivot−pos)`）
- `board.gd` 网格 / **空洞** / 目标
  - **空洞 = 地面缺失**；`is_solid()` / `supports()` 是「脚下有没有地面」的**唯一依据**（越界与空洞同构）
  - `set_void(cell2d, on)` = 扩展点（实心 ↔ 空洞动态切换）
- `level_loader.gd` JSON 关卡；`puzzle_core.gd` 门面

### Solver / 工具
- `solver/solver.gd` BFS 最优解 + `grade()` 难度分级；`solver/validate.gd` 质检门
- `tools/level_generator.gd` + `generate_levels.gd`（固定种子可复现）、`validate_levels.gd`
- `tools/build_level_set.gd` —— 按声明式曲线可复现地重建整个关卡集，**并把「难度平滑爬坡」变成被校验的性质**

### 视觉层 `scenes/`
- `game.gd`：渲染 + 翻滚/坠落动画 + **踩空坠落**（`check_fall()`）+ 落地挤压 + 重生落体
  - 着色器化材质：瓦片（顶面提亮 / 边缘倒角压暗 / 目标呼吸发光）、方块（顶面提亮 + 菲涅尔边缘 + 通关闪光）
  - 目标格 = 荧光瓦片 + **嵌在瓦片表面的光圈**（自转 + 起伏）
  - 坠落两类：**完全悬空** → 原地自由落体(+自旋)；**部分悬空** → 先绕支撑边缘倾倒 90°，脱离后再落体
  - `animate=false` → 全部同步执行（供 headless 测试确定性驱动）
- `main.gd`：斜 45° 等距相机（按视口比例自适应取景）、渐变幕布（含径向暗角）、方向光+阴影、
  HUD、**统一提示带**、换关过渡、**安全区域避让**、**自适应画质**、通关庆祝

### 元游戏层 `meta/`（与规则层解耦，可 headless 单测）
- `progress.gd`：进度持久化 —— 已完成 / 最佳步数 / **最佳回放** / 本机榜（每关 5 条）；存档路径可注入
- `leaderboard.gd`：本机榜 + 总成绩汇总 + 远端提交载荷接缝
- `level_select.gd`：选关界面（顺序解锁 / 最佳与参考步数 / 本机榜 / 重置需两次确认 / **可点的返回按钮**）
- `touch_controls.gd`：触屏操作层（斜向 D-pad + 动作按钮 + 滑动 + **手势提示**）
- `ui_layout.gd`：取景 / 触控尺寸 / 选关网格 / 屏幕方向映射 / **安全区域**的纯函数
- `render_quality.gd`：画质档位与自适应降级规则（纯函数）
- `ending.gd`：全部通关的庆祝层（标题 + 统计 + 撒花 + 两个出口）

### 关卡 / 测试 / 导出
- `levels/level_01..20.json`：**20 关，全部骨牌**。
  曲线（实测，见 `build_level_set.gd` 的注释）：
  步数 **2 → 15**（逐关不减）、盘面 **25 → 144** 格、洞密度 **4% → 25%**
- `tests/`：9 个套件 / **623 项断言**全绿
- `export_presets.cfg`：**Web + Linux + Windows**（`html/head_include` 由 `gf-web-inject.sh` 从
  `workflow/web/head_include.html` 生成）

### 工作流 `workflow/` + pi 扩展
- `gf-run.sh` / `gf-test.sh` / `gf-serve.sh` / `gf-shot.sh` / `gf-export.sh` / `gf-package.sh` /
  `gf-pages.sh` / `gf-font-subset.sh` / **`gf-web-inject.sh`**；`serve_nocache.py`
- `workflow/web/`：`head_include.html`（HPI/安全区/画质策略）、`diag.html`（WebGL 能力探测页）
- pi 斜杠命令：`/serve` `/stop` `/shot` `/test` `/games` —— 游戏无关，自动发现 `games/*/`

---

## 2. MVP 对照（立项文档「十一、MVP 方案 → MVP 包含」）

| 必须项 | 状态 | 说明 |
|---|---|---|
| 3D 方块滚动 | ✅ | 通用翻滚 + 动画 |
| Domino | ✅ | 竖立/横躺/四向 |
| ~~Cube~~ | ❌ **已移除** | 单格方块没有姿态约束，只能直线走 → 不好玩（详见「已知坑」） |
| **20 个关卡** | ✅ | 全部骨牌；步数 2→15、盘面 25→144、洞密度 4%→25%，**严格平滑爬坡** |
| JSON 关卡系统 | ✅ | + 生成器 + 质检 + 可复现重建 |
| Solver | ✅ | BFS 最优解 + 难度分级 |
| **Replay** | ✅ | 通关记录移动序列；`V` 回放最佳记录（触屏按钮兼作停止） |
| **排行榜基础** | ✅ | 本机榜 + 总成绩/已最优汇总；远端载荷接缝已预留 |
| 选关界面 | ✅ | 顺序解锁 / 5 列自适应网格 / 触屏可返回 |
| **通关庆祝** | ✅ | 20 关全部通关 → 庆祝层（动画 + 统计 + 撒花 + 出口） |
| 移动端适配 | ✅ | 触屏操作 + 安全区域 + 手势提示 + 竖屏取景 |
| Web 版本 | ✅ | 已导出发布于 GitHub Pages |
| **Steam Demo** | ✅ | Windows/Linux 预设 + `gf-package.sh` 出 SteamPipe 分发包（**Steamworks SDK 未接入**） |

MVP 排除项（多人 / UGC / AI 大规模生成 / 商店 / 剧情）确认未做 ✅

---

## 3. 执行计划

### P0 ✅ 已完成
1. ✅ 关卡扩到 20 关：`tools/build_level_set.gd`（声明式曲线 + 可复现种子 + 写盘后终检 + 曲线单调校验）。

### P1 ✅ 已完成
2. ✅ **Replay**：通关记录方向标签序列 → 重演（只保存最佳步数那次）。
3. ✅ **关卡选择界面**：卡片显示形状 + 最佳/参考步数；顺序解锁。

### P2 ✅ 已完成
4. ✅ **排行榜基础** + **Steam Demo 打包**。
5. ✅ **GitHub Pages 上线**（`https://easyindie.github.io/EasyGodot/`）。
6. ✅ 修 Safari `WebGL context lost`（根因：默认 4096² 阴影贴图）。

### P3 ✅ 已完成（本轮）
7. ✅ **移除 cube + 冰面机制**：cube 关卡不可玩（一滑就坠落），整个形状与机关体系一起删掉，
   关卡全部回到骨牌，并把难度曲线重做成**逐关平滑爬坡**且**被自动校验**。
8. ✅ **通关庆祝**：`meta/ending.gd`（标题 + 统计 + 撒花 + 两个出口）。
9. ✅ **移动端安全区域**：`ui_layout.safe_insets()` + Web `env(safe-area-inset-*)` + 原生
   `DisplayServer.get_display_safe_area()`；HUD / 提示带 / 触屏控件 / 选关 / 庆祝层全部避让。
10. ✅ **触屏交互重做**：手势提示（对角线，每局一次）+ 动作按钮纯文字设计 + 回放状态变色 +
    控件布局按安全区排布。
11. ✅ **坠落后重开的动画**：方块从上方落入 + 回弹 + 落地挤压（`game.gd::play_spawn()`）。
12. ✅ **画质与分辨率无关**：MSAA + 自适应档位（`render_quality.gd`）+ 逐帧材质升级
    （瓦片/方块着色器、目标光圈、径向暗角）+ Web 端 DPR 预算策略。

### 待拍板 / 下一步
- Steamworks SDK（成就 / 云存档 / 真正的排行榜）。
- 第二个游戏复用本工作流（验证「游戏工厂」的通用性）。
- 若仍想要「形状变化」带来的新鲜感：`shapes.gd` 加一行就能注册 1×3 长条（**前提是它自证好玩**）。

---

## 4. 常用命令

```bash
workflow/scripts/gf-test.sh                                    # 跑全部测试（9 套件 623 断言）
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/validate_levels.gd
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/build_level_set.gd   # 重建 20 关（含曲线校验）
workflow/scripts/gf-export.sh games/puzzle-core web            # 导出（会自动同步 head_include）
workflow/scripts/gf-web-inject.sh games/puzzle-core            # 只同步 head_include
workflow/scripts/gf-font-subset.sh                             # 重建字体子集（含自动 --import）
workflow/scripts/gf-pages.sh --deploy                          # 发 Pages
workflow/scripts/gf-shot.sh games/puzzle-core res://levels/level_01.json
workflow/scripts/gf-serve.sh                                   # 本地预览（多线程 + 禁缓存）
```

pi 里：`/test` `/serve` `/shot` `/games`
排障 URL 参数：`?lite=1`（低端 GPU）、`?tier=0..3`（强制画质档）、`?px=2.5`（百万像素预算）、
`?dpr=1.5`（像素比上限）、`?touch=1|0`（强制触屏 UI）

---

## 5. 已知坑（省时间）

### 玩法设计
- **① 单格 cube 不好玩 —— 这是真实反馈推翻设计假设的例子。**
  单格方块在平面棋盘上没有**任何姿态约束**，只能一条直线走到目标，点几下就通关；
  「最优步数高」不等于「难」，因为决策空间只有 4 个方向且几乎全部等价。
  - 第一版补救：加冰面打滑机制（一次移动滑到底）。结果更糟：**一滑就坠落**，
    惩罚来自机制本身而不是玩家的判断，体验从「无聊」变成「折磨」。
  - 最终决定：**整个移除 cube 与机制体系**（连同 `mechanism` 字段、`slide_path`、
    求解器的折算规则一起删干净），关卡全部回到骨牌，难度改由**关卡设计**（盘面 + 洞密度）承担。
  - 留下的守卫：`test_core.gd` 断言 `Shapes.get_shape("cube") == null`，
    防止死形状或半成品机制被悄悄加回来。
  **教训：新形状/新机制必须自证好玩——姿态约束或占地约束至少要占一样。**

- **② 骨牌类谜题的最优步数几乎不随盘面变大而增长**（实测：5×5 中位数 5 步，
  11×10 中位数也只有 8 步）。起点/目标是随机撒的，随机两点之间本来就短；洞越多反而越堵。
  因此「第 20 关必须最少 20 步」这类规划**做不到也没必要**。
  难度爬坡应交给盘面尺寸 + 洞密度，步数只当搜索目标，并且要**事后校验曲线**。

- **③ 不能把上一关的「实际结果」当成下一关的门槛**（生成器里的经典错误）：
  超额命中的结果会成为下一关的下限，误差逐关累积——实测到第 8 关要求 19 步、
  第 10 关要求 31 步，后面直接生成不出来。
  正确做法是**选择**（在多种子里挑最接近目标的）而不是**抬门槛**。

### 结构与工程
- `gl_compatibility` 不渲染 `BG_SKY`/`ProceduralSkyMaterial` → 背景用**跟随相机的渐变幕布**（unshaded quad）。
- `roll_delta` 的 `pivot` 用「单元中心在整数格」坐标，而渲染把方块抬高 0.5 贴地
  → `pivot_world` 必须 **+0.5**。
- **Godot 会给同名兄弟节点自动改名**（`Tile` → `@MeshInstance3D@3`）→ 不能按名字数节点；
  用显式数组记录（`game.gd::tiles` / `tile_count()`）。
- **改「单元网格怎么挂」时必须同步所有搬运代码**（真实 bug，两处连环）：
  为了做落地挤压，把单元挂到一个位于**质心**的 pivot 下（单元位置随之变成「相对质心」）。
  于是 `_start_roll` / `check_fall` 里那句 `cube.position -= cs`（原意是把“绝对格坐标”转成相对质心）
  就多减了一次质心 → **方块在整个翻滚动画里被平移到棋盘外**，而落点因为 `_position_block()` 会重建
  所以看起来正常。只查“动完之后”完全测不出来，必须断言**中间帧**。
  另外 rig 建好后要**立刻**设好初始变换，否则 tween 求值前会闪一帧世界原点。
  教训：**「状态对、画面错」这类问题只能在渲染位置上断言** ——
  现在 `test_e2e::_test_move_animation_geometry()` 会逐帧检查质心到「起点→终点」线段的距离（注入 bug 可复现 25 帧跑偏）。
- **字体子集的扫描范围必须包含「会提供显示文案」的所有层**（真实 bug）：
  扫描范围原本只有 `scenes/` + `meta/`，注释里写着“core/solver/tools 是 headless 层，不渲染文字”。
  后来把形状显示名搬进 `core/shapes.gd`（数据注册表），扫描范围没跟着变 →
  「骨牌」两个字被移出子集，**卡片上直接渲染成豆腐块**，而守卫测试因为扫的是同一份范围也一起漏掉了。
  现在 `core/*.gd` 已纳入范围（脚本与 `tests/test_font.gd` 必须同步改）。
  教训：**“某层不会渲染文字”是个会过期的假设** —— 一旦某层开始提供显示用常量（形状名、状态名），
  它就必须进入扫描范围。
- **动画类需求要断言「中间帧」**（真实反馈“回放时方块没动画、移动很快”）：
  回放原本自己写了一套节奏（步间只停 0.05s），而翻滚缓动是 `t*t`（动作集中在最后 80ms），
  连播看起来就是“没有动画、一下一下地跳”。修法是让回放与手动操作**共用同一套原语**
  （`_wait_for_anim` / `_do_move_animated` / `_reset_to_start`），并把步间停顿改成人类节奏。
  测试断言的是「某一步过程中必须出现质心离开半整数格点的帧」+「逐帧位移不超过翻滚动画的速度上限
  （14 格/秒 × dt）」—— 前者证明真的在转，后者证明没有瞬移，且都不依赖帧率。
  注意：原来的回放测试跑在 `animate=false` 下，所以**动画从来没被验证过**。
- **一次性动画不能用「持久状态」当判据**（真实 bug）：庆祝动画原本判断「当前是否已全部通关」，
  而这是个**持久**状态 —— 于是全部通关之后回头再刷第 1 关，每次都会被再恭喜一次。
  正确做法是在 `record_win` **之前**快照，用「从未完成 → 完成」这个**跃迁**触发。
  一般规律：**一次性事件用跃迁判断，连续状态用当前值判断**，两者不能混用。
  另外庆祝动画不该是一次性的：选关界面在全部通关后提供「回顾通关」入口（未通关时不可见）。
- **刚体不要做「每步都挤压」的果冻效果**（真实反馈“方块移动动画很奇怪”）：
  方块是刚体几何，每一步都缩放一下读起来像渲染故障。挤压只留给坠落重生落地那一次，
  而且必须绕**自身质心**（早期直接缩放 `block`，而它的子节点用世界格坐标写位置 →
  缩放父节点把子节点位置一起缩放，方块每走一步都朝世界原点窜一下）。
- **底部锚点的 `offset` 是相对屏幕底边的负值**：把屏幕绝对坐标写进 `offset_*` 会让控件
  飞到屏幕外（实测提示带 `top=1040 / vp=720`）。
- **手机竖屏只有 ~390px 宽**：HUD 两块面板按固定宽度摆会**互相压住**
  → `_apply_hud_insets()` 按可用宽度比例分配 + 窄屏缩小字号并缩短文案。
- **测试不能写玩家存档**：e2e 真的会 `record_win`，早先直接写 `user://progress.json`，
  于是「全新进度」的前提在第二次运行时不成立。
  现在用项目设置 `puzzle/progress_path` 指向临时文件（顺带也修掉了存档被污染的真 bug）。
- **内置字体必须是子集**：完整 Noto Sans SC 16.4MB → 子集 ~115KB。
  `tests/test_font.gd` 只扫描**字符串字面量**（注释里的字符永远不会被渲染），
  并断言字体 < 1MB；两侧扫描规则（`STRING_RE` / `UI_SOURCES`）必须一致。
  **Noto Sans SC 几乎没有符号字形**：`↺ ☰ ● ◆ ★ ✓` 全部缺失（`↖ ↗ ↙ ↘ ▶ ■ ·` 可用）——
  图标方案不要赌字体，宁可写清楚文字 + 用颜色表达状态。
- **headless 运行不会自动重新导入资源**：改字体/纹理后 `.godot/imported/` 仍是旧的。
  `gf-font-subset.sh` 末尾已自动 `--import`。

### 平台 / 移动端
- **手机竖屏必须自己拉远相机**：`Camera3D.fov` 是竖向 FOV，竖屏横向可视范围更窄。
  见 `meta/ui_layout.gd::camera_distance()`（比例 ≥ 1 时旧行为不变）。
- **`100vh` 在 iOS Safari 上包含底部工具栏**：底部按钮会被工具栏压住（“界面显示不全”）。
  解决：注入 CSS 把 `html, body` 高度设为 `100dvh`（不支持则优雅退回 `100%`）。
- **安全区域**：必须加 `viewport-fit=cover` 之后 `env(safe-area-inset-*)` 才有意义，
  加了之后页面会铺到刘海下面，所以**必须**把 inset 交给 UI 避让（否则更糟）。
  Web 读 CSS，原生平台读 `DisplayServer.get_display_safe_area()`；两家都要**夹取**脏数据。
- **触屏是指向性输入，不能沿用键盘的网格轴映射**：斜 45° 等距相机下四个网格方向在屏幕上成对角分布，
  按键盘那样「上滑 = -z」会让方块往右上滚。屏幕方向由相机 `unproject` 现算后注入
  （`main.gd::_update_touch_screen_dirs`），D-pad 也相应转成斜向菱形。
- **横屏触屏控件会占掉底部约 40% 高度**：此时若把状态提示放在“控件上方”，
  它就正好落在屏幕垂直中央、压住棋盘 → 触屏一律把提示带放**顶部**。
- **状态提示不要放屏幕正中**：会直接压在棋盘上，玩家看不到自己刚做了什么。
  统一走 `main.gd::_refresh_bands()`（桌面底部 / 触屏顶部，同一条带只显示优先级最高的一条）。
- **Safari 的 WebGL 内存上限远紧于 Chrome**：真正的元凶是**方向光阴影默认 4096×4096（1680 万像素）**，
  比画面还大 10 倍。已降到 1024（mobile 也是 1024）、并把 `positional_shadow/atlas_size` 也降下来。
- **Web 上不能信任 `canvas_resize_policy` 的语义** → 直接**给 `devicePixelRatio` 设预算**。
  现在是**分级预算 + 下限 1.0**（任何设备都不会比 CSS 分辨率更模糊，小屏反而会超采样到 2.0），
  而不是早期那种“无条件钳到 1.6M 像素”（Retina 上等于先渲染小图再放大 → 发虚）。
  `?lite=1 / ?tier= / ?px= / ?dpr=` 都可用于排障二分。

### CI / 工具链
- 单线程 HTTP server 会被一次中断的下载**永久卡死** → 必须多线程。
- 浏览器对 `index.pck` 缓存极顽固 → 用 `gf-serve.sh`（`Cache-Control: no-store`）。
- Godot 4 坑：`Vector3i` 无 `dot()`；`Array.sort()` 不能排 `Vector3i`（用 `sort_custom`）；
  版本头污染 stdout（用 `--no-header`）。
- **WSL 的 drvfs 下 `core.fileMode=false`**：git 记不住执行位，所有文件入库为 `100644`，
  CI 里直接调用脚本会 `Permission denied` → `git update-index --chmod=+x workflow/scripts/*.sh`。
- **GitHub Pages 无法自定义响应头** → 只能托管 Godot 的**单线程** Web 导出；
  **免费版组织**的 Pages 只能从**公开仓库**发布；首次启用需 `gh api -X POST repos/<o>/<r>/pages -f build_type=workflow`。

---

## 6. 关键文件

```
games/puzzle-core/
  core/{rotations,shape,shapes,puzzle_state,moves,board,level_loader,puzzle_core,util}.gd
  solver/{solver,validate}.gd
  scenes/{game,main}.gd  +  main.tscn
  tools/{level_generator,generate_levels,build_level_set,validate_levels,screenshot}.gd
  meta/{progress,leaderboard,level_select,touch_controls,ui_layout,render_quality,ending}.gd
  levels/level_01..20.json              # 20 关，全部骨牌
  tests/{test_core,test_solver,test_e2e,test_generator,test_progress,
         test_leaderboard,test_ui_layout,test_render_quality,test_font,fixtures}.gd
workflow/scripts/gf-*.sh  +  serve_nocache.py
workflow/web/{head_include.html,diag.html}
workflow/docs/01..07
workflow/pi-extensions/game-factory.ts
```
