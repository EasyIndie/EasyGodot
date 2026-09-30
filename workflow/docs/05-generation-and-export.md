# 05 · AI 关卡生成与导出管线（阶段 4 沉淀）

> 这是「AI 游戏工厂」闭环的最后一块：内容自动生产（生成 → 质检 → 筛选）+ 一键导出分发。

---

## 1. 关卡生成器（tools/level_generator.gd + generate_levels.gd）

**核心闭环**：

```
随机生成候选关卡
      ↓
质检门 Validate（合法性 → 可解性 → 难度）
      ↓
按条件筛选（难度 / 最少步数）
      ↓
写出合格关卡 JSON
```

**CLI 用法**：

```bash
# 生成 20 个 medium 关卡（6x6，洞密度 12%，最少 2 步，固定种子）
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/generate_levels.gd \
  --count 20 --difficulty medium --grid 6x6 --holes 12 --min-moves 2 --seed 42
```

**参数**：`--count` / `--difficulty`（easy/medium/hard/expert/any）/ `--grid WxZ` / `--holes P%` /
`--min-moves N` / `--seed S` / `--out DIR` / `--shape S`（`domino`|`cube`，默认 domino）

**淘汰分桶**（stats）：`invalid`（不合法）/ `unsolvable`（不可解）/ `trivial`（步数不足）/
`wrong_difficulty`（难度不符）。实测：20 次尝试 → 15 关保留（4 不合法 + 1 不可解）。

**特性**：固定种子完全可复现（利于测试与回归）。

---

## 1b. 正式关卡集构建（tools/build_level_set.gd）

`generate_levels.gd` 产出的是**候选池**；正式关卡集用一个**声明式曲线**来构建：

```bash
workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/build_level_set.gd
# → 覆写 levels/level_01..20.json（默认种子 2027，完全可复现）
```

- 脚本内 `SPECS` 常量声明每一关的 `{形状, 目标难度, 棋盘尺寸, 洞密度, 最少步数}`
- 逐关尝试多个种子来命中原难度；命中不了则回退「任意难度」并标记 `met=false`
- 写出后**从磁盘重新加载 + 求解**做终检（确保写出去的东西真的可用）
- 汇总里 `met_target == total` 且 `written == total` 才返回退出码 0

当前曲线（20 关）：`easy×4 → medium×3 → cube(easy) → medium×2 → hard → cube(medium) →
hard×3 → cube(medium) → hard → expert×2 → cube(hard)`

> **Cube 是单格形状**：姿态在规则上等价，`shapes.gd::resolve_orientation` 对单格形状
> 把任何语义描述符（`standing`/`lying_x`/`lying_z`）都映射到 `orientation = 0`；
> 生成器指定 `--shape cube` 时固定输出 `standing`。

---

## 2. 导出管线（export_presets.cfg + workflow/scripts/gf-export.sh）

**预设**：Web（`--export-release Web`）+ Linux（`--export-release Linux`）+ Windows（`--export-release "Windows"`）。

**一键导出**：

```bash
workflow/scripts/gf-export.sh                      # 三个平台全导
workflow/scripts/gf-export.sh games/puzzle-core windows   # 只导指定平台
```

**导出模板安装**（一次性）：

```bash
# 下载并安装到 ~/.local/share/godot/export_templates/<版本>/（4.7.2.stable）
```

**产物**：

```
games/puzzle-core/build/
├── web/index.html + index.wasm + index.pck + index.js   # 浏览器直接跑
├── linux/puzzle-core.x86_64 + puzzle-core.pck           # 桌面可执行
└── windows/puzzle-core.exe + puzzle-core.pck            # Windows 可执行
```

**关键：导出过滤**。`exclude_filter="build/*, tests/*, tools/*"` 避免把开发产物
（测试/工具/上次构建输出）打进游戏包。实测排除生效（打包日志不再含 tests/tools/build）。

**本地预览（防缓存）**：

