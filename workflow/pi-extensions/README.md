# Pi 扩展：Game Factory 调试斜杠命令

把日常调试用的操作暴露为 pi 的斜杠命令，**不用再另开终端**。

## 命令

| 命令 | 作用 |
|---|---|
| `/serve [game] [port]` | 启动/重启 Web 预览服务（后台 + 禁用缓存），默认端口 8000 |
| `/stop` | 停止 Web 预览服务 |
| `/shot [game] [level]` | 关卡截图（需要显示环境，如 WSLg） |
| `/test [game]` | 运行该游戏的全部测试 |
| `/games` | 列出 `games/` 下发现的游戏（▶ 标注当前） |

> 只保留「调试时高频」的操作。导出（`gf-export.sh`）、关卡质检（`validate_levels.gd`）、
> 关卡生成（`generate_levels.gd`）属于按需/CI 操作，需要时直接 `bash` 调用即可，不做成常驻命令。

## 游戏无关、可扩展（重要）

命令**不绑定任何具体游戏**。执行时按以下顺序自动确定「当前游戏」：

1. 命令里显式给出的 `<game>`（例如 `/serve my-game`）
2. 当前工作目录所在的 `games/<name>/`
3. 若 `games/` 下只有一个游戏，就用它

因此**新增游戏不需要改这个扩展**：

```
games/
├── puzzle-core/      # 已有
└── my-new-game/      # 新游戏：放好 project.godot / tests/ / export_presets.cfg
```

`/games` 立刻能看到它，`/test my-new-game`、`/serve my-new-game` 直接可用。

底层脚本（`gf-run/test/serve/shot/export.sh`）本来就以「项目目录」为参数，
所以复用链条是：**扩展（自动发现游戏）→ 脚本（参数化项目）→ Godot**，任何一层都不用为新游戏重写。

## 安装

把 `game-factory.ts` 复制到 pi 的扩展目录，然后 `/reload`：

```bash
# Windows（pi 原生进程用的就是这个目录）
cp workflow/pi-extensions/game-factory.ts "/mnt/c/Users/<你>/.pi/agent/extensions/"

# 或 WSL/Linux
cp workflow/pi-extensions/game-factory.ts ~/.pi/agent/extensions/
```

装成**用户级**扩展后，任何遵循本工作流结构的仓库都能直接用这些命令。

## 实现要点

- 命令直接执行（**不经过模型**），结果以通知形式弹出。
- pi 若跑在 Windows，其 `bash` 解析会落到 WSL / Git Bash；扩展通过 `bash -c` 执行脚本，
  并把仓库路径转成 `/mnt/<drive>/...`。
- 从 `ctx.cwd` 向上查找仓库根（含 `workflow/scripts/gf-test.sh`），因此在仓库子目录里也能用。
- `/serve` 用 `nohup ... &` 后台常驻，日志写 `/tmp/gf-serve.log`；启动前会清理旧实例。