```bash
workflow/scripts/gf-serve.sh        # → http://localhost:8000
```

`index.pck`（~14MB）/ `index.wasm`（~39MB）体积大，浏览器极易沿用旧缓存，
造成「改了代码但页面没变」的假象。`gf-serve.sh` 使用 `serve_nocache.py`：

- 对所有响应加 `Cache-Control: no-store, no-cache`，强制每次拉取最新产物；
- 用 `ThreadingHTTPServer`（**多线程**）——`python -m http.server` / `TCPServer` 是单线程的，
  只要有一个客户端中途断开下载就会**阻塞在 send() 上、之后所有请求全部挂起**，
  浏览器只能回退旧缓存（这是排查过的真实故障）；
- 启动时打印 `index.pck` 的更新时间，便于确认托管的是最新构建；
- 端口被占用时给出提示。

**验证构建内容**（不依赖浏览器）：用 Godot 直接加载 `index.pck` 并检查常量/信号，
或直接从 pck 实例化主场景驱动一次坠落判定，可确认导出的脚本就是最新代码。

> 用其他服务器（如 VS Code Live Server）时，务必硬刷新（Ctrl+Shift+R）或在
> DevTools → Network 勾选 Disable cache。

---

## 2b. Steam Demo 打包（workflow/scripts/gf-package.sh）

立项文档 MVP 的「Steam Demo」= 可直接上架 Steam 的桌面分发包。本脚本把它一键化：

```bash
workflow/scripts/gf-package.sh                        # Windows + Linux（默认 appid 480）
workflow/scripts/gf-package.sh games/puzzle-core --appid 1234560
workflow/scripts/gf-package.sh games/puzzle-core --platforms "windows"
```

**流程**：导出构建 → 组装 `dist/<name>-steam-demo-dir/` → 压缩（zip，无 zip 时退回 tar.gz）。

**产物结构**：

```
dist/puzzle-core-steam-demo.zip
dist/puzzle-core-steam-demo-dir/
├── steam_appid.txt            # 本地走 Steam 客户端联调用（默认 480 = Valve 的 Spacewar）
├── README.txt                 # 运行 / 上传 / 上架说明（自动生成）
├── windows/puzzle-core.exe + .pck + steam_appid.txt
├── linux/puzzle-core.x86_64 + .pck + steam_appid.txt
└── steamcmd/
    ├── app_build_windows.vdf  # SteamPipe 上传配置模板（contentroot 指向 windows/）
    └── app_build_linux.vdf
```

上传（需真实 appid/depot id，先改 vdf）：

```bash
steamcmd +login <账号> +run_app_build <绝对路径>/app_build_windows.vdf +quit
```

> **范围说明**：这里交付的是「**能上架、能下载、能跑**」的分发闭环，**不含** Steamworks SDK
> 集成（成就 / 云存档 / Steam 排行榜）。后者需要 SDK 动态库与 `appid`，属于后续迭代。

---

## 2c. 发布到 GitHub Pages

**能不能上？能。** 但要知道为什么——GitHub Pages 有一个硬限制。

### 关键约束：Pages 无法自定义响应头

GitHub Pages 不能发 `Cross-Origin-Opener-Policy` / `Cross-Origin-Embedder-Policy`，
而这**只**影响 Godot 的**多线程** Web 导出（它需要 `SharedArrayBuffer`，进而需要跨源隔离）。

本项目用的是**单线程**导出：

```ini
# games/puzzle-core/export_presets.cfg
variant/thread_support=false
```

因此不需要跨源隔离，静态托管即可运行。另外：

- 导出的 `index.html` 用**相对路径**引用资源 → 可放在 `https://<user>.github.io/<repo>/` 子路径
- 最大的 `index.wasm`（约 38MB）低于 GitHub 的 100MB/文件硬限制
- 仍建议加 `.nojekyll`（避免 Jekyll 处理静态产物）

**实测验证**（用最朴素的静态服务器，等价于 Pages 的零自定义响应头）：

| 文件 | 结果 |
|---|---|
| `index.wasm` | HTTP 200，`application/wasm`（`instantiateStreaming` 需要这个 MIME，Pages 也提供） |
| `index.pck` | HTTP 200，`application/octet-stream`（Godot 按 arraybuffer 读取，无妨） |
| `index.html` | HTTP 200，`text/html` |
| 响应头 | **无 COOP/COEP** —— 与 Pages 一致，游戏照常运行 |

### 两种发布方式

**B（推荐）：GitHub Actions 自动构建部署**

`.github/workflows/pages.yml` 在推送 `main` 时执行：
安装 Godot `4.7.2` + 导出模板（带缓存）→ 导入资源 → **跑全部测试与关卡质检** →
导出 Web → 加 `.nojekyll` → 上传并部署到 Pages。

仓库 Settings → Pages → Source 选 **“GitHub Actions”**。

> 好处：构建产物不进版本库；测试/质检不过就不发布。

**A：本地构建 + 推到 gh-pages 分支**

```bash
workflow/scripts/gf-pages.sh games/puzzle-core --deploy
```

脚本会导出 Web、把产物放进 `dist/pages/` 并加 `.nojekyll`，
然后以独立 git 仓库强推到 `gh-pages` 分支。之后 Settings → Pages →
Source 选 “Deploy from a branch” → `gh-pages` / `(root)`。

```bash
# 只生成不部署（先把本地目录当 Pages 跑一遍）
workflow/scripts/gf-pages.sh games/puzzle-core
python3 -m http.server 8080 --directory dist/pages   # → http://localhost:8080
```

### Safari 兼容性（已踩过的坑）

**现象**：Safari 打开后弹 `WebGL context lost, please reload the page`。

**根因**：`html/canvas_resize_policy=2`（Adaptive）会让 WebGL 绘图缓冲 =
`window.innerWidth × devicePixelRatio`。Retina 上就是 **3024×1800（约 540 万像素）**；
Safari 的 WebGL 内存上限远紧于 Chrome，直接回收上下文。

**修复**（三件）：

1. `canvas_resize_policy` 改为 **1（Project）**——绘图缓冲固定为项目视口 **1280×720
   （约 92 万像素，约 1/6）**；
2. `html/head_include` 注入 CSS，把 canvas 按 16:9 **铺满窗口**（弥补固定分辨率的显示尺寸），
   并把 Godot 的 `alert` 换成**带「重新加载」按钮的页面内浮层**；
3. `project.godot` 显式关闭 `msaa_3d`/`msaa_2d`，避免多重采样帧缓冲再翻几倍内存。

> 注意：`head_include` 里的 CSS 必须用 `!important`，才能盖过 Godot 每次 resize 写入的
> 内联 `style.width/height`；但这不影响 Godot 的判断（它读的是内联属性值）与输入坐标映射
> （它用 `getBoundingClientRect()`）。

**诊断页**：`workflow/web/diag.html` 会被 `gf-export.sh` 自动附带到站点根目录，
访问 `/diag.html` 即可看到：WebGL2/1 支持、真实 GPU renderer、`MAX_RENDERBUFFER_SIZE`、
DPR 与窗口尺寸，并**真正分配**三种尺寸的帧缓冲看能否成功，以及可同时创建多少个 WebGL2 上下文。

### 注意事项

- **仓库已转为公开**，Pages 使用 **workflow 构建源**（`build_type=workflow`）。
  免费版组织的 Pages 只能从公开仓库发布——这就是当初必须先转公开的原因。
- 首次启用 Pages 需要一次显式操作（工作流的 `GITHUB_TOKEN` 没有 admin 权限，
  `configure-pages` 的 `enablement` 开不了）：
  ```bash
  gh api -X POST repos/<owner>/<repo>/pages -f build_type=workflow
  ```
  之后 `actions/configure-pages` 只负责读取配置，不需要 admin。
- `workflow/godot-bin/`（Godot 二进制，>100MB）、`games/*/build/`、`dist/` 已在 `.gitignore` 中。
- 若日后**开启多线程导出**（`variant/thread_support=true`），GitHub Pages 会因缺少
  COOP/COEP 而无法运行 —— 那时需换 Cloudflare Pages / Netlify（它们可自定义响应头）。
- `gf-serve.sh` 仅供**本地开发**（它额外发了 no-store，且是多线程服务器），与 Pages 无关。

---

## 2c. 字体子集化（workflow/scripts/gf-font-subset.sh）

中文字体是 Web 游戏体积的大头：Noto Sans SC 完整字体 **16.4MB**。
本游戏 UI 实际上只用几百个字，于是按项目实际用字裁剪：

```bash
workflow/scripts/gf-font-subset.sh                     # 重建字体子集
workflow/scripts/gf-run.sh -p games/puzzle-core res://tests/test_font.gd   # 校验
```

| | 前 | 后 |
|---|---|---|
| 字体文件 | 16.4 MB | **100 KB**（165×） |
| `index.pck` | 14.5 MB | **307 KB** |
| 首屏下载（pck+wasm+js） | ~54 MB | **~39.8 MB**（-26%） |
| 运行时字体内存 | ~16 MB | **~0.1 MB** |

**做法**：从会渲染 UI 文本的源码（`scenes/`、`meta/`、`*.tscn`、`project.godot`）里提取**字符串字面量**
（注释与标识符永远不会被渲染，不该逼字体包含里面的生僻符号，如 `∘`、`——`），
加上 `levels/*.json` 全量；再用 HarfBuzz（`subset-font`，Node 包）裁剪。
完整字体自动下载（`notofonts/noto-cjk` 的 SubsetOTF），
`subset-font` 缺失时自动 `npm install` 到 `.tools/fontsubset/`。

**守卫**：`tests/test_font.gd` 扫描同样的来源，断言每个字符都有字形，
并断言字体 < 1MB（防止有人不小心把完整字体换回去）。
新增文案用到子集外的字会**直接测试失败**，而不是静默变成豆腐块。

> 两边扫描范围必须一致（`STRING_RE` / `UI_SOURCES`）。core/solver/tools/tests 是 headless 层，
> 不渲染文字，其注释里的 `∘` 之类符号也未必在 Noto Sans SC 里，所以不计入。

---

## 3. 阶段 4 沉淀的最佳实践

1. **内容生产闭环 = 生成 + 质检门 + 筛选**：AI 生成关卡不再「人工抽查」，而是自动
   过滤到「合法 + 可解 + 难度达标」才入库。
2. **确定性种子**：生成器固定种子可复现，AI 可以「同种子微调」迭代关卡。
3. **生成逻辑与 CLI 分离**：`level_generator.gd`（可测试类）+ `generate_levels.gd`（薄 CLI）。
4. **导出过滤开发产物**：`exclude_filter` 排除 tests/tools/build，包体干净。
5. **构建输出纳入 .gitignore**：`build/`、`.godot/`、`godot-bin/`、`levels/generated/` 不入库。

---

## 4. 全流程回顾（阶段 0-4 已完成）

```
[内容] 关卡 JSON ──► 质检门(validate) ──► 可解/难度 ──► 入库
[生成] level_generator ──► 质检门 ──► 筛选 ──► 写 JSON
[规则] core（纯逻辑，headless 可跑）
[测试] 五层：unit/state/level/E2E/generator（gf-test.sh，127+ 项）
[视觉] scenes（通用 PolyCube 渲染，消费 core）
[求解] solver（BFS 最优解/难度/Replay 数据）
[分发] gf-export.sh（Web + Linux 一键构建）
[智能体] gf-run.sh + SKILL.md + docs/（可复用平台 + 最佳实践）
```
